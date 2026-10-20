//
//  Commute.swift
//  RadarMap
//
//  Дорога на работу и домой — понятными словами, а не средними.
//
//  «Вышел в 8:22, доехал за 55 минут, на 12 минут дольше обычного; кто
//  выезжает в 7:45 — доезжает за 36». Это то, что человек хочет знать о своей
//  дороге, и всё это уже лежит в истории поездок: старт, финиш, время. Дом и
//  работа — выученные (FrequentPlaces) или заданные вручную.
//
//  Считается на телефоне и только здесь. Время выезда из дома и приезда на
//  работу — самые личные данные приложения: по ним восстанавливается, где
//  человек живёт и работает. Сервер видит только обезличенные скорости на
//  дорогах (пробки), а к своей дороге телефон прикладывает их сам.
//
//  Время в пути — без стоянок склейки (заезд в магазин по дороге домой —
//  не пробка): `movingDuration`. Остановки на светофорах и в заторе в него
//  входят — они и есть дорога.
//
//  Чистая логика, время — параметром; покрыто CommuteTests.
//

import CoreLocation
import Foundation

nonisolated enum Commute {

    enum Direction: String, CaseIterable, Equatable, Sendable {
        case toWork, toHome

        var title: String {
            switch self {
            case .toWork: return String(localized: "Дорога на работу")
            case .toHome: return String(localized: "Дорога домой")
            }
        }

        var symbol: String {
            switch self {
            case .toWork: return "briefcase.fill"
            case .toHome: return "house.fill"
            }
        }
    }

    /// Одна поездка по направлению.
    struct Trip: Equatable, Identifiable, Sendable {
        let id: Double
        let direction: Direction
        let departure: Date
        let arrival: Date
        /// В пути, без стоянок склейки.
        let duration: TimeInterval
        let distanceMeters: Double
    }

    /// Окно выезда, в котором доезжают быстрее всего.
    struct BestWindow: Equatable, Sendable {
        /// Начало окна, минуты от полуночи.
        let startMinute: Int
        let medianDuration: TimeInterval
        /// Сколько экономит против «обычно».
        let saving: TimeInterval
        let trips: Int
    }

    /// Всё про одно направление за окно истории.
    struct Summary: Equatable, Identifiable, Sendable {
        let direction: Direction
        var id: String { direction.rawValue }
        /// Последняя поездка (новые первыми).
        let last: Trip
        /// Медиана времени в пути; nil — поездок меньше `commuteMinTrips`.
        let usual: TimeInterval?
        /// Обычное время выезда (медиана, минуты от полуночи); nil — мало поездок.
        let usualDepartureMinute: Int?
        /// Последняя минус обычная; nil — «обычно» ещё нет.
        let lastDelay: TimeInterval?
        let best: BestWindow?
        /// Поездки окна, новые первыми.
        let trips: [Trip]
        /// Неделя дороги (8.8.15): средняя за 7 дней против «обычно»; nil —
        /// за неделю меньше двух поездок или «обычно» ещё нет.
        var week: Week? = nil

        /// Последняя поездка заметно дольше/короче обычного.
        var lastIsSlower: Bool { (lastDelay ?? 0) >= AppConfig.commuteNoticeableDelaySeconds }
        var lastIsFaster: Bool { (lastDelay ?? 0) <= -AppConfig.commuteNoticeableDelaySeconds }
    }

    // MARK: - Поездки

    /// Поездки дом↔работа из истории (любой порядок на входе, новые первыми на
    /// выходе). Старт старой записи без точки и трека берётся из конца
    /// предыдущей поездки, если между ними — обычная стоянка, а не неделя.
    static func trips<Source: CommuteTripSource>(history: [Source],
                      home: CLLocationCoordinate2D,
                      work: CLLocationCoordinate2D,
                      radius: CLLocationDistance = AppConfig.commutePlaceRadiusMeters) -> [Trip] {
        // Слишком близкие дом и работа (соседние дома) — направления не
        // различить: любая поездка по кварталу стала бы «дорогой на работу».
        guard distance(home, work) > radius * 2 else { return [] }
        // Одна запись — одна поездка, даже если история пришла с повтором
        // (склейка при загрузке с диска): иначе медиана считала бы её дважды.
        var seen = Set<Double>()
        let ordered = history.filter { seen.insert($0.id).inserted }
            .sorted { $0.startedAt < $1.startedAt }
        var result: [Trip] = []
        // Старт — шире конца: автостарт CoreMotion ловит поездку уже на ходу,
        // в 400–1000 м от дома, и такие поездки в кармане «дорогой на работу»
        // не становились никогда (сценарий S20, 20.10). Не шире трети пути
        // дом–работа: иначе направления не различить.
        let startRadius = max(radius, min(AppConfig.commuteGhostStartRadiusMeters, distance(home, work) / 3))
        for (index, record) in ordered.enumerated() {
            guard let end = record.endCoordinate,
                  let start = record.startCoordinate
                    ?? chainedStart(of: record, previous: index > 0 ? ordered[index - 1] : nil)
            else { continue }
            let direction: Direction
            if distance(start, home) <= startRadius, distance(end, work) <= radius {
                direction = .toWork
            } else if distance(start, work) <= startRadius, distance(end, home) <= radius {
                direction = .toHome
            } else {
                continue
            }
            result.append(Trip(id: record.id, direction: direction,
                               departure: record.startedAt, arrival: record.endedAt,
                               duration: record.movingDuration,
                               distanceMeters: record.distanceMeters))
        }
        return result.reversed()
    }

    private static func chainedStart<Source: CommuteTripSource>(of record: Source,
                                                                previous: Source?) -> CLLocationCoordinate2D? {
        guard let previous, let end = previous.endCoordinate else { return nil }
        let gap = record.startedAt.timeIntervalSince(previous.endedAt)
        guard gap >= 0, gap <= AppConfig.commuteChainMaxGapSeconds else { return nil }
        return end
    }

    // MARK: - Сводка

    /// Неделя дороги: «за неделю в среднем 41 мин — на 3 мин дольше обычного».
    struct Week: Equatable, Sendable {
        /// Средняя за 7 дней, с.
        let average: TimeInterval
        let trips: Int
        /// Средняя минус «обычно» (медиана 30 дней), с.
        let delta: TimeInterval

        /// Отклонение заметно — иначе строка «как обычно» ничего не добавляет.
        var isNoticeable: Bool { abs(delta) >= AppConfig.commuteWeekNoticeableSeconds }
    }

    /// Неделя по поездкам окна: последние 7 суток до `now`, не меньше двух
    /// поездок, и «обычно» уже есть. Средняя, а не медиана: неделю делает
    /// каждый день, и один тяжёлый вторник — часть её правды.
    static func week(_ window: [Trip], usual: TimeInterval?, now: Date) -> Week? {
        guard let usual else { return nil }
        let since = now.addingTimeInterval(-7 * 86_400)
        let recent = window.filter { $0.departure >= since && $0.departure <= now }
        guard recent.count >= AppConfig.commuteWeekMinTrips else { return nil }
        let average = recent.reduce(0) { $0 + $1.duration } / Double(recent.count)
        return Week(average: average, trips: recent.count, delta: average - usual)
    }

    /// Сводка по направлению за окно. nil — поездок этого направления нет.
    static func summary(_ direction: Direction, trips: [Trip], now: Date,
                        calendar: Calendar = .current,
                        windowDays: Int = AppConfig.commuteWindowDays) -> Summary? {
        let since = now.addingTimeInterval(-Double(windowDays) * 86400)
        let window = trips
            .filter { $0.direction == direction && $0.departure >= since && $0.departure <= now }
            .sorted { $0.departure > $1.departure }
        guard let last = window.first else { return nil }

        let enough = window.count >= AppConfig.commuteMinTrips
        let usual = enough ? median(window.map(\.duration)) : nil
        let usualDeparture = enough
            ? Int(median(window.map { Double(minuteOfDay($0.departure, calendar: calendar)) }).rounded())
            : nil
        let best = (usual != nil && usualDeparture != nil)
            ? bestWindow(window, usual: usual!, usualDeparture: usualDeparture!, calendar: calendar)
            : nil
        return Summary(direction: direction, last: last, usual: usual,
                       usualDepartureMinute: usualDeparture,
                       lastDelay: usual.map { last.duration - $0 },
                       best: best, trips: window,
                       week: week(window, usual: usual, now: now))
    }

    /// Обе сводки, по которым есть поездки. Порядок — по времени суток:
    /// утром первой «на работу», вечером — «домой».
    static func summaries(trips: [Trip], now: Date, calendar: Calendar = .current) -> [Summary] {
        let all = Direction.allCases.compactMap { summary($0, trips: trips, now: now, calendar: calendar) }
        let hour = calendar.component(.hour, from: now)
        return hour < 14 ? all : all.reversed()
    }

    /// Лучшее окно выезда: окна по четверти часа, медиана в каждом, 2+ поездки,
    /// не дальше полутора часов от обычного выезда и с заметной экономией.
    /// Окно самого обычного выезда советом не считается — там человек и так.
    static func bestWindow(_ trips: [Trip], usual: TimeInterval, usualDeparture: Int,
                           calendar: Calendar = .current) -> BestWindow? {
        let size = AppConfig.commuteBucketMinutes
        var buckets: [Int: [TimeInterval]] = [:]
        for trip in trips {
            let minute = minuteOfDay(trip.departure, calendar: calendar)
            buckets[minute / size * size, default: []].append(trip.duration)
        }
        let usualBucket = usualDeparture / size * size
        let candidates = buckets.compactMap { start, durations -> BestWindow? in
            guard durations.count >= AppConfig.commuteBucketMinTrips,
                  start != usualBucket,
                  abs(start - usualDeparture) <= AppConfig.commuteAdviceSpanMinutes else { return nil }
            let med = median(durations)
            let saving = usual - med
            guard saving >= AppConfig.commuteMinSavingSeconds else { return nil }
            return BestWindow(startMinute: start, medianDuration: med, saving: saving,
                              trips: durations.count)
        }
        // Больше экономия, при равенстве — ближе к обычному выезду.
        return candidates.min {
            ($0.saving, -abs($0.startMinute - usualDeparture)) > ($1.saving, -abs($1.startMinute - usualDeparture))
        }
    }

    // MARK: - Помощники

    static func minuteOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude)
    }
}

// MARK: - Источник поездок и журнал

/// Что «дороге» нужно знать о поездке. Запись истории — один источник,
/// журнал (`CommuteLedger`) — второй: история держит 50 записей, а при
/// трёх-четырёх поездках в день «медиана за 30 дней» на ней считалась за
/// 12–17 дней (аудит 19.10).
nonisolated protocol CommuteTripSource {
    var id: Double { get }
    var startedAt: Date { get }
    var endedAt: Date { get }
    var movingDuration: TimeInterval { get }
    var distanceMeters: Double { get }
    var startCoordinate: CLLocationCoordinate2D? { get }
    var endCoordinate: CLLocationCoordinate2D? { get }
}

extension TripRecord: CommuteTripSource {}

/// Журнал поездок для «дороги»: только концы, время и длина, 45 дней.
/// Без трека, проездов и баллов — то, что нужно медиане, и ничего больше.
/// Хранится там же, где профиль участков (CommuteProfileStore): на телефоне,
/// вне резервной копии.
nonisolated enum CommuteLedger {

    struct Entry: Codable, Equatable, Sendable, CommuteTripSource {
        let id: Double
        let startedAt: Date
        let endedAt: Date
        let movingDuration: TimeInterval
        let distanceMeters: Double
        let startLat: Double?
        let startLon: Double?
        let endLat: Double?
        let endLon: Double?

        init(_ record: some CommuteTripSource) {
            id = record.id
            startedAt = record.startedAt
            endedAt = record.endedAt
            movingDuration = record.movingDuration
            distanceMeters = record.distanceMeters
            startLat = record.startCoordinate?.latitude
            startLon = record.startCoordinate?.longitude
            endLat = record.endCoordinate?.latitude
            endLon = record.endCoordinate?.longitude
        }

        var startCoordinate: CLLocationCoordinate2D? {
            guard let startLat, let startLon else { return nil }
            return CLLocationCoordinate2D(latitude: startLat, longitude: startLon)
        }
        var endCoordinate: CLLocationCoordinate2D? {
            guard let endLat, let endLon else { return nil }
            return CLLocationCoordinate2D(latitude: endLat, longitude: endLon)
        }
    }

    /// Журнал после новой истории: запись истории главнее (склейка поменяла
    /// длину и финиш), старше окна — вон, новые первыми, не больше потолка.
    static func updated(_ entries: [Entry], with history: [some CommuteTripSource], now: Date,
                        keepDays: Double = AppConfig.commuteLedgerKeepDays,
                        maxEntries: Int = AppConfig.commuteLedgerMaxEntries) -> [Entry] {
        var byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in history { byID[record.id] = Entry(record) }
        let oldest = now.addingTimeInterval(-keepDays * 86_400)
        return Array(byID.values.filter { $0.startedAt >= oldest }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(maxEntries))
    }
}
