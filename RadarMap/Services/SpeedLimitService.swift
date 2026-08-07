//
//  SpeedLimitService.swift
//  RadarMap
//
//  Лимиты скорости дорог (maxspeed из OpenStreetMap, готовит наш сервер).
//  Определяет лимит дороги, по которой едем (позиция + курс), и следит за превышением.
//  База ~3 МБ обновляется раз в неделю и не трогает главный поток при загрузке.
//  Матчинг на GPS-тике стоит ~0,1 мс в плотном центре (замерено
//  PerformanceBudgetTests на сети по статистике боевого файла) — это
//  по-прежнему самая дорогая арифметика тика, и трогать её надо с замером.
//  Прежний комментарий обещал здесь «микросекунды»; на деле их не было
//  никогда — до появления рамки сегмента цена была 0,7 мс.
//

import Foundation
import MapKit
import Observation
import os

@MainActor
@Observable
final class SpeedLimitService {
    /// Лимит дороги, по которой сейчас едем (nil — дорога без данных и
    /// предположить не из чего).
    private(set) var currentLimit: Int?

    /// Лимит не из OSM, а предположен по классу дороги
    /// (`RoadClass.assumedLimitKmh`). Показывается со знаком «≈» и НЕ
    /// превращается в конкретную сумму штрафа: деньги требуют уверенности,
    /// а предположение её не даёт.
    private(set) var isCurrentLimitAssumed = false
    /// Мгновенное превышение — только для подсветки цифры на HUD: флаг щёлкает
    /// на одном GPS-фиксе, а GPS шумит (68 → 71 → 66 при лимите 60).
    private(set) var isOverspeeding = false
    /// Превышаем УСТОЙЧИВО (дольше overspeedSustainSeconds). Именно этот флаг
    /// решает, кричать ли о камере: иначе один шумный фикс на «превысил на 1 км»
    /// поднимал спокойный анонс до сирены.
    private(set) var isOverspeedingSustained = false

    /// Голос «Превышение скорости» — подключается в AppEnvironment.
    @ObservationIgnored var onOverspeed: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onOverspeed,
                                               "SpeedLimitService.onOverspeed") }
    }

    /// Поколение индекса: растёт при загрузке/обновлении базы лимитов. Карта
    /// по нему пересобирает слой маркеров — индекс приезжает с диска и с сервера
    /// позже первого слоя, и без сигнала мини-знаки «60» не появились бы до
    /// первого движения карты.
    private(set) var indexRevision = 0
    /// Сеть для схемы приборки: индекс лимитов под кэшем окрестности.
    /// Пересоздаётся вместе с индексом — кэш не должен пережить свои данные.
    private(set) var sketchNetwork: any RoadNetworkSource = EmptyRoadNetwork()

    private let settings: AppSettings
    @ObservationIgnored private var index: LimitIndex? {
        didSet {
            indexRevision += 1
            sketchNetwork = index.map { CachedRoadNetwork($0) } ?? EmptyRoadNetwork()
        }
    }
    @ObservationIgnored private var missCount = 0
    @ObservationIgnored private var overspeedSince: Date?
    @ObservationIgnored private var lastWarnAt: Date = .distantPast
    @ObservationIgnored private var started = false

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("speed_limits.json")
    }

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Лимит дороги у произвольной точки (карточка камеры). nil — данных нет.
    func limit(near coordinate: CLLocationCoordinate2D) -> Int? {
        index?.limit(near: coordinate)
    }

    /// То же, но с предположением по классу дороги, когда OSM молчит.
    /// Возвращает и признак «предположено» — его обязан показать вызывающий.
    func limit(for camera: Camera) -> (kmh: Int, isAssumed: Bool)? {
        if let known = index?.limit(near: camera.coordinate) { return (known, false) }
        guard let assumed = camera.roadClass.assumedLimitKmh else { return nil }
        return (assumed, true)
    }

    /// Сам индекс — для пакетных запросов вне main (слой маркеров карты
    /// спрашивает лимиты двух сотен камер разом; LimitIndex — Sendable).
    var limitIndex: LimitIndex? { index }

    /// База лимитов есть. Без неё не считаются ни превышения, ни рейтинг, ни
    /// «возможные штрафы» — то есть половина Итогов пустая, и по экрану
    /// непонятно почему. Пользователю это надо сказать, а не оставить гадать.
    var isReady: Bool { index != nil }

    /// Скачивание идёт прямо сейчас (для честной плашки, а не спиннера-загадки).
    private(set) var isDownloading = false

    // MARK: - Загрузка базы

    /// Вызывается при старте приложения: локальный файл сразу, сервер — раз в 7 дней.
    func start() {
        guard !started else { return }
        started = true
        Task {
            await loadLocal()
            await refreshFromServerIfNeeded()
        }
    }

    private func loadLocal() async {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        index = await Task.detached(priority: .utility) {
            (try? Data(contentsOf: url)).flatMap(LimitIndex.build)
        }.value
        if index == nil {
            Log.route.error("кэш лимитов есть на диске, но не прочитался")
        }
    }

    /// Повторить загрузку по кнопке из плашки: человек видит, что данных нет,
    /// и должен иметь возможность что-то с этим сделать, а не ждать неделю.
    func retryDownload() async {
        Storage.set(0, for: .speedLimitsLastCheck)
        await refreshFromServerIfNeeded()
    }

    private func refreshFromServerIfNeeded() async {
        let lastCheck = Storage.double(.speedLimitsLastCheck)
        let weekAgo = Date().timeIntervalSince1970 - 7 * 24 * 3600
        guard index == nil || lastCheck < weekAgo else { return }

        isDownloading = true
        defer { isDownloading = false }
        // Недельная фоновая проверка: сбой сети не критичен, попробуем в следующий раз.
        let api = APIClient(timeout: 30)
        guard let data = try? await api.getData("speed_limits.json",
                                                cachePolicy: .reloadIgnoringLocalCacheData) else { return }

        let url = fileURL
        let built = await Task.detached(priority: .utility) { () -> LimitIndex? in
            guard let index = LimitIndex.build(from: data) else { return nil }
            do { try data.write(to: url, options: .atomic) } catch {
                // Индекс уже в памяти — без кэша просто перекачаем через неделю.
                Log.route.error("кэш лимитов не записался: \(error.localizedDescription, privacy: .public)")
            }
            return index
        }.value
        if let built {
            index = built
            Storage.set(Date().timeIntervalSince1970, for: .speedLimitsLastCheck)
        }
    }

    // MARK: - Тик (вызывается LocationService на каждой GPS-точке)

    /// `fallbackClass` — класс дороги ближайшей камеры. Когда `maxspeed` в OSM
    /// нет, лимит предполагается по нему: см. `RoadClass.assumedLimitKmh`.
    /// Класс камеры — лучший доступный признак дороги, по которой мы едем:
    /// камера стоит НАД этой дорогой, и её `cls` проставлен снапом у 3455 из
    /// 3467 записей базы.
    func update(coordinate: CLLocationCoordinate2D, course: CLLocationDirection,
                speedKmh: Double, announce: Bool, fallbackClass: RoadClass = .unknown) {
        guard settings.speedLimitsEnabled, let index else {
            currentLimit = nil; isCurrentLimitAssumed = false; clearOverspeed()
            return
        }

        // Матчим дорогу только в движении с достоверным курсом;
        // стоя (светофор) держим последний известный лимит.
        if speedKmh >= 8, course >= 0 {
            if let limit = index.match(coordinate, courseDegrees: course) {
                if limit != currentLimit { currentLimit = limit }
                if isCurrentLimitAssumed { isCurrentLimitAssumed = false }
                missCount = 0
            } else {
                missCount += 1
                if missCount >= 4 {
                    // Данных по дороге нет — предполагаем по классу. Раньше
                    // здесь наступал nil, и вместе с ним пропадали превышение,
                    // рейтинг и голос о камере в режиме по умолчанию.
                    let assumed = fallbackClass.assumedLimitKmh
                    if assumed != currentLimit { currentLimit = assumed }
                    if isCurrentLimitAssumed != (assumed != nil) {
                        isCurrentLimitAssumed = assumed != nil
                    }
                }
            }
        }

        guard let limit = currentLimit else {
            clearOverspeed()
            return
        }
        let over = speedKmh > Double(limit) + settings.overspeedTolerance
        if over != isOverspeeding { isOverspeeding = over }
        overspeedSince = over ? (overspeedSince ?? Date()) : nil

        // Устойчивость считаем один раз и здесь: и голос, и градус алерта о камере
        // должны опираться на одно и то же «превышаем по-настоящему».
        let sustained = overspeedSince.map {
            Date().timeIntervalSince($0) >= AppConfig.overspeedSustainSeconds
        } ?? false
        if sustained != isOverspeedingSustained { isOverspeedingSustained = sustained }

        // Голос про само превышение: не чаще раза в 30 с.
        if sustained, announce, Date().timeIntervalSince(lastWarnAt) > 30 {
            lastWarnAt = Date()
            onOverspeed?()
        }
    }

    private func clearOverspeed() {
        isOverspeeding = false
        isOverspeedingSustained = false
        overspeedSince = nil
    }
}

// MARK: - Индекс сегментов

/// Иммутабельный индекс: строится в фоне, читается с главного потока без блокировок.
struct LimitIndex: Sendable, RoadNetworkSource {
    struct Segment: Sendable {
        let limit: Int
        let pts: [MKMapPoint]
        /// Рамка сегмента в единицах MKMapPoint.
        ///
        /// Ячейка грида — 1,1 км, а совпадением считается 35 м: почти всё, что
        /// попало в кольцо ячеек, до дороги под колесом не дотягивается. Без
        /// рамки `match` обходил ВСЕ пары точек ВСЕХ сегментов кольца — в
        /// плотном центре это тысячи пар на каждом GPS-тике. Рамка отсекает
        /// сегмент четырьмя сравнениями, до того как начнётся геометрия.
        let minX, minY, maxX, maxY: Double

        init(limit: Int, pts: [MKMapPoint]) {
            self.limit = limit
            self.pts = pts
            var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
            for point in pts {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            self.minX = minX; self.minY = minY
            self.maxX = maxX; self.maxY = maxY
        }

        /// Может ли эта дорога оказаться ближе `reach` (в единицах MKMapPoint).
        func mayReach(_ p: MKMapPoint, within reach: Double) -> Bool {
            p.x >= minX - reach && p.x <= maxX + reach
                && p.y >= minY - reach && p.y <= maxY + reach
        }
    }

    let segments: [Segment]
    let grid: [Int: [Int32]]   // ячейка 0.01° → индексы сегментов

    // MARK: - Дороги для схемы на приборке

    /// Индекс лимитов — по совместительству ЕДИНСТВЕННАЯ дорожная геометрия,
    /// которая уже лежит на телефоне: 21 558 сегментов, 183 483 точки, офлайн.
    /// Мы качали его ради матчинга лимита, а он несёт настоящие линии дорог —
    /// с перекрёстками и развязками. Первый источник для RoadSketch, пока не
    /// собран собственный roads.json (см. RoadNetwork.swift).
    ///
    /// Чего этот источник НЕ знает: класса дороги, моста, односторонности —
    /// в файле их нет. Поэтому все линии помечены как «без подробностей», и
    /// вью рисует их ровно, не выдавая догадку за измеренное.
    func roads(near coordinate: CLLocationCoordinate2D,
               radius: CLLocationDistance) -> [RoadLine] {
        // Ячейка грида 0.01° ≈ 1,1 км — берём кольцо ячеек по радиусу.
        let span = max(1, Int((radius / 1100).rounded(.up)))
        let centerLat = Int((coordinate.latitude + 90) * 100)
        let centerLon = Int((coordinate.longitude + 180) * 100)

        var seen = Set<Int32>()
        for latCell in (centerLat - span)...(centerLat + span) {
            for lonCell in (centerLon - span)...(centerLon + span) {
                if let found = grid[latCell * 40_000 + lonCell] { seen.formUnion(found) }
            }
        }
        guard !seen.isEmpty else { return [] }

        let origin = MKMapPoint(coordinate)
        // Радиус в единицах MKMapPoint, и сравниваем КВАДРАТЫ — в тех же
        // единицах, что и точки сегмента.
        //
        // Здесь была путаница в единицах: `MKMapPoint.distance` возвращает
        // МЕТРЫ, а сравнивали его с радиусом, уже переведённым в единицы карты.
        // На широте Ташкента это множитель ~8,8 — «дороги в радиусе 570 м»
        // отдавались в радиусе пяти километров. Схема потом всё равно обрезала
        // их своим масштабом, поэтому на экране это не проявлялось: просто
        // каждая пересборка тащила в несколько раз больше геометрии, чем
        // просила, и делала это на телефоне в держателе.
        let limitSquared = Self.points(radius, at: coordinate) * Self.points(radius, at: coordinate)
        func within(_ point: MKMapPoint) -> Bool {
            let dx = point.x - origin.x, dy = point.y - origin.y
            return dx * dx + dy * dy <= limitSquared
        }
        let reach = Self.points(radius, at: coordinate)
        return seen.compactMap { index -> RoadLine? in
            let segment = segments[Int(index)]
            guard segment.mayReach(origin, within: reach) else { return nil }
            // Точки за радиусом отбрасываем, но линию не рвём: берём кусок от
            // первой до последней попавшей — иначе дорога рассыпалась бы на
            // обрывки там, где она просто длинная.
            guard let first = segment.pts.firstIndex(where: within),
                  let last = segment.pts.lastIndex(where: within),
                  last > first else { return nil }
            return RoadLine(points: segment.pts[first...last].map(\.coordinate))
        }
    }

    nonisolated private static func cellKey(lat: Double, lon: Double) -> Int {
        let latCell = Int((lat + 90) * 100)
        let lonCell = Int((lon + 180) * 100)
        return latCell * 40_000 + lonCell
    }

    nonisolated static func build(from data: Data) -> LimitIndex? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["segments"] as? [[Any]] else {
            Log.route.error("speed_limits.json: неожиданный формат")
            return nil
        }

        var segments: [Segment] = []
        segments.reserveCapacity(raw.count)
        var grid: [Int: [Int32]] = [:]

        for entry in raw {
            guard entry.count == 2,
                  let limit = (entry[0] as? NSNumber)?.intValue,
                  let flat = entry[1] as? [NSNumber], flat.count >= 4 else { continue }

            var pts: [MKMapPoint] = []
            pts.reserveCapacity(flat.count / 2)
            let segmentIndex = Int32(segments.count)
            var cells = Set<Int>()

            var previous: (lat: Double, lon: Double)?
            for i in stride(from: 0, to: flat.count - 1, by: 2) {
                let lat = flat[i].doubleValue, lon = flat[i + 1].doubleValue
                pts.append(MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: lon)))
                cells.insert(cellKey(lat: lat, lon: lon))
                // Длинные прямые перегоны: отмечаем и промежуточные ячейки (шаг ~0.005°).
                if let p = previous {
                    let steps = Int(max(abs(lat - p.lat), abs(lon - p.lon)) / 0.005)
                    if steps > 1 {
                        for s in 1..<steps {
                            let f = Double(s) / Double(steps)
                            cells.insert(cellKey(lat: p.lat + (lat - p.lat) * f,
                                                 lon: p.lon + (lon - p.lon) * f))
                        }
                    }
                }
                previous = (lat, lon)
            }
            segments.append(Segment(limit: limit, pts: pts))
            for cell in cells { grid[cell, default: []].append(segmentIndex) }
        }
        return segments.isEmpty ? nil : LimitIndex(segments: segments, grid: grid)
    }

    /// Кандидаты кольца 3×3 ячеек вокруг точки. Один сегмент лежит в нескольких
    /// ячейках, поэтому Set: без него длинный проспект перебирался бы девять раз.
    nonisolated private func candidates(around coordinate: CLLocationCoordinate2D) -> Set<Int32> {
        var found = Set<Int32>()
        for dLat in -1...1 {
            for dLon in -1...1 {
                let key = Self.cellKey(lat: coordinate.latitude + Double(dLat) * 0.01,
                                       lon: coordinate.longitude + Double(dLon) * 0.01)
                if let list = grid[key] { found.formUnion(list) }
            }
        }
        return found
    }

    /// Ближайшая дорога кольца: лимит и квадрат расстояния в единицах MKMapPoint.
    ///
    /// Общее тело для `match` и `limit(near:)` — они обязаны сходиться в том,
    /// какую дорогу считают ближайшей, а раньше это были две копии одного
    /// цикла, расходившиеся при каждой правке.
    ///
    /// Считаем в КВАДРАТАХ единиц карты, а не в метрах: `MKMapPoint.distance`
    /// на каждую пару точек — это корень и пересчёт масштаба по широте, а нам
    /// нужно только сравнить, что ближе. Порядок сравнений от этого не меняется
    /// (масштаб внутри кольца постоянен), а метры остаются только на границе.
    nonisolated private func nearestRoad(
        to p: MKMapPoint, within reach: Double, candidates: Set<Int32>,
        accepts: (_ dx: Double, _ dy: Double) -> Bool
    ) -> Int? {
        var bestSquared = reach * reach
        var bestLimit: Int?
        for candidate in candidates {
            let segment = segments[Int(candidate)]
            // Рамка: четыре сравнения вместо обхода всех точек сегмента.
            guard segment.mayReach(p, within: reach) else { continue }
            let pts = segment.pts
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                // Ближайшая точка на отрезке AB.
                let dx = b.x - a.x, dy = b.y - a.y
                let len2 = dx * dx + dy * dy
                guard len2 > 0 else { continue }
                let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
                let ox = a.x + t * dx - p.x, oy = a.y + t * dy - p.y
                let squared = ox * ox + oy * oy
                guard squared < bestSquared else { continue }
                guard accepts(dx, dy) else { continue }
                bestSquared = squared
                bestLimit = segment.limit
            }
        }
        return bestLimit
    }

    /// Метры в единицы MKMapPoint на этой широте.
    nonisolated private static func points(_ meters: Double,
                                           at coordinate: CLLocationCoordinate2D) -> Double {
        meters / MKMetersPerMapPointAtLatitude(coordinate.latitude)
    }

    /// Лимит дороги в точке: ближе 35 м к линии и направление совпадает с курсом (±40°, обе стороны).
    nonisolated func match(_ coordinate: CLLocationCoordinate2D, courseDegrees: Double) -> Int? {
        nearestRoad(to: MKMapPoint(coordinate),
                    within: Self.points(35, at: coordinate),
                    candidates: candidates(around: coordinate)) { dx, dy in
            // Совпадение направления (дорогу считаем двусторонней).
            // Меркатор конформен: азимут корректно берётся прямо из map-точек (y растёт на юг).
            let segmentBearing = (atan2(dx, -dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            var diff = abs(segmentBearing - courseDegrees).truncatingRemainder(dividingBy: 360)
            if diff > 180 { diff = 360 - diff }
            return min(diff, 180 - diff) <= 40
        }
    }

    /// Лимит ближайшей дороги без учёта курса — для карточки камеры
    /// (камера стоит, курса нет; берём просто ближайшую дорогу до 45 м).
    nonisolated func limit(near coordinate: CLLocationCoordinate2D) -> Int? {
        nearestRoad(to: MKMapPoint(coordinate),
                    within: Self.points(45, at: coordinate),
                    candidates: candidates(around: coordinate)) { _, _ in true }
    }
}
