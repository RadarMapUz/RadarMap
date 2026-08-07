//
//  SpeedLimitService.swift
//  RadarMap
//
//  Лимиты скорости дорог (maxspeed из OpenStreetMap, готовит наш сервер).
//  Определяет лимит дороги, по которой едем (позиция + курс), и следит за превышением.
//  База ~3 МБ обновляется раз в неделю; индекс и матчинг устроены так, чтобы
//  на каждом GPS-тике работать за микросекунды и не трогать главный поток при загрузке.
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
    @ObservationIgnored var onOverspeed: (() -> Void)?

    /// Поколение индекса: растёт при загрузке/обновлении базы лимитов. Карта
    /// по нему пересобирает слой маркеров — индекс приезжает с диска и с сервера
    /// позже первого слоя, и без сигнала мини-знаки «60» не появились бы до
    /// первого движения карты.
    private(set) var indexRevision = 0
    private let settings: AppSettings
    @ObservationIgnored private var index: LimitIndex? { didSet { indexRevision += 1 } }
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
struct LimitIndex: Sendable {
    struct Segment: Sendable {
        let limit: Int
        let pts: [MKMapPoint]
    }

    let segments: [Segment]
    let grid: [Int: [Int32]]   // ячейка 0.01° → индексы сегментов

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

    /// Лимит дороги в точке: ближе 35 м к линии и направление совпадает с курсом (±40°, обе стороны).
    nonisolated func match(_ coordinate: CLLocationCoordinate2D, courseDegrees: Double) -> Int? {
        let p = MKMapPoint(coordinate)
        var bestDistance = 35.0
        var bestLimit: Int?

        var candidates = Set<Int32>()
        for dLat in -1...1 {
            for dLon in -1...1 {
                let key = Self.cellKey(lat: coordinate.latitude + Double(dLat) * 0.01,
                                       lon: coordinate.longitude + Double(dLon) * 0.01)
                if let list = grid[key] { candidates.formUnion(list) }
            }
        }

        for candidate in candidates {
            let segment = segments[Int(candidate)]
            let pts = segment.pts
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                // Ближайшая точка на отрезке AB.
                let dx = b.x - a.x, dy = b.y - a.y
                let len2 = dx * dx + dy * dy
                guard len2 > 0 else { continue }
                let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
                let closest = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
                let d = p.distance(to: closest)
                guard d < bestDistance else { continue }
                // Совпадение направления (дорогу считаем двусторонней).
                // Меркатор конформен: азимут корректно берётся прямо из map-точек (y растёт на юг).
                let segmentBearing = (atan2(dx, -dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
                var diff = abs(segmentBearing - courseDegrees).truncatingRemainder(dividingBy: 360)
                if diff > 180 { diff = 360 - diff }
                guard min(diff, 180 - diff) <= 40 else { continue }
                bestDistance = d
                bestLimit = segment.limit
            }
        }
        return bestLimit
    }

    /// Лимит ближайшей дороги без учёта курса — для карточки камеры
    /// (камера стоит, курса нет; берём просто ближайшую дорогу до 45 м).
    nonisolated func limit(near coordinate: CLLocationCoordinate2D) -> Int? {
        let p = MKMapPoint(coordinate)
        var bestDistance = 45.0
        var bestLimit: Int?
        var candidates = Set<Int32>()
        for dLat in -1...1 {
            for dLon in -1...1 {
                let key = Self.cellKey(lat: coordinate.latitude + Double(dLat) * 0.01,
                                       lon: coordinate.longitude + Double(dLon) * 0.01)
                if let list = grid[key] { candidates.formUnion(list) }
            }
        }
        for candidate in candidates {
            let pts = segments[Int(candidate)].pts
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                let dx = b.x - a.x, dy = b.y - a.y
                let len2 = dx * dx + dy * dy
                guard len2 > 0 else { continue }
                let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
                let d = p.distance(to: MKMapPoint(x: a.x + t * dx, y: a.y + t * dy))
                if d < bestDistance {
                    bestDistance = d
                    bestLimit = segments[Int(candidate)].limit
                }
            }
        }
        return bestLimit
    }
}
