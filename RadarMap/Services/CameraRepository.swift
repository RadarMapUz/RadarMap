//
//  CameraRepository.swift
//  RadarMap
//
//  Источник данных о камерах: база из cameras.json + свои (локально) − скрытые.
//  Свои камеры и скрытые id сохраняются в Documents/user_cameras.json.
//

import Foundation
import CoreLocation
import MapKit
import Observation
import os

protocol CameraRepository {
    var cameras: [Camera] { get }
    /// База прочитана: до этого пустой `cameras` не значит «камер нет».
    var isDatabaseLoaded: Bool { get }
    func nearest(to coordinate: CLLocationCoordinate2D, limit: Int) -> [Camera]
    func cameras(in region: MKCoordinateRegion, limit: Int) -> [Camera]
}

@MainActor
@Observable
final class CameraStore: CameraRepository {

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
    private var bundled: [Camera] = []
    private(set) var loadError: String?

    private(set) var custom: [Camera] = []
    private(set) var hiddenIDs: Set<Int> = []
    /// Передвижные радары с сервера (краудсорсинг), живут несколько часов.
    private(set) var mobile: [Camera] = []

    /// Растёт при любом изменении данных (загрузка/добавление/скрытие) — UI подписывается на это.
    private(set) var revision = 0

    /// Кэш объединённого списка: пересобирается только при изменении данных,
    /// а не при каждом обращении (горячий путь: retile, ближайшие, вход в зону).
    @ObservationIgnored private var mergedCache: [Camera]?
    /// Пространственный индекс: ячейка 0.05° (~5.5 км) → индексы камер в merged-списке.
    /// Запросы «в области» и «ближайшие» не сканируют все 3341 камеры, а берут пару ячеек.
    @ObservationIgnored private var gridCache: [Int: [Int]]?

    /// Правки модератора поверх базы (overrides.json). Применяются только к
    /// базе: свои камеры — дело пользователя, передвижные модерируются на
    /// сервере напрямую, там правка мгновенна и подписи не требует.
    private(set) var overrides: CameraOverrides = .empty

    /// Итоговый набор для карты и оповещений:
    /// база + правки модератора + свои + передвижные, без скрытых пользователем.
    var cameras: [Camera] {
        if let mergedCache { return mergedCache }
        let base = CameraOverrideEngine.apply(overrides, to: bundled).cameras
        let merged = (base + custom + mobile).filter { !hiddenIDs.contains($0.id) }
        mergedCache = merged
        return merged
    }

    // MARK: - Пространственный индекс

    nonisolated private static let gridCellDegrees = 0.05

    nonisolated private static func cellKey(latCell: Int, lonCell: Int) -> Int {
        latCell * 8000 + lonCell
    }
    nonisolated private static func cellOf(lat: Double, lon: Double) -> (Int, Int) {
        (Int((lat + 90) / gridCellDegrees), Int((lon + 180) / gridCellDegrees))
    }

    private func grid() -> [Int: [Int]] {
        if let gridCache { return gridCache }
        var built: [Int: [Int]] = [:]
        built.reserveCapacity(cameras.count / 2)
        for (index, camera) in cameras.enumerated() {
            let (latCell, lonCell) = Self.cellOf(lat: camera.lat, lon: camera.lon)
            built[Self.cellKey(latCell: latCell, lonCell: lonCell), default: []].append(index)
        }
        gridCache = built
        return built
    }

    /// Обновить список передвижных радаров (вызывается MobileCameraService).
    ///
    /// Сравниваем по СОДЕРЖИМОМУ, а не через `==` списков: `Camera` равна по
    /// одному id (см. Camera.swift), и уточнение типа отметки (amend — сервер
    /// переписывает ТУ ЖЕ строку) или её подтверждение независимым водителем
    /// меняли только тип и `mobileConfirmed`, а id оставляли прежним. Для
    /// такого списка `==` возвращал true, и обновление до карты не доезжало:
    /// призрак-маркер оставался призраком, а «тренога» на экране — «радаром».
    /// Изменение двигает и `revision`, и `mobileRevision`: по второй
    /// AppEnvironment.observeCameraRevision оценивает тревогу сразу — новая
    /// чужая отметка не ждёт ни экрана, ни ретайла.
    @discardableResult
    func setMobileCameras(_ cameras: [Camera]) -> Bool {
        let changed = cameras.count != mobile.count
            || zip(cameras, mobile).contains { new, old in
                new.id != old.id || new.type != old.type
                    || new.mobileConfirmed != old.mobileConfirmed
                    || new.lat != old.lat || new.lon != old.lon
                    // Сервер продлил срок — новая подпись и новый срок гашения.
                    || new.mobileExpires != old.mobileExpires || new.location != old.location
            }
        guard changed else { return false }
        mobile = cameras
        mobileRevision &+= 1
        dataChanged()
        return true
    }

    /// Растёт только при смене чужих отметок (см. setMobileCameras).
    @ObservationIgnored private(set) var mobileRevision = 0

    nonisolated private static let firstCustomID = 1_000_001

    /// Версия активной базы (встроенная = bundledDBVersion; после OTA — версия с сервера).
    private(set) var dbVersion: Int =
        Storage.intIfPresent(.cameraDBVersion) ?? AppConfig.bundledDBVersion

    /// База прочитана (декод асинхронный): до этого `cameras` пуст не потому,
    /// что камер нет.
    @ObservationIgnored private(set) var isDatabaseLoaded = false

    /// Первая загрузка базы завершена (декод асинхронный). Для одноразовых
    /// миграций, которым нужны данные камер: вызов в момент сборки сервисов
    /// пришёлся бы на пустой список.
    @ObservationIgnored var onDatabaseLoaded: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onDatabaseLoaded,
                                               "CameraRepository.onDatabaseLoaded") }
    }

    init() {
        loadUserData()
        let downloadedVersion = Storage.intIfPresent(.cameraDBVersion) ?? 0
        // Декодируем JSON вне главного потока — не блокируем первый кадр.
        Task { [weak self] in
            let result = await Self.decodeDatabase(downloadedVersion: downloadedVersion)
            guard let self else { return }
            self.bundled = result.cameras
            self.loadError = result.error
            self.loadOverrides()   // правки применяются к базе — только после неё
            if !result.usedRemote && self.dbVersion != AppConfig.bundledDBVersion {
                // Скачанная копия испорчена, удалена или устарела относительно
                // встроенной — честно откатываемся на версию из бандла.
                self.dbVersion = AppConfig.bundledDBVersion
                Storage.remove(.cameraDBVersion)
            }
            self.dataChanged()
            self.isDatabaseLoaded = true
            self.onDatabaseLoaded?()
        }
    }

    /// Файл базы, скачанной с сервера (переживает обновления приложения).
    nonisolated private static var remoteFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cameras_remote.json")
    }

    // @concurrent обязателен: при NonisolatedNonsendingByDefault обычный nonisolated async
    // исполнялся бы на акторе вызывающего — то есть декодировал 3341 камеру на главном потоке.
    @concurrent private static func decodeDatabase(downloadedVersion: Int) async
        -> (cameras: [Camera], error: String?, usedRemote: Bool) {
        // 1) Скачанная с сервера копия — но только если она НЕ старше встроенной.
        // Иначе после обновления приложения телефон навсегда оставался бы на
        // данных, скачанных до апдейта: свежая база из бандла просто игнорировалась
        // (а в ней могут быть новые поля — направление дороги, полосы, класс).
        if downloadedVersion >= AppConfig.bundledDBVersion,
           let decoded = JSONFile.load([Camera].self, from: remoteFileURL, log: Log.cameras),
           decoded.count >= 100 {
            return (decoded, nil, true)
        }
        if downloadedVersion > 0, downloadedVersion < AppConfig.bundledDBVersion {
            Log.cameras.notice("скачанная база v\(downloadedVersion, privacy: .public) старше встроенной v\(AppConfig.bundledDBVersion, privacy: .public) — берём встроенную")
            try? FileManager.default.removeItem(at: remoteFileURL)
        }
        // 2) встроенная база — её отсутствие означает битую сборку, кричим громко
        guard let url = Bundle.main.url(forResource: "cameras", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Camera].self, from: data) else {
            Log.cameras.fault("встроенная cameras.json не читается — приложение без базы")
            return ([], String(localized: "Встроенная база камер не читается — переустановите приложение."), false)
        }
        return (decoded, nil, false)
    }

    // MARK: - Правки модератора

    /// Файл правок, скачанный с сервера (переживает обновления приложения).
    nonisolated private static var overridesFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("camera_overrides.json")
    }

    /// Поднять сохранённые правки. Зовётся сразу после загрузки базы: правки
    /// без базы применять не к чему, а проверка правдоподобия считает долю от
    /// её размера.
    private func loadOverrides() {
        guard let stored = JSONFile.load(CameraOverrides.self,
                                         from: Self.overridesFileURL, log: Log.cameras),
              CameraOverrideEngine.isSane(stored, baseCount: bundled.count) else { return }
        overrides = stored
    }

    /// Применить свежий файл правок. Возвращает `false`, если файл отвергнут —
    /// тогда остаёмся на прежних правках, а не «ни на каких»: полпути здесь
    /// хуже, чем оба конца.
    @discardableResult
    func applyOverrides(_ fresh: CameraOverrides) -> Bool {
        guard CameraOverrideEngine.isSane(fresh, baseCount: bundled.count) else {
            Log.cameras.fault("правки отвергнуты: скрывают слишком много камер (\(fresh.items.count, privacy: .public) записей на \(self.bundled.count, privacy: .public) камер)")
            return false
        }
        guard fresh != overrides else { return true }
        overrides = fresh
        // Вне main и по порядку (как история поездок): запись правок не должна
        // стоять в кадре применения (правило 11).
        JSONFile.saveOrdered(fresh, to: Self.overridesFileURL, log: Log.cameras, wait: false)
        let result = CameraOverrideEngine.apply(fresh, to: bundled)
        Log.cameras.notice("правки v\(fresh.version, privacy: .public): скрыто \(result.hidden, privacy: .public), сдвинуто \(result.moved, privacy: .public), переопределено \(result.retyped, privacy: .public), отвергнуто \(result.rejected, privacy: .public)")
        dataChanged()
        return true
    }

    /// Применить скачанное обновление базы: валидация → атомарная запись → подмена в памяти.
    func applyRemote(data: Data, version: Int) async throws(RemoteDBError) -> Int {
        let decoded: [Camera]
        do throws(any Error) {
            decoded = try await offMain {
                try JSONDecoder().decode([Camera].self, from: data)
            }
        } catch {
            // Путь ключа (codingPath) — ровно то, что нужно, когда сборка не
            // разбирает подписанную базу.
            throw .undecodable(String(describing: error))
        }
        guard decoded.count >= 100 else { throw .incomplete(count: decoded.count) }
        // Запись ~1 МБ атомарно (temp + rename) — вне main, как декод выше:
        // на применении OTA она подвешивала кадр.
        let url = Self.remoteFileURL
        do throws(any Error) {
            try await offMain {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
        bundled = decoded
        dbVersion = version
        Storage.set(version, for: .cameraDBVersion)
        dataChanged()
        return decoded.count
    }

    private func dataChanged() {
        mergedCache = nil
        gridCache = nil
        revision += 1
    }

    // MARK: - Запросы

    /// Ближайшие камеры: расширяющиеся кольца ячеек индекса вместо сортировки всех 3341
    /// (и без аллокаций CLLocation — критично для ретайлинга на каждом км пути).
    func nearest(to coordinate: CLLocationCoordinate2D, limit: Int) -> [Camera] {
        let all = cameras
        guard !all.isEmpty else { return [] }
        let index = grid()
        let (centerLat, centerLon) = Self.cellOf(lat: coordinate.latitude, lon: coordinate.longitude)

        var candidates: [Int] = []
        var ring = 0
        let maxRing = 60   // 60 × 0.05° ≈ 330 км — дальше камер точно нет смысла искать
        while ring <= maxRing {
            // Ячейки на чебышёвском расстоянии == ring (рамка кольца).
            for latCell in (centerLat - ring)...(centerLat + ring) {
                for lonCell in (centerLon - ring)...(centerLon + ring)
                where max(abs(latCell - centerLat), abs(lonCell - centerLon)) == ring {
                    if let found = index[Self.cellKey(latCell: latCell, lonCell: lonCell)] {
                        candidates.append(contentsOf: found)
                    }
                }
            }
            // Набрали достаточно — добираем ещё одно кольцо (камера у границы ячейки
            // может быть ближе, чем найденные) и выходим.
            if candidates.count >= limit {
                ring += 1
                for latCell in (centerLat - ring)...(centerLat + ring) {
                    for lonCell in (centerLon - ring)...(centerLon + ring)
                    where max(abs(latCell - centerLat), abs(lonCell - centerLon)) == ring {
                        if let found = index[Self.cellKey(latCell: latCell, lonCell: lonCell)] {
                            candidates.append(contentsOf: found)
                        }
                    }
                }
                break
            }
            ring += 1
        }

        return candidates
            .map { (all[$0], GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                                  all[$0].lat, all[$0].lon)) }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    func cameras(in region: MKCoordinateRegion, limit: Int) -> [Camera] {
        let latMin = region.center.latitude  - region.span.latitudeDelta  / 2
        let latMax = region.center.latitude  + region.span.latitudeDelta  / 2
        let lonMin = region.center.longitude - region.span.longitudeDelta / 2
        let lonMax = region.center.longitude + region.span.longitudeDelta / 2

        // Область → ячейки индекса; при гигантской области (десятки тысяч ячеек)
        // дешевле пройтись по списку целиком.
        let all = cameras
        let (loLat, loLon) = Self.cellOf(lat: latMin, lon: lonMin)
        let (hiLat, hiLon) = Self.cellOf(lat: latMax, lon: lonMax)
        let cellCount = (hiLat - loLat + 1) * (hiLon - loLon + 1)

        var visible: [Camera] = []
        if cellCount <= 6000 {
            let index = grid()
            for latCell in loLat...hiLat {
                for lonCell in loLon...hiLon {
                    guard let found = index[Self.cellKey(latCell: latCell, lonCell: lonCell)] else { continue }
                    for i in found {
                        let camera = all[i]
                        if camera.lat >= latMin, camera.lat <= latMax,
                           camera.lon >= lonMin, camera.lon <= lonMax {
                            visible.append(camera)
                        }
                    }
                }
            }
        } else {
            visible = all.filter {
                $0.lat >= latMin && $0.lat <= latMax && $0.lon >= lonMin && $0.lon <= lonMax
            }
        }

        guard visible.count > limit else { return visible }
        return visible
            .map { ($0, GeoMath.fastDistance(region.center.latitude, region.center.longitude,
                                             $0.lat, $0.lon)) }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: - Свои камеры

    @discardableResult
    func addCamera(at coordinate: CLLocationCoordinate2D, type: CameraType, label: String) -> Camera {
        ensureUserDataLoaded()
        let id = (custom.map(\.id).max() ?? (Self.firstCustomID - 1)) + 1
        let violations: [String] = type == .stationaryRadar
            ? ["тезликни ошириш"]
            : ["тезликни ошириш", "қизил чироқда ўтиш"]
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let camera = Camera(
            id: id,
            region: String(localized: "Моя камера"),
            city: "",
            location: name.isEmpty ? String(localized: "Добавлено вручную") : name,
            lat: coordinate.latitude,
            lon: coordinate.longitude,
            type: type.sourceString,
            violations: violations,
            needsReview: nil
        )
        custom.append(camera)
        dataChanged()
        persist()
        return camera
    }

    func deleteCustom(_ camera: Camera) {
        ensureUserDataLoaded()
        custom.removeAll { $0.id == camera.id }
        dataChanged()
        persist()
    }

    /// Влить восстановленное из копии: свои камеры и скрытые. Слияние сделано
    /// чистым движком (TripBackupMerge) — здесь только присвоение и запись.
    func applyRestored(custom: [Camera], hidden: Set<Int>) {
        self.custom = custom
        self.hiddenIDs = hidden
        dataChanged()
        persist()
    }

    func isCustom(_ camera: Camera) -> Bool { camera.id >= Self.firstCustomID }

    // MARK: - Скрытие / жалоба

    func hide(_ camera: Camera) {
        ensureUserDataLoaded()
        hiddenIDs.insert(camera.id)
        dataChanged()
        persist()
    }

    func unhide(id: Int) {
        ensureUserDataLoaded()
        hiddenIDs.remove(id)
        dataChanged()
        persist()
    }

    /// Вернуть все скрытые разом — в том числе те, чьих точек уже нет в
    /// наборе (передвижная истекла, камеру убрал модератор).
    func unhideAll() {
        ensureUserDataLoaded()
        guard !hiddenIDs.isEmpty else { return }
        hiddenIDs.removeAll()
        dataChanged()
        persist()
    }

    /// Скрытые пользователем камеры — для списка в настройках. Скрытая камера
    /// молчит, поэтому вернуть её должно быть так же просто, как скрыть: до
    /// этого списка `unhide` не звал ни один экран, и скрытие было навсегда.
    var hiddenCameras: [Camera] {
        guard !hiddenIDs.isEmpty else { return [] }
        let base = CameraOverrideEngine.apply(overrides, to: bundled).cameras
        return (base + custom + mobile)
            .filter { hiddenIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
    }

    // MARK: - Хранение

    private nonisolated struct UserData: Codable, Sendable {
        var custom: [Camera]
        var hidden: [Int]
    }

    private var storeURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("user_cameras.json")
    }

    /// Свои камеры и скрытые не прочитались (файл защищён до разблокировки):
    /// пока не прочтём, не пишем — иначе затрём их (сценарий S9, 20.10).
    @ObservationIgnored private var userDataUnreadable = false

    private func loadUserData() {
        switch JSONFile.loadChecked(UserData.self, from: storeURL, log: Log.cameras) {
        case .missing:
            userDataUnreadable = false
        case .loaded(let decoded):
            custom = decoded.custom
            hiddenIDs = Set(decoded.hidden)
            userDataUnreadable = false
        case .corrupt:
            userDataUnreadable = !JSONFile.setAside(storeURL, log: Log.cameras)
        case .unreadable:
            userDataUnreadable = true
        }
    }

    /// Прочитать свои камеры, если на старте файл не читался (до первой
    /// разблокировки): перед любой правкой — иначе id новой совпал бы с
    /// существующей на диске, и одна из них потерялась бы (ревью S9).
    private func ensureUserDataLoaded() {
        guard userDataUnreadable else { return }
        // Добавленное, пока файл не читался, — поверх прочитанного, а не
        // вместо: иначе правка окна пропадала при первом чтении (ревью S9).
        let added = custom, hidden = hiddenIDs
        loadUserData()
        guard !userDataUnreadable else { return }
        if !added.isEmpty || !hidden.isEmpty {
            custom = Self.merged(custom, added)
            hiddenIDs.formUnion(hidden)
            JSONFile.saveOrdered(UserData(custom: custom, hidden: Array(hiddenIDs)),
                                 to: storeURL, log: Log.cameras, wait: false)
        }
        dataChanged()
    }

    /// Вернулись на экран — свои камеры, не прочитанные на старте, сейчас:
    /// иначе до первой правки они не предупреждали бы, а скрытые звучали.
    func reloadUserDataIfNeeded() {
        ensureUserDataLoaded()
    }

    private func persist() {
        if userDataUnreadable {
            // Ещё раз: к моменту правки файл мог стать доступен (и тогда
            // ensureUserDataLoaded сам допишет правку поверх прочитанного).
            ensureUserDataLoaded()
            if userDataUnreadable {
                Log.cameras.error("свои камеры не записаны: файл ещё не читается")
            }
            return
        }
        JSONFile.saveOrdered(UserData(custom: custom, hidden: Array(hiddenIDs)),
                             to: storeURL, log: Log.cameras, wait: false)
    }

    /// Свои с диска плюс добавленные, пока файл не читался. Совпавший id —
    /// новая камера, а не та же: ей — свободный id, а не молча выбросить.
    nonisolated static func merged(_ disk: [Camera], _ memory: [Camera]) -> [Camera] {
        var used = Set(disk.map(\.id))
        var next = max(firstCustomID, (disk.map(\.id).max() ?? 0) + 1)
        var result = disk
        for camera in memory {
            // Та же камера — по содержанию: `==` у Camera сравнивает только id,
            // и столкнувшийся id просто выбрасывал новую (ревью S9).
            if disk.contains(where: { $0.id == camera.id && $0.lat == camera.lat && $0.lon == camera.lon }) {
                continue
            }
            var copy = camera
            if used.contains(copy.id) {
                while used.contains(next) { next += 1 }
                copy = copy.withID(next)
            }
            used.insert(copy.id)
            result.append(copy)
        }
        return result
    }
}

/// Почему OTA-база не применена. Дефект самого файла (не разбирается, камер
/// мало) — этот файл не качать снова; сбой записи на телефоне (место) — не
/// дефект базы, её можно взять позже (ревью S23, 20.10).
nonisolated enum RemoteDBError: Error, Equatable {
    case undecodable(String)
    case incomplete(count: Int)
    case writeFailed(String)

    var isPayloadDefect: Bool {
        if case .writeFailed = self { return false }
        return true
    }
}
