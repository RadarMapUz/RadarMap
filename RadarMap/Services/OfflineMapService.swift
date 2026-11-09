//
//  OfflineMapService.swift
//  RadarMap
//
//  Офлайн-карты: скачать область целиком, чтобы карта рисовалась без связи
//  (трасса Ташкент — Бухара часами без сети). docs/plan_map_offline.md §2.3/§2.7.
//
//  Что приходит с сервера, применяется без участия человека — значит, по
//  правилу 19: каталог (`regions.json`) проверяется подписью при КАЖДОМ
//  чтении, включая копию с диска; файл региона принимается, только если
//  sha256 всего файла сошёлся с подписанным каталогом. Не сошлось — файл
//  удаляется, прежняя версия (если была) остаётся.
//
//  Карта переключается на файлы региона только БЕЗ связи и только внутри
//  скачанной области (EngineModernStyle, `pmtiles://file://`). Со связью —
//  обычный онлайн: так свежесть выпусков не зависит от того, когда человек
//  последний раз обновлял регион.
//

import CoreLocation
import CryptoKit
import Foundation
import Observation
import os

/// Локальные файлы региона для стиля движка.
nonisolated struct OfflineFiles: Equatable, Sendable {
    let omt: URL
    let mvt: URL
}

@Observable
final class OfflineMapService {

    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей
    /// (см. MapState).
    nonisolated deinit {}

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case updateAvailable
        case failed(String)
    }

    /// Что установлено: версия набора и имена файлов по виду («mvt», «omt»).
    struct Installed: Codable, Equatable {
        let version: Int
        let files: [String: String]
    }

    private(set) var catalog: RegionCatalog?
    private(set) var installed: [String: Installed] = [:]
    private(set) var progress: [String: Double] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var isLoadingCatalog = false

    @ObservationIgnored private let api = APIClient(timeout: 30, resourceTimeout: 1800)
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Область установлена: середины её клеток поиска, скачать адреса и
    /// заведения. Ставит AppEnvironment.
    @ObservationIgnored var onSearchCellsNeeded: (([CLLocationCoordinate2D]) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onSearchCellsNeeded,
                                               "OfflineMapService.onSearchCellsNeeded") }
    }

    init() {
        installed = JSONFile.load([String: Installed].self, from: Self.manifestURL, log: Log.network) ?? [:]
        // Каталога нет — первый запуск; битый отсеет подпись в verify.
        if let data = try? Data(contentsOf: Self.catalogURL) {
            catalog = Self.verify(data)
        }
    }

    // MARK: - Каталог

    /// Свежий каталог с сервера. Ошибка — остаёмся на проверенной копии.
    func refreshCatalog() async {
        guard !isLoadingCatalog else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            let data = try await api.getData(AppConfig.offlineRegionsPath,
                                             cachePolicy: .reloadIgnoringLocalCacheData)
            guard let fresh = Self.verify(data) else {
                Log.network.error("каталог офлайн-регионов не прошёл проверку подписи")
                return
            }
            catalog = fresh
            try Self.ensureDirectory()
            try data.write(to: Self.catalogURL, options: .atomic)
        } catch {
            Log.network.error("каталог офлайн-регионов не пришёл: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func verify(_ data: Data) -> RegionCatalog? {
        // Битый конверт — nil; сетевой путь пишет «не прошёл проверку подписи» сам.
        guard let envelope = try? JSONDecoder().decode(SignedPayload<RegionCatalog>.self, from: data),
              let catalog = envelope.verified(), !catalog.regions.isEmpty else { return nil }
        return catalog
    }

    // MARK: - Состояние

    func state(for region: RegionCatalog.Region) -> State {
        if let fraction = progress[region.id] { return .downloading(fraction) }
        if let message = errors[region.id] { return .failed(message) }
        guard let have = installed[region.id] else { return .notDownloaded }
        if let catalog, have.version < catalog.version { return .updateAvailable }
        return .ready
    }

    var usedBytes: Int64 {
        installed.values.flatMap(\.files.values).reduce(0) { total, name in
            // Файла нет — 0 байт: это подпись в настройках, а не проверка целостности.
            let size = (try? Self.directory.appendingPathComponent(name)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    /// Регион точки (дом, текущее место) — его предлагаем первым.
    func region(containing coordinate: CLLocationCoordinate2D?) -> RegionCatalog.Region? {
        guard let coordinate else { return nil }
        return catalog?.region(containing: coordinate)
    }

    /// Файлы для карты без связи: точка внутри скачанного региона, оба файла на месте.
    ///
    /// Ответ по региону кэшируется: без сети карта машины спрашивала это на
    /// КАЖДЫЙ тик GPS, и каждый раз — два stat() на главном потоке. Кэш
    /// сбрасывается при любой смене установленного (download/remove).
    func offlineFiles(at coordinate: CLLocationCoordinate2D) -> OfflineFiles? {
        guard let region = catalog?.region(containing: coordinate) else { return nil }
        if let cached = offlineFilesCache[region.id] { return cached }
        let files: OfflineFiles?
        if let have = installed[region.id],
           let omt = have.files["omt"], let mvt = have.files["mvt"] {
            let omtURL = Self.directory.appendingPathComponent(omt)
            let mvtURL = Self.directory.appendingPathComponent(mvt)
            files = FileManager.default.fileExists(atPath: omtURL.path)
                && FileManager.default.fileExists(atPath: mvtURL.path)
                ? OfflineFiles(omt: omtURL, mvt: mvtURL) : nil
        } else {
            files = nil
        }
        offlineFilesCache[region.id] = .some(files)
        return files
    }
    /// Регион → файлы (или честное «нет»). Optional внутри Optional: «нет»
    /// тоже кэшируется, иначе регион без файлов проверялся бы на каждый тик.
    @ObservationIgnored private var offlineFilesCache: [String: OfflineFiles?] = [:]

    /// Середины клеток поиска всех установленных областей.
    var installedSearchCells: [CLLocationCoordinate2D] {
        guard let catalog else { return [] }
        return catalog.regions.filter { installed[$0.id] != nil }
            .flatMap { $0.searchCellCenters(cellZoom: catalog.cellZoom) }
    }

    // MARK: - Загрузка

    func download(_ region: RegionCatalog.Region) {
        guard tasks[region.id] == nil, catalog != nil else { return }
        errors[region.id] = nil
        progress[region.id] = 0
        let api = self.api
        let id = region.id
        // Прогресс — на главный актор; собственный слабый захват, без
        // изменяемой ссылки из задачи (Swift 6: SendableClosureCaptures).
        let report: @Sendable (Double) -> Void = { [weak self] value in
            guard let owner = self else { return }
            Task { @MainActor in
                // Процент, а не каждый пакет: значение читает SwiftUI.
                guard let old = owner.progress[id], Int(value * 100) != Int(old * 100) else { return }
                owner.progress[id] = value
            }
        }
        tasks[region.id] = Task { [weak self] in
            // Свежий каталог перед загрузкой: на сервере живут только последние
            // версии, и файл по адресу из старого каталога ответил бы 404.
            await self?.refreshCatalog()
            guard let self, let catalog = self.catalog else { return }
            let region = catalog.regions.first { $0.id == id } ?? region
            let total = Double(max(region.totalBytes, 1))
            var done: Int64 = 0
            var saved: [String: String] = [:]
            do {
                for (kind, file) in region.files.sorted(by: { $0.key < $1.key }) {
                    let before = done
                    let temporary = try await api.download(
                        "\(AppConfig.offlineRegionsDirectory)/\(catalog.version)/\(file.file)") { fraction in
                            report((Double(before) + fraction * Double(file.bytes)) / total)
                        }
                    // Проверка — до того, как файл станет картой: sha256 всего
                    // файла против подписанного каталога.
                    let digest = try await Self.sha256(of: temporary)
                    guard digest == file.sha256.lowercased() else {
                        // Временный файл загрузки: не удалился — его уберёт система; ошибка ниже — про sha.
                        try? FileManager.default.removeItem(at: temporary)
                        throw OfflineError.digestMismatch(file.file)
                    }
                    let name = "\(catalog.version)-\(file.file)"
                    try Self.install(temporary, as: name)
                    saved[kind] = name
                    done += file.bytes
                }
                let old = self.installed[region.id]
                self.installed[region.id] = Installed(version: catalog.version, files: saved)
                self.offlineFilesCache[region.id] = nil
                _ = JSONFile.save(self.installed, to: Self.manifestURL, log: Log.network)
                // Прежняя версия — только после того, как новая на месте.
                for name in old?.files.values ?? [:].values where !saved.values.contains(name) {
                    Self.remove(name)
                }
                Log.network.info("офлайн-регион \(region.id, privacy: .public) v\(catalog.version, privacy: .public) установлен")
                self.onSearchCellsNeeded?(region.searchCellCenters(cellZoom: catalog.cellZoom))
            } catch {
                // Недокачанное — не в карту: удаляем то, что успело лечь.
                for name in saved.values {
                    Self.remove(name)
                }
                // Отмена приходит и как URLError.cancelled: «проверьте связь»
                // на собственный ✕ было бы неправдой.
                if error is CancellationError || Task.isCancelled {
                    Log.network.info("загрузка \(region.id, privacy: .public) отменена")
                } else {
                    Log.network.error("офлайн-регион \(region.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    self.errors[region.id] = String(localized: "Не удалось скачать — проверьте связь и попробуйте ещё раз")
                }
            }
            self.progress[region.id] = nil
            self.tasks[region.id] = nil
        }
    }

    func cancel(_ region: RegionCatalog.Region) {
        tasks[region.id]?.cancel()
        tasks[region.id] = nil
        progress[region.id] = nil
    }

    func delete(_ region: RegionCatalog.Region) {
        cancel(region)
        errors[region.id] = nil
        guard let have = installed.removeValue(forKey: region.id) else { return }
        offlineFilesCache[region.id] = nil
        for name in have.files.values {
            Self.remove(name)
        }
        _ = JSONFile.save(installed, to: Self.manifestURL, log: Log.network)
    }

    // MARK: - Диск

    /// Удалить файл региона. Неудача не ломает карту, но оставляет на диске
    /// сотни мегабайт, которых не видно в «Занято», — поэтому в журнал.
    private nonisolated static func remove(_ name: String) {
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        } catch {
            Log.network.error("офлайн-файл \(name, privacy: .public) не удалён: \(error.localizedDescription, privacy: .public)")
        }
    }

    enum OfflineError: LocalizedError {
        case digestMismatch(String)
        var errorDescription: String? {
            switch self {
            case .digestMismatch(let file): return "sha256 не сошёлся: \(file)"
            }
        }
    }

    /// Library/OfflineMaps, а не Application Support: путь уходит в стиль
    /// движка адресом `pmtiles://file://…`, и пробел в «Application Support»
    /// стал бы %20 — проверять, как его раскодирует источник движка, незачем.
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineMaps", isDirectory: true)
    }
    nonisolated static var manifestURL: URL { directory.appendingPathComponent("installed.json") }
    nonisolated static var catalogURL: URL { directory.appendingPathComponent("regions.json") }

    nonisolated static func ensureDirectory() throws {
        var dir = directory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Сотни мегабайт карт не место в резервной копии iCloud: их можно
        // скачать заново, а место в облаке у человека не бесконечно.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
    }

    nonisolated static func install(_ temporary: URL, as name: String) throws {
        try ensureDirectory()
        let target = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
    }

    /// sha256 большого файла кусками по мегабайту — вне главного потока.
    @concurrent nonisolated static func sha256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        // Файл открыт только на чтение: ошибка закрытия ничего не теряет.
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
