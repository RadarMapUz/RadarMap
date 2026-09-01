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

    /// Снос — БЕЗ прыжка на актор, и это не стиль, а обход живого бага рантайма.
    ///
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor синтезирует isolated deinit
    /// каждому @MainActor-классу, даже когда своего deinit нет. Такой deinit
    /// уходит в swift_task_deinitOnExecutor, тот в синхронном кадре главного
    /// потока (текущей Task нет) заводит TaskLocal::StopLookupScope, а
    /// MarkerItem::create в рантайме iOS 26 берёт память у task-аллокатора
    /// БЕЗУСЛОВНО — при task == nullptr это статический слэб внутри
    /// libswift_Concurrency. Item::destroy потом зовёт free() по этому
    /// указателю: «pointer being freed was not allocated» → SIGABRT.
    ///
    /// Условия сходятся ровно там, где SwiftUI сносит вью с @State-моделью
    /// внутри GraphHost.runTransaction: там жива task-local привязка. В ветке
    /// main рантайма баг уже исправлен; до выхода такой iOS помогает одно —
    /// не синтезировать isolated deinit вовсе.
    nonisolated deinit {}
    /// Растёт при каждой смене снимка сети — по нему схема пересобирает растр.
    private(set) var revision = 0
    /// Снимок загруженных тайлов под кэшем окрестности. Пустой, пока тайлы
    /// не приехали, — вызывающий обязан держать фолбэк, а не пустоту.
    private(set) var network: any RoadNetworkSource = EmptyRoadNetwork()
    /// Костяк района: раздельные проезжие сведены в одну ось, мелочи нет.
    /// Пустой на старом формате — вызывающий тогда берёт обычную сеть.
    private(set) var farNetwork: any RoadNetworkSource = EmptyRoadNetwork()

    /// Местность вокруг: вода, зелень, рельсы, кварталы. Пустая, пока слои не
    /// приехали, — рисовать нечего, и это нормальное состояние.
    private(set) var areas: [SketchArea] = []
    /// Точечные объекты, нарисованные руками в панели: светофоры, развороты.
    private(set) var points: [SketchPoint] = []
    /// Те же объекты, пересчитанные сервером по костяку района: свои
    /// пересечения, своё сведение, своя посадка на ось. Не выборка из
    /// points — другая геометрия, как и сама дальняя сеть.
    private(set) var farPoints: [SketchPoint] = []

    /// Какие наборы тайлов сейчас нужны. Ставит схема: она одна знает охват и
    /// то, едем ли мы по двору. Слой, невидимый на текущем охвате, не
    /// качается и не разбирается вовсе — дворовые проезды это половина всех
    /// дорог, и в общем файле они ехали бы на телефон всю поездку впустую.
    func setWantedSets(_ wanted: Swift.Set<RoadTiles.Set>) {
        guard wanted != wantedSets else { return }
        wantedSets = wanted
        lastEnsureAt = nil   // состав окрестности изменился — проверить сразу
    }
    @ObservationIgnored private var wantedSets: Swift.Set<RoadTiles.Set> = [.far, .streets]
    /// Распакованная местность по ключам наборов.
    @ObservationIgnored private var loadedAreas: [String: [SketchArea]] = [:]
    @ObservationIgnored private var loadedPoints: [String: [SketchPoint]] = [:]
    @ObservationIgnored private var loadedPointsFar: [String: [SketchPoint]] = [:]

    /// Сеть приходит уже генерализованной: склейка, схлопывание раздельных
    /// проезжих, отсев обрубков и упрощение посчитаны на сервере один раз на
    /// всю страну. Схема тогда только фильтрует по классу и сглаживает.
    var isPrecomputed: Bool { indexVersion >= RoadTiles.formatVersionV2 }

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
    private var indexURL: URL {
        directory.appendingPathComponent(indexVersion >= RoadTiles.formatVersionV2
                                         ? "roads_index_v2.json" : "roads_index.json")
    }
    /// Версия действующего индекса. Старый формат остаётся рабочим: сервер
    /// публикует оба, пока в проде есть сборки, знающие только его.
    @ObservationIgnored private var indexVersion = RoadTiles.formatVersionV2

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
        // Сперва новый формат, потом старый: если на диске лежат оба, работать
        // надо по новому.
        for version in [RoadTiles.formatVersionV2, RoadTiles.formatVersion] {
            indexVersion = version
            let url = indexURL
            let loaded = await Task.detached(priority: .utility) { () -> RoadTiles.Index? in
                guard let data = try? Data(contentsOf: url),
                      let envelope = try? JSONDecoder().decode(
                          SignedPayload<RoadTiles.Index>.self, from: data)
                else { return nil }
                return envelope.verified()
            }.value
            if let loaded, loaded.version == version {
                index = loaded
                return
            }
        }
        indexVersion = RoadTiles.formatVersionV2
    }

    private func refreshIndexIfNeeded() async {
        // Трое суток, а не семь. Публикация недельная, и при недельной же
        // проверке телефон в худшем случае ждал свежие дороги почти две
        // недели: разминулись на день — жди следующий круг. Трое суток режут
        // ожидание вдвое, а стоят одного маленького подписанного JSON.
        let lastCheck = Storage.double(.roadsIndexLastCheck)
        let deadline = Date().timeIntervalSince1970 - 3 * 24 * 3600
        guard index == nil || lastCheck < deadline else { return }

        // Недельная фоновая проверка: сбой сети не критичен, попробуем позже.
        // Новый формат спрашиваем первым; сервер отдаёт оба, пока в проде есть
        // сборки, знающие только старый.
        var payload: Data?
        for version in [RoadTiles.formatVersionV2, RoadTiles.formatVersion] {
            indexVersion = version
            let name = version >= RoadTiles.formatVersionV2
                ? "roads_index_v2.json" : "roads_index.json"
            if let data = try? await api.getData(name,
                                                 cachePolicy: .reloadIgnoringLocalCacheData) {
                payload = data
                break
            }
        }
        guard let data = payload else { return }
        let expectedVersion = indexVersion

        let url = indexURL, directory = self.directory
        let fresh = await Task.detached(priority: .utility) { () -> RoadTiles.Index? in
            guard let envelope = try? JSONDecoder().decode(
                      SignedPayload<RoadTiles.Index>.self, from: data),
                  let value = envelope.verified(),
                  value.version == expectedVersion else { return nil }
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
        // Новый индекс — новый набор тайлов; проверить покрытие заново, не
        // дожидаясь, пока машина отъедет на километр.
        lastEnsureAt = nil
        Storage.set(Date().timeIntervalSince1970, for: .roadsIndexLastCheck)
        if replacing {
            // Хэши могли смениться — всё загруженное перечитается и переверится.
            loaded.removeAll()
            broken.removeAll()
            snapshotKeys.removeAll()
        }
        collectGarbage(keeping: fresh)
    }

    /// Убрать с диска файлы, которых больше нет в индексе.
    ///
    /// Раньше это была гигиена, теперь необходимость: смена сетки с 0.5° на
    /// 0.05° делает мусором ВСЕ старые тайлы разом — до двадцати четырёх
    /// мегабайт, которые никто никогда больше не прочитает и которые не
    /// исчезнут сами. Индекс подписан и знает полный состав набора, так что
    /// «нет в индексе» — это надёжный признак, а не догадка.
    private func collectGarbage(keeping index: RoadTiles.Index) {
        let directory = self.directory
        let live = Set(index.tiles.keys.map {
            RoadTiles.fileName(key: $0, version: index.version)
        })
        Task.detached(priority: .background) {
            let manager = FileManager.default
            guard let names = try? manager.contentsOfDirectory(atPath: directory.path)
            else { return }
            var removed = 0
            for name in names where name.hasPrefix("tile_") || name.hasPrefix("road2_") {
                guard !live.contains(name) else { continue }
                try? manager.removeItem(at: directory.appendingPathComponent(name))
                removed += 1
            }
            if removed > 0 {
                Log.route.notice("тайлы дорог вне индекса удалены: \(removed, privacy: .public)")
            }
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
        // Условия «есть снимок» тут намеренно НЕТ: там, где под машиной
        // тайлов нет вовсе (сеть молчала, sha не сошлась), snapshotKeys
        // остаётся пустым — и гейт, зависящий от него, не срабатывал бы
        // никогда, то есть ровно в самом плохом случае мы бы и работали
        // каждую секунду. Пересборку снимка после долетевшего тайла даёт
        // finish(), он же сбрасывает lastEnsureAt.
        if let last = lastEnsureAt, downloading.isEmpty,
           GeoMath.fastDistance(last.latitude, last.longitude,
                                coordinate.latitude, coordinate.longitude) < 1000 {
            return
        }
        lastEnsureAt = coordinate
        // Тайлы, которых нет в подписанном индексе, не существуют и не
        // запрашиваются: индекс — единственный источник правды о наборе.
        let wanted = Set(coverageKeys(around: coordinate, index: index))

        var missing: [String] = []
        for key in wanted where !isLoaded(key) && !broken.contains(key)
            && !downloading.contains(key) {
            missing.append(key)
        }
        for key in missing {
            downloading.insert(key)
            Task { await load(key: key, expected: index.tiles[key]!) }
        }
        // Снимок пересобирается, когда состав окрестности изменился и всё,
        // что можно было получить, получено.
        let ready = wanted.filter { isLoaded($0) }
        if missing.isEmpty, downloading.isEmpty, ready != snapshotKeys {
            rebuildSnapshot(keys: ready)
        }
    }

    /// Какие файлы нужны вокруг точки.
    ///
    /// В старом формате это девять тайлов окрестности. В новом у каждого тайла
    /// три набора, и берём мы не все: костяк и улицы нужны всегда, дворовые
    /// проезды — только когда схема их показывает. Половина всех дорог
    /// перестаёт ехать на телефон ради случая, который наступает под конец
    /// поездки.
    private func coverageKeys(around coordinate: CLLocationCoordinate2D,
                              index: RoadTiles.Index) -> [String] {
        let tiles = RoadTiles.neighborhood(of: coordinate,
                                           tileDegrees: index.tileDegrees)
        guard index.version >= RoadTiles.formatVersionV2 else {
            return tiles.filter { index.tiles[$0] != nil }
        }
        return tiles.flatMap { tile in
            wantedSets.map { RoadTiles.setKey(tile, $0) }
        }.filter { index.tiles[$0] != nil }
    }

    /// Тайл: сперва диск, затем сеть; в обоих случаях sha256 сверяется с
    /// подписанным индексом, несходство — «тайла нет», не «сойдёт и так».
    private func load(key: String, expected: RoadTiles.Index.TileMeta) async {
        defer { downloading.remove(key) }
        let fileURL = directory.appendingPathComponent(
            RoadTiles.fileName(key: key, version: indexVersion))

        let set = Self.setOf(key)
        let fromDisk = await Task.detached(priority: .utility) { () -> Decoded? in
            guard let data = try? Data(contentsOf: fileURL),
                  RoadTiles.sha256Hex(of: data) == expected.sha256 else { return nil }
            return Self.decode(data, as: set)
        }.value
        if let fromDisk {
            // Снять с полёта ДО finish, а не в defer на выходе: finish
            // собирает снимок только когда полёт пуст, а defer срабатывает
            // позже него — то есть на последнем тайле пачки снимок не
            // собирался никогда.
            downloading.remove(key)
            finish(key: key, decoded: fromDisk)
            return
        }

        guard let data = try? await api.getData(
            "roads/" + RoadTiles.fileName(key: key, version: indexVersion)) else {
            // Сеть — не приговор: попробуем при следующем ensureCoverage.
            return
        }
        let directory = self.directory
        let decoded = await Task.detached(priority: .utility) { () -> Decoded? in
            guard RoadTiles.sha256Hex(of: data) == expected.sha256,
                  let value = Self.decode(data, as: set) else { return nil }
            do {
                try FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                Log.route.error("тайл дорог не записался: \(error.localizedDescription, privacy: .public)")
            }
            return value
        }.value
        guard let decoded else {
            broken.insert(key)
            Log.route.error("тайл дорог \(key, privacy: .public) не сошёлся по sha или формату — отброшен")
            return
        }
        downloading.remove(key)
        finish(key: key, decoded: decoded)
    }

    // MARK: - Адреса

    /// Файл адресов города: с диска, иначе с сервера, и в обоих случаях sha256
    /// сверяется с подписанным индексом.
    ///
    /// Отдельным входом, а не через покрытие: адреса не окрестность. Их просят
    /// один раз на город и по имени клетки, а не по рамке экрана, поэтому
    /// ensureCoverage о них ничего не знает и знать не должен.
    ///
    /// nil — «адресов нет»: индекс их не знает, сеть не ответила или файл не
    /// сошёлся по подписи. Честный пустой ответ здесь лучше половины списка:
    /// поиск после него уходит к Apple, а не показывает неполный город как
    /// полный.
    func addressBook(for coordinate: CLLocationCoordinate2D) async -> AddressBook? {
        let key = AddressBook.key(for: coordinate)
        guard indexVersion >= RoadTiles.formatVersionV2,
              let expected = index?.tiles[key], !broken.contains(key)
        else { return nil }

        let fileURL = directory.appendingPathComponent(
            RoadTiles.fileName(key: key, version: indexVersion))
        if let fromDisk = await Task.detached(priority: .utility, operation: {
            () -> AddressBook? in
            guard let data = try? Data(contentsOf: fileURL),
                  RoadTiles.sha256Hex(of: data) == expected.sha256 else { return nil }
            return AddressBook.decode(data)
        }).value {
            return fromDisk
        }

        guard let data = try? await api.getData(
            "roads/" + RoadTiles.fileName(key: key, version: indexVersion))
        else { return nil }
        let directory = self.directory
        let decoded = await Task.detached(priority: .utility) { () -> AddressBook? in
            guard RoadTiles.sha256Hex(of: data) == expected.sha256,
                  let book = AddressBook.decode(data) else { return nil }
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                Log.route.error("адреса не записались: \(error.localizedDescription, privacy: .public)")
            }
            return book
        }.value
        if decoded == nil {
            broken.insert(key)
            Log.route.error("адреса \(key, privacy: .public) не сошлись по sha или формату — отброшены")
        }
        return decoded
    }

    /// Что лежит в наборе: дороги или местность.
    private nonisolated enum Decoded {
        case roads([RoadLine])
        case areas([SketchArea])
        case points([SketchPoint])
    }

    /// Тайл уже разобран и лежит в памяти.
    ///
    /// Проверять один `loaded` нельзя: туда попадают только ДОРОЖНЫЕ наборы, а
    /// местность и точки живут в своих словарях. Пока здесь стояло
    /// `loaded[key] == nil`, любой недорожный тайл считался недостающим ВСЕГДА
    /// — он скачивался, разбирался, ложился в свой словарь и на следующем
    /// тике запрашивался снова. А так как список недостающих никогда не
    /// пустел, снимок окрестности не пересобирался вовсе: схема всю дорогу
    /// рисовалась запасной сетью из индекса лимитов, и ни вода, ни зелень, ни
    /// кварталы, ни светофоры на неё не попадали ни разу.
    private func isLoaded(_ key: String) -> Bool {
        guard let set = Self.setOf(key) else { return loaded[key] != nil }
        if set.isPoints { return loadedPoints[key] != nil || loadedPointsFar[key] != nil }
        if set.isArea { return loadedAreas[key] != nil }
        return loaded[key] != nil
    }

    /// Набор по составному ключу «тайл_набор». nil — старый формат.
    private nonisolated static func setOf(_ key: String) -> RoadTiles.Set? {
        guard let suffix = key.split(separator: "_").last else { return nil }
        return RoadTiles.Set(rawValue: String(suffix))
    }

    private nonisolated static func decode(_ data: Data,
                                           as set: RoadTiles.Set?) -> Decoded? {
        if set?.isPoints == true {
            return RoadTiles.decodePoints(data).map(Decoded.points)
        }
        if set?.isArea == true {
            return RoadTiles.decodeAreas(data).map(Decoded.areas)
        }
        return RoadTiles.decodeTile(data).map(Decoded.roads)
    }

    private func finish(key: String, decoded: Decoded) {
        switch decoded {
        case .roads(let lines): loaded[key] = lines
        case .areas(let shapes): loadedAreas[key] = shapes
        case .points(let marks):
            if Self.setOf(key) == .pointsFar { loadedPointsFar[key] = marks }
            else { loadedPoints[key] = marks }
        }
        // Состав окрестности изменился — следующий тик обязан пройти гейт,
        // иначе новый тайл ждал бы километра пути.
        lastEnsureAt = nil
        // Снимок собираем один раз, когда долетела вся пачка; следующий
        // ensureCoverage сузит его до окрестности и выселит дальние тайлы.
        guard downloading.isEmpty else { return }
        rebuildSnapshot(keys: Set(loaded.keys).union(loadedAreas.keys)
            .union(loadedPoints.keys).union(loadedPointsFar.keys))
    }

    private func rebuildSnapshot(keys: Set<String>) {
        // Дальние тайлы — вон из памяти (файлы остаются на диске).
        //
        // Порог считается ОТ РАЗМЕРА ОКРЕСТНОСТИ, а не константой в двенадцать.
        // Константа была верна, пока на тайл приходился один файл: девять
        // тайлов покрытия плюс запас. В новом формате файлов три на тайл, то
        // есть окрестность сама по себе от восемнадцати до двадцати семи, —
        // порог срабатывал бы всегда, и запас, ради которого он и написан,
        // исчез бы: разворот через границу тайла заставлял бы перечитывать
        // файлы с диска заново.
        if loaded.count + loadedAreas.count + loadedPoints.count
            + loadedPointsFar.count > keys.count + 9 {
            for key in loaded.keys where !keys.contains(key) {
                loaded.removeValue(forKey: key)
            }
            for key in loadedAreas.keys where !keys.contains(key) {
                loadedAreas.removeValue(forKey: key)
            }
            for key in loadedPoints.keys where !keys.contains(key) {
                loadedPoints.removeValue(forKey: key)
            }
            for key in loadedPointsFar.keys where !keys.contains(key) {
                loadedPointsFar.removeValue(forKey: key)
            }
        }
        snapshotKeys = keys
        // Костяк района собирается отдельным снимком: на дальнем охвате схема
        // берёт его вместо обычной сети — там раздельные проезжие уже сведены
        // в одну ось, и мелочи нет вовсе.
        let isV2 = indexVersion >= RoadTiles.formatVersionV2
        let farSuffix = "_" + RoadTiles.Set.far.rawValue
        let nearTiles = keys.filter { !isV2 || !$0.hasSuffix(farSuffix) }
            .compactMap { loaded[$0] }
        let farTiles = isV2 ? keys.filter { $0.hasSuffix(farSuffix) }.compactMap { loaded[$0] }
                            : []
        areas = keys.compactMap { loadedAreas[$0] }.flatMap { $0 }
        points = keys.compactMap { loadedPoints[$0] }.flatMap { $0 }
        farPoints = keys.compactMap { loadedPointsFar[$0] }.flatMap { $0 }
        Task.detached(priority: .utility) { [nearTiles, farTiles] in
            let near = TileRoadNetwork.build(nearTiles)
            let far = farTiles.isEmpty ? nil : TileRoadNetwork.build(farTiles)
            await MainActor.run {
                self.network = CachedRoadNetwork(near)
                if let far {
                    self.farNetwork = CachedRoadNetwork(far)
                } else {
                    self.farNetwork = EmptyRoadNetwork()
                }
                self.revision += 1
                Log.route.info("сеть дорог: \(near.lines.count) линий, костяк \(far?.lines.count ?? 0)")
            }
        }
    }
}
