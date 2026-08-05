//
//  TripStats.swift
//  RadarMap
//
//  Статистика поездки: живые метрики + лог пройденных камер со скоростью,
//  трек поездки (упрощённый Дугласом-Пекером) и история.
//

import Foundation
import Observation
import CoreLocation
import os

@MainActor
@Observable
final class TripStats {
    private(set) var maxSpeedKmh: Double = 0
    private(set) var distanceMeters: CLLocationDistance = 0
    private(set) var startedAt: Date?
    private(set) var lastPointAt: Date?
    /// Пройденные камеры текущей/последней поездки (со скоростью прохождения).
    private(set) var passed: [PassedCamera] = []
    /// Заезды по пути, склеенные в эту поездку (см. resume и TripMerge).
    private(set) var stops: [TripStop] = []

    private(set) var history: [TripRecord] = []
    /// Пожизненные счётчики — живут отдельно от истории (она обрезается до 50 поездок).
    private(set) var lifetime = LifetimeStats()
    /// Вызывается после сохранения поездки (AppEnvironment вешает сюда недельный дайджест).
    @ObservationIgnored var onTripFinished: (() -> Void)?

    @ObservationIgnored private var lastCoordinate: CLLocationCoordinate2D?
    /// Сырой трек текущей поездки: точка каждые ≥30 м, упрощается при финише.
    @ObservationIgnored private var trackBuffer: [TrackPoint] = []
    private static let trackStepMeters = 30.0
    private static let trackTolerance = 0.00022   // ~22 м — упрощение Дугласа-Пекера
    private static let trackMaxPoints = 400

    init() { loadHistory() }

    var camerasPassed: Int { passed.count }

    /// finish() обнуляет startedAt — длительность последней поездки храним отдельно,
    /// иначе «средняя км/ч» и «в пути» на экране Итогов превращаются в нули.
    private var finishedDuration: TimeInterval = 0

    /// Полное время поездки — со стоянками: столько она заняла по часам.
    var durationSeconds: TimeInterval {
        guard let startedAt, let lastPointAt else { return finishedDuration }
        return max(0, lastPointAt.timeIntervalSince(startedAt))
    }
    /// Время в движении: стоянки склеенной поездки не должны топить среднюю скорость.
    var movingSeconds: TimeInterval {
        max(0, durationSeconds - stops.reduce(0) { $0 + $1.duration })
    }
    var averageSpeedKmh: Double {
        movingSeconds > 0 ? distanceMeters / movingSeconds * 3.6 : 0
    }

    func begin() {
        maxSpeedKmh = 0
        distanceMeters = 0
        lastCoordinate = nil
        passed = []
        stops = []
        trackBuffer = []
        finishedDuration = 0
        startedAt = Date()
        lastPointAt = startedAt
    }

    /// Продолжить прошлую поездку вместо новой: запись вынимается из истории
    /// обратно в живую сессию, а пауза между ними становится остановкой.
    /// Так заезд в магазин остаётся одной поездкой (решает TripMerge).
    /// Трек поднимаем уже упрощённым — сырых точек прошлой ноги нет, и это
    /// нормально: следующее упрощение при финише всё равно прошло бы по ним.
    func resume(_ record: TripRecord, stoppedUntil resumedAt: Date = Date()) {
        history.removeAll { $0.id == record.id }
        startedAt = record.startedAt
        lastPointAt = resumedAt
        finishedDuration = 0
        distanceMeters = record.distanceMeters
        maxSpeedKmh = record.maxSpeedKmh
        passed = record.passed
        trackBuffer = record.trackPoints
        lastCoordinate = record.endCoordinate
        stops = (record.stops ?? []) + [
            TripStop(id: UUID(),
                     lat: record.endLat ?? record.trackPoints.last?.lat ?? 0,
                     lon: record.endLon ?? record.trackPoints.last?.lon ?? 0,
                     from: record.endedAt, to: resumedAt)
        ]
        persist()   // история уже без этой записи — не потерять её при вылете
        let stopSeconds = Int(self.stops.last?.duration ?? 0)
        Log.trips.info("поездка продолжена: остановка \(stopSeconds, privacy: .public) с")
    }

    func update(coordinate: CLLocationCoordinate2D, speedKmh: Double) {
        if let last = lastCoordinate {
            let step = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            if step < 500 { distanceMeters += step }
        }
        lastCoordinate = coordinate
        maxSpeedKmh = max(maxSpeedKmh, speedKmh)
        lastPointAt = Date()

        // Трек: точка каждые ≥30 м (память копеечная, финальное сжатие при финише).
        if let last = trackBuffer.last {
            if GeoMath.fastDistance(last.lat, last.lon,
                                    coordinate.latitude, coordinate.longitude) >= Self.trackStepMeters {
                trackBuffer.append(TrackPoint(lat: coordinate.latitude,
                                              lon: coordinate.longitude, speedKmh: speedKmh))
            }
        } else {
            trackBuffer.append(TrackPoint(lat: coordinate.latitude,
                                          lon: coordinate.longitude, speedKmh: speedKmh))
        }
    }

    /// Зафиксировать прохождение камеры (скорость — в точке максимального сближения).
    func registerPass(camera: Camera, speedKmh: Double, limitKmh: Int?) {
        passed.append(PassedCamera(
            id: UUID(), cameraID: camera.id, typeRaw: camera.type,
            location: camera.displayTitle, speedKmh: speedKmh, date: Date(),
            lat: camera.lat, lon: camera.lon, limitKmh: limitKmh
        ))
    }

    /// Сбросить поездку без записи в историю: пассажирский старт («я в такси»)
    /// не должен портить статистику и рейтинг.
    func cancel() {
        startedAt = nil
        finishedDuration = 0
        distanceMeters = 0
        maxSpeedKmh = 0
        passed = []
        stops = []
        trackBuffer = []
    }

    /// `endedManually` — нажали «Завершить» (а не автостоп по CoreMotion).
    /// Флаг едет в запись: он запрещает склейку следующей поездки (см. TripMerge).
    func finish(endedManually: Bool = true) {
        finishedDuration = durationSeconds
        defer { startedAt = nil }
        guard let startedAt, distanceMeters >= 100 else { return }
        // Рейтинг считаем по сырому треку (упрощённый теряет пики скорости).
        let scorePasses = passed.map { DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh) }
        let score = DrivingScore.tripScore(passes: scorePasses,
                                           trackSpeeds: trackBuffer.map(\.speedKmh))
        let record = TripRecord(
            id: startedAt.timeIntervalSince1970,
            startedAt: startedAt,
            endedAt: lastPointAt ?? Date(),
            distanceMeters: distanceMeters,
            maxSpeedKmh: maxSpeedKmh,
            passed: passed,
            endLat: lastCoordinate?.latitude,
            endLon: lastCoordinate?.longitude,
            track: Self.packTrack(Self.simplify(trackBuffer,
                                                tolerance: Self.trackTolerance,
                                                maxPoints: Self.trackMaxPoints)),
            score: score,
            stops: stops.isEmpty ? nil : stops,
            endedManually: endedManually
        )
        history.insert(record, at: 0)
        history = TripHistory.pruned(history)
        lifetime = LifetimeStats.updated(lifetime, passes: scorePasses, distanceMeters: distanceMeters)
        persist()
        persistLifetime()
        onTripFinished?()
    }

    /// Разделить склеенную поездку по остановке («Разделить здесь» в деталке) —
    /// страховка, если автоматика склеила лишнее.
    func splitRecord(id: Double, at stop: TripStop) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        let legs = TripHistory.split(history[index], at: stop)
        guard legs.count == 2 else { return }
        history.replaceSubrange(index...index, with: legs)
        history = TripHistory.pruned(history)
        persist()
    }

    /// Одноразовая чистка «мостовых» проездов: направление трека у камеры против
    /// оси её дороги (появилась в базе v8). Вызывает AppEnvironment после сборки
    /// сервисов — оси знает CameraRepository.
    func axisCleanupIfNeeded(axisByID: [Int: Int]) {
        guard !Storage.bool(.passAxisCleanup1), !axisByID.isEmpty else { return }
        let (cleaned, changed) = TripHistory.axisSanitized(history, axisByID: axisByID)
        if changed {
            history = cleaned
            lifetime = LifetimeStats.rebuilt(from: history)
            persist()
            persistLifetime()
            Log.trips.info("чистка мостовых проездов: история пересчитана")
        }
        Storage.set(true, for: .passAxisCleanup1)
    }

    func deleteRecord(id: Double) {
        history.removeAll { $0.id == id }
        persist()
    }

    func clearHistory() {
        history = []
        persist()
    }

    // MARK: - Рейтинг и экономия

    /// Текущий рейтинг: средний балл поездок за 30 дней, взвешенный по дистанции.
    var rating: Int? {
        TripHistory.weightedRating(history, within: 30 * 86400, now: Date())
    }

    /// Тренд к прошлой неделе — для стрелки у кольца рейтинга.
    var ratingTrend: Int? {
        let now = Date()
        guard let current = TripHistory.weightedRating(history, within: 7 * 86400, now: now),
              let previous = TripHistory.weightedRating(history, within: 7 * 86400,
                                                        now: now.addingTimeInterval(-7 * 86400))
        else { return nil }
        return current - previous
    }

    /// Сводка за последние 7 дней — заголовок истории.
    var weekSummary: (trips: Int, distance: CLLocationDistance, cameras: Int)? {
        TripHistory.weekSummary(history)
    }

    /// Что показывать в шапке Итогов: живую сессию (nil) или последнюю поездку.
    func fallbackRecord(isTripActive: Bool) -> TripRecord? {
        TripHistory.fallbackRecord(history: history, isTripActive: isTripActive,
                                   liveDistance: distanceMeters)
    }

    /// «Сэкономлено на штрафах» за последние 30 дней (по истории; пожизненное — в lifetime).
    var month30: (clean: Int, over: Int, risk: Double, topOverLocation: String?) {
        TripHistory.month30(history)
    }

    #if DEBUG
    /// Демо-история для скриншотов и визуальной проверки отчёта на симуляторе:
    /// `simctl launch <app> -demoHistory -showStats -showReport`.
    /// ЗАМЕЩАЕТ историю — только под DEBUG и только по явному флагу запуска,
    /// в релизную сборку не попадает.
    /// `shiftDays` сдвигает всю демо-историю в прошлое — так проверяется состояние
    /// «поездки есть, но не в этом периоде» (открыл Итоги после недели без езды).
    func seedDemoHistory(shiftDays: Double = 0) {
        let base = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
        let now = Date().addingTimeInterval(-shiftDays * 86400)

        /// Одна демо-поездка. `hour` задаёт время суток проезда камеры — от него
        /// зависит полоса «когда рискуете».
        func makeRecord(index: Int, daysAgo: Double, km: Double, seed: Int,
                        over: Bool, hour: Int, withStop: Bool = false) -> TripRecord {
            let day = Calendar.current.startOfDay(for: now.addingTimeInterval(-daysAgo * 86400))
            var start = day.addingTimeInterval(Double(hour) * 3600)
            // Заданный час мог оказаться позже «сейчас» (вечер ещё не наступил):
            // такая запись уезжает в будущее и в период не попадает — сдвигаем её
            // на сутки назад.
            if start > now { start.addTimeInterval(-86400) }
            let track = Self.demoTrack(from: base, seed: seed, km: km)
            // Камера стоит НА треке (примерно на 40% пути), а не в стороне от него.
            let camIndex = max(0, (track.count / 3) / 3 * 3)
            let cam = CLLocationCoordinate2D(latitude: track[camIndex],
                                             longitude: track[camIndex + 1])
            let pass = PassedCamera(id: UUID(), cameraID: 1000 + index,
                                    typeRaw: "Стационар радар",
                                    location: ["Юнусабад", "Чиланзар", "Мирзо-Улугбек"][index % 3],
                                    speedKmh: over ? 88 : 56,
                                    date: start.addingTimeInterval(400),
                                    lat: cam.latitude, lon: cam.longitude, limitKmh: 60)
            // Одна поездка с заездом по пути — проверить блок остановок.
            let stops: [TripStop]? = withStop ? [TripStop(
                id: UUID(), lat: base.latitude, lon: base.longitude,
                from: start.addingTimeInterval(900),
                to: start.addingTimeInterval(900 + 1500))] : nil
            return TripRecord(
                id: start.timeIntervalSince1970, startedAt: start,
                endedAt: start.addingTimeInterval(km * 90 + (stops?.first?.duration ?? 0)),
                distanceMeters: km * 1000, maxSpeedKmh: over ? 104 : 82,
                passed: [pass], endLat: track[track.count - 3], endLon: track[track.count - 2],
                track: track, score: over ? 68 : 94, stops: stops, endedManually: true)
        }

        var seeded: [TripRecord] = []
        // Эта неделя: три поездки идут по одному «рабочему» коридору (общий seed) —
        // на карте видно градусы частоты, а не шесть равнозначных линий. Три
        // проезда с превышением дают зону риска и полосу часов.
        let week: [(daysAgo: Double, km: Double, seed: Int, over: Bool, hour: Int)] = [
            (0.2, 12.4, 1, true,  19), (1.1, 8.1,  1, false, 9),
            (2.3, 23.7, 2, false, 14), (3.0, 5.2,  3, true,  20),
            (4.5, 31.0, 1, false, 8),  (5.4, 14.8, 4, true,  18),
        ]
        for (index, item) in week.enumerated() {
            seeded.append(makeRecord(index: index, daysAgo: item.daysAgo, km: item.km,
                                     seed: item.seed, over: item.over, hour: item.hour,
                                     withStop: index == 2))
        }
        // Прошлая неделя — база сравнения. Без неё «стало лучше/хуже», дельта
        // километров и движение рейтинга сравнивать не с чем, и половина разбора
        // периода на экране просто не появляется.
        let previous: [(daysAgo: Double, km: Double, seed: Int, over: Bool, hour: Int)] = [
            (8.3, 9.6, 1, true, 19), (9.6, 11.2, 1, true, 20),
            (11.2, 7.4, 2, true, 18), (12.7, 6.1, 3, false, 10),
        ]
        for (index, item) in previous.enumerated() {
            seeded.append(makeRecord(index: 6 + index, daysAgo: item.daysAgo, km: item.km,
                                     seed: item.seed, over: item.over, hour: item.hour))
        }
        history = seeded
        lifetime = LifetimeStats.rebuilt(from: history)
        persist()
        persistLifetime()
    }

    /// Демо-трек: ломаная «по улицам» — мелкое петляние плюс поворот на каждом
    /// шестом шаге. Прямой луч из одной точки (как было раньше) на карте
    /// превращался в звезду, которой у живого пользователя не бывает.
    /// Одинаковый `seed` даёт одинаковую геометрию, поэтому короткая поездка —
    /// начало длинной: ровно так выглядит повторяющаяся дорога на работу.
    private static func demoTrack(from base: CLLocationCoordinate2D,
                                  seed: Int, km: Double) -> [Double] {
        let stepMeters = 500.0
        let steps = max(6, Int((km * 1000 / stepMeters).rounded()))
        var heading = Double(30 + seed * 47 % 300)
        var point = base
        var track: [Double] = [base.latitude, base.longitude, 30]
        for step in 1...steps {
            if step % 8 == 0 {
                heading += (step / 8) % 2 == 0 ? 70 : -76   // перекрёсток
            } else {
                heading += Double((step * 37 + seed * 13) % 7) - 3   // петляние
            }
            // Дальше 5 км от центра поездка разворачивается: 31 км по городу —
            // это много поворотов, а не прямая в область.
            if GeoMath.fastDistance(point.latitude, point.longitude,
                                    base.latitude, base.longitude) > 5000 {
                heading = GeoMath.bearing(from: point, to: base)
                    + Double((step * 17 + seed) % 40) - 20
            }
            point = GeoMath.destination(from: point, bearing: heading,
                                        distanceMeters: stepMeters)
            track += [point.latitude, point.longitude, 38 + Double(step % 7) * 9]
        }
        return track
    }
    #endif

    // MARK: - Трек: упаковка и упрощение (Дуглас-Пекер)

    nonisolated private static func packTrack(_ points: [TrackPoint]) -> [Double]? {
        guard points.count >= 2 else { return nil }
        var flat: [Double] = []
        flat.reserveCapacity(points.count * 3)
        for p in points {
            flat.append((p.lat * 1e5).rounded() / 1e5)
            flat.append((p.lon * 1e5).rounded() / 1e5)
            flat.append((p.speedKmh * 10).rounded() / 10)
        }
        return flat
    }

    /// Классический Дуглас-Пекер по (lat, lon); скорость сохраняется у оставленных точек.
    nonisolated static func simplify(_ points: [TrackPoint], tolerance: Double,
                                     maxPoints: Int) -> [TrackPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (lo, hi) = stack.popLast() {
            guard hi > lo + 1 else { continue }
            var worst = 0.0
            var worstIndex = lo
            for i in (lo + 1)..<hi {
                let d = perpendicular(points[i], points[lo], points[hi])
                if d > worst { worst = d; worstIndex = i }
            }
            if worst > tolerance {
                keep[worstIndex] = true
                stack.append((lo, worstIndex))
                stack.append((worstIndex, hi))
            }
        }
        var result = points.indices.filter { keep[$0] }.map { points[$0] }
        // Страховка от гигантских треков: равномерное прореживание до лимита.
        if result.count > maxPoints {
            let step = Double(result.count - 1) / Double(maxPoints - 1)
            result = (0..<maxPoints).map { result[Int((Double($0) * step).rounded())] }
        }
        return result
    }

    nonisolated private static func perpendicular(_ p: TrackPoint, _ a: TrackPoint, _ b: TrackPoint) -> Double {
        let dx = b.lon - a.lon, dy = b.lat - a.lat
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.lon - a.lon, p.lat - a.lat) }
        let t = max(0, min(1, ((p.lon - a.lon) * dx + (p.lat - a.lat) * dy) / len2))
        return hypot(p.lon - (a.lon + t * dx), p.lat - (a.lat + t * dy))
    }

    // MARK: - Хранение

    private var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("trips.json")
    }
    private func loadHistory() {
        if let decoded = JSONFile.load([TripRecord].self, from: storeURL, log: Log.trips) {
            history = decoded
        }
        if let data = Storage.data(.lifetimeStats) {
            do {
                lifetime = try JSONDecoder().decode(LifetimeStats.self, from: data)
            } catch {
                // Не читается — ниже восстановим из истории (backfill).
                Log.trips.error("lifetimeStats не декодировались: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Одноразовая гео-чистка: старые версии засчитывали камеры с параллельных
        // улиц — выкидываем их из истории и пересчитываем баллы и счётчики.
        if !Storage.bool(.passGeoCleanup1) {
            let (cleaned, changed) = TripHistory.sanitized(history)
            if changed {
                history = cleaned
                lifetime = LifetimeStats.rebuilt(from: history)
                persist()
                persistLifetime()
            }
            Storage.set(true, for: .passGeoCleanup1)
        }
        // Обновились с версии без счётчиков, а поездки уже есть — восстанавливаем
        // из истории, чтобы экономия и достижения не начинались с нуля.
        if lifetime.trips == 0 && !history.isEmpty {
            lifetime = LifetimeStats.rebuilt(from: history)
            persistLifetime()
        }
    }

    private func persistLifetime() {
        do {
            Storage.set(try JSONEncoder().encode(lifetime), for: .lifetimeStats)
        } catch {
            Log.trips.error("lifetimeStats не сохранились: \(error.localizedDescription, privacy: .public)")
        }
    }
    private func persist() {
        JSONFile.save(history, to: storeURL, log: Log.trips)
    }
}
