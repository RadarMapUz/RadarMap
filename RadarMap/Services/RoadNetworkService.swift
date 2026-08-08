//
//  RoadNetworkService.swift
//  RadarMap
//
//  Дорожные тайлы для схемы приборки: подписанный индекс + ленивые тайлы.
//
//  Устройство повторяет остальные молча применяемые данные (правило 19):
//  индекс — SignedPayload, проверяется ДО разбора и на каждой загрузке с
//  диска (файл на диске — такие же чужие байты, как файл из сети); каждый
//  тайл сверяется с sha256 из индекса и при несходстве отбрасывается,
//  а не «спасается». Любая неисправность даёт пустой источник — схема
//  тогда рисует сеть из индекса лимитов (FallbackRoadNetwork), то есть
//  ровно то, что рисовала до появления тайлов.
//
//  Ленивость: телефон возит окрестность 3×3 тайла (~165 км), а не страну.
//  ensureCoverage дёргается тиком приборки — скачивание идёт только когда
//  схема на экране и только недостающих тайлов.
//

import CoreLocation
import Foundation
import Observation
import os

@MainActor
@Observable
final class RoadNetworkService {
    /// Растёт при каждой смене снимка сети — по нему схема пересобирает растр.
    private(set) var revision = 0
    /// Снимок загруженных тайлов под кэшем окрестности. Пустой, пока тайлы
    /// не приехали, — вызывающий обязан держать фолбэк, а не пустоту.
    private(set) var network: any RoadNetworkSource = EmptyRoadNetwork()

    @ObservationIgnored private var index: RoadTiles.Index?
    /// Распакованные тайлы в памяти (только окрестность — см. eviction).
    @ObservationIgnored private var loaded: [String: [RoadLine]] = [:]
    /// Битые или отсутствующие на сервере — не долбим по кругу до нового индекса.
    @ObservationIgnored private var broken: Set<String> = []
    @ObservationIgnored private var downloading: Set<String> = []
    @ObservationIgnored private var snapshotKeys: Set<String> = []
    @ObservationIgnored private var started = false
    /// Где проверяли покрытие в прошлый раз (гейт ensureCoverage).
    @ObservationIgnored private var lastEnsureAt: CLLocationCoordinate2D?
    /// Один клиент на сервис: новый APIClient — это новый URLSession без
    /// keep-alive, т.е. свежее TCP+TLS-рукопожатие на каждый тайл к тому же
    /// хосту, и никем не закрываемая сессия следом.
    @ObservationIgnored private let api = APIClient(timeout: 30)

    private var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("roads", isDirectory: true)
    }
    private var indexURL: URL { directory.appendingPathComponent("roads_index.json") }

    // MARK: - Старт и индекс

    /// Вызывается при старте приложения: локальный индекс сразу, сервер — раз
    /// в неделю (дорожная сеть меняется медленнее камер).
    func start() {
        guard !started else { return }
        started = true
        Task {
            await loadLocalIndex()
            await refreshIndexIfNeeded()
        }
    }

    private func loadLocalIndex() async {
        let url = indexURL
        let loaded = await Task.detached(priority: .utility) { () -> RoadTiles.Index? in
            guard let data = try? Data(contentsOf: url),
                  let envelope = try? JSONDecoder().decode(
                      SignedPayload<RoadTiles.Index>.self, from: data)
            else { return nil }
            return envelope.verified()
        }.value
        if let loaded, loaded.version == RoadTiles.formatVersion {
            index = loaded
        }
    }

    private func refreshIndexIfNeeded() async {
        let lastCheck = Storage.double(.roadsIndexLastCheck)
        let weekAgo = Date().timeIntervalSince1970 - 7 * 24 * 3600
        guard index == nil || lastCheck < weekAgo else { return }

        // Недельная фоновая проверка: сбой сети не критичен, попробуем позже.
        guard let data = try? await api.getData("roads_index.json",
                                                cachePolicy: .reloadIgnoringLocalCacheData)
        else { return }

        let url = indexURL, directory = self.directory
        let fresh = await Task.detached(priority: .utility) { () -> RoadTiles.Index? in
            guard let envelope = try? JSONDecoder().decode(
                      SignedPayload<RoadTiles.Index>.self, from: data),
                  let value = envelope.verified(),
                  value.version == RoadTiles.formatVersion else { return nil }
            do {
                try FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                // Индекс уже в памяти — без кэша просто перекачаем через неделю.
                Log.route.error("индекс дорог не записался: \(error.localizedDescription, privacy: .public)")
            }
            return value
        }.value
        guard let fresh else { return }
        let replacing = index != nil && index != fresh
        index = fresh
        Storage.set(Date().timeIntervalSince1970, for: .roadsIndexLastCheck)
        if replacing {
            // Хэши могли смениться — всё загруженное перечитается и переверится.
            loaded.removeAll()
            broken.removeAll()
            snapshotKeys.removeAll()
        }
    }

    // MARK: - Ленивое покрытие

    /// Обеспечить тайлы вокруг точки (3×3). Дёргается тиком приборки: дёшево,
    /// когда всё на месте; скачивает только недостающее.
    func ensureCoverage(around coordinate: CLLocationCoordinate2D) {
        guard let index else { return }
        // Гейт: тайл — 55 км, состав окрестности меняется раз в десятки минут,
        // а тик приборки дёргает нас каждую секунду — и 9 строковых ключей с
        // тремя Set'ами каждый раз выбрасывались. Пока не отъехали на километр
        // и ничего не в полёте, выходим по одному сравнению расстояния.
        if let last = lastEnsureAt, downloading.isEmpty, !snapshotKeys.isEmpty,
           GeoMath.fastDistance(last.latitude, last.longitude,
                                coordinate.latitude, coordinate.longitude) < 1000 {
            return
        }
        lastEnsureAt = coordinate
        // Тайлы, которых нет в подписанном индексе, не существуют и не
        // запрашиваются: индекс — единственный источник правды о наборе.
        let wanted = Set(RoadTiles.neighborhood(of: coordinate,
                                                tileDegrees: index.tileDegrees))
            .filter { index.tiles[$0] != nil }

        var missing: [String] = []
        for key in wanted where loaded[key] == nil && !broken.contains(key)
            && !downloading.contains(key) {
            missing.append(key)
        }
        for key in missing {
            downloading.insert(key)
            Task { await load(key: key, expected: index.tiles[key]!) }
        }
        // Снимок пересобирается, когда состав окрестности изменился и всё,
        // что можно было получить, получено.
        let ready = wanted.filter { loaded[$0] != nil }
        if missing.isEmpty, downloading.isEmpty, ready != snapshotKeys {
            rebuildSnapshot(keys: ready)
        }
    }

    /// Тайл: сперва диск, затем сеть; в обоих случаях sha256 сверяется с
    /// подписанным индексом, несходство — «тайла нет», не «сойдёт и так».
    private func load(key: String, expected: RoadTiles.Index.TileMeta) async {
        defer { downloading.remove(key) }
        let fileURL = directory.appendingPathComponent("tile_\(key).json")

        let fromDisk = await Task.detached(priority: .utility) { () -> [RoadLine]? in
            guard let data = try? Data(contentsOf: fileURL),
                  RoadTiles.sha256Hex(of: data) == expected.sha256 else { return nil }
            return RoadTiles.decodeTile(data)
        }.value
        if let fromDisk {
            finish(key: key, lines: fromDisk)
            return
        }

        guard let data = try? await api.getData("roads/tile_\(key).json") else {
            // Сеть — не приговор: попробуем при следующем ensureCoverage.
            return
        }
        let directory = self.directory
        let decoded = await Task.detached(priority: .utility) { () -> [RoadLine]? in
            guard RoadTiles.sha256Hex(of: data) == expected.sha256,
                  let lines = RoadTiles.decodeTile(data) else { return nil }
            do {
                try FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                Log.route.error("тайл дорог не записался: \(error.localizedDescription, privacy: .public)")
            }
            return lines
        }.value
        guard let decoded else {
            broken.insert(key)
            Log.route.error("тайл дорог \(key, privacy: .public) не сошёлся по sha или формату — отброшен")
            return
        }
        finish(key: key, lines: decoded)
    }

    private func finish(key: String, lines: [RoadLine]) {
        loaded[key] = lines
        // Снимок собираем один раз, когда долетела вся пачка; следующий
        // ensureCoverage сузит его до окрестности и выселит дальние тайлы.
        guard downloading.isEmpty else { return }
        rebuildSnapshot(keys: Set(loaded.keys))
    }

    private func rebuildSnapshot(keys: Set<String>) {
        // Дальние тайлы — вон из памяти (файлы остаются на диске).
        if loaded.count > 12 {
            for key in loaded.keys where !keys.contains(key) {
                loaded.removeValue(forKey: key)
            }
        }
        snapshotKeys = keys
        let tiles = keys.compactMap { loaded[$0] }
        Task.detached(priority: .utility) { [tiles] in
            let built = TileRoadNetwork.build(tiles)
            await MainActor.run {
                self.network = CachedRoadNetwork(built)
                self.revision += 1
                Log.route.info("сеть дорог: \(built.lines.count) линий из \(tiles.count) тайлов")
            }
        }
    }
}
