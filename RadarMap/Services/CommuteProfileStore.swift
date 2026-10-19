//
//  CommuteProfileStore.swift
//  RadarMap
//
//  Где живут профиль дороги по участкам (CommuteProfile) и журнал поездок
//  для «дороги» (CommuteLedger): Application Support/Commute, вне резервной
//  копии — это дом, работа и распорядок дня, их не должно быть ни на
//  сервере, ни в чужой копии телефона. Пересобирается сам из новых поездок,
//  поэтому терять его не страшно.
//
//  Всё, что трогает диск, идёт ОДНОЙ очередью (`enqueue`): чтение при
//  запуске, свёртка поездки, записи и стирание. Иначе запоздавшая запись
//  возвращала бы стёртое «Время дороги на работу», а старый журнал затирал
//  новый (ревью 19.10). Стирание поднимает `generation` — всё, что встало в
//  очередь до него, отказывается писать.
//

import CoreLocation
import Foundation
import os

@MainActor
@Observable
final class CommuteProfileStore {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    private(set) var book = CommuteProfile.Book() { didSet { revision &+= 1 } }
    /// Растёт с каждой сменой профиля (чтение, свёртка, стирание): по нему
    /// «сейчас ~44 мин» понимает, что считать заново.
    private(set) var revision = 0
    private(set) var ledger: [CommuteLedger.Entry] = []
    /// Файлы прочитаны: до этого журнал на диск не пишется — запись затёрла
    /// бы его огрызком из одной истории.
    @ObservationIgnored private(set) var isLoaded = false
    /// Файлы прочитаны — журнал пора учесть в «дороге» (AppEnvironment).
    @ObservationIgnored var onLoaded: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onLoaded,
                                               "CommuteProfileStore.onLoaded") }
    }
    @ObservationIgnored private var chain: Task<Void, Never>?
    /// Растёт при стирании: работа, вставшая в очередь раньше, не пишет.
    @ObservationIgnored private var generation = 0

    init() {
        enqueue { store in await store.loadFromDisk() }
    }

    private func enqueue(_ work: @escaping @MainActor (CommuteProfileStore) async -> Void) {
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }

    private func loadFromDisk() async {
        let started = generation
        let (book, ledger) = await Self.read()
        // Стёрли, пока читали, — прочитанное уже не наше.
        if started == generation {
            if let book { self.book = book }
            if let ledger { self.ledger = ledger }
        }
        isLoaded = true
        onLoaded?()
    }

    // MARK: - Поездка

    /// Свернуть поездку дом↔работа в профиль. Вызывать только для поездок
    /// направления (решает вызывающий по Commute.trips). Трек и время —
    /// массивами как есть: точки со временем собираются вне main.
    func ingest(record: TripRecord, track: [TrackPoint], times: [Double],
                direction: Commute.Direction, limits: LimitIndex?) {
        let stops = (record.stops ?? []).map {
            $0.from.timeIntervalSince1970...max($0.from.timeIntervalSince1970, $0.to.timeIntervalSince1970)
        }
        let started = generation
        enqueue { store in
            guard store.generation == started else { return }
            let book = await Self.folded(store.book, track: track, times: times, direction: direction,
                                         tripID: record.id, departure: record.startedAt,
                                         arrival: record.endedAt, stops: stops, limits: limits)
            guard store.generation == started else { return }
            store.book = book
            #if DEBUG
            if store.isDemo { return }
            #endif
            await Self.save(book, to: Self.profileURL)
            let rows = book[direction].reduce(0) { $0 + $1.rows.count }
            Log.trips.info("профиль дороги: \(direction.rawValue, privacy: .public), вариантов \(book[direction].count, privacy: .public), строк \(rows, privacy: .public)")
        }
    }

    @concurrent
    private static func folded(_ book: CommuteProfile.Book, track: [TrackPoint], times: [Double],
                               direction: Commute.Direction, tripID: Double,
                               departure: Date, arrival: Date,
                               stops: [ClosedRange<Double>], limits: LimitIndex?) async -> CommuteProfile.Book {
        let points = zip(track, times).map { CommuteProfile.TimedPoint(lat: $0.0.lat, lon: $0.0.lon, t: $0.1) }
        return CommuteProfile.fold(points, into: book, direction: direction, tripID: tripID,
                                   departure: departure, arrival: arrival, stops: stops,
                                   limitAt: limits.map { index in { index.limit(near: $0) } },
                                   now: Date())
    }

    #if DEBUG
    /// Демо-профиль в памяти: свёртка и стирание его на диск не пишут.
    @ObservationIgnored private var isDemo = false

    /// Снимок `-demoCommutes`: профиль пути дом↔работа по прямой, пять будних
    /// утр и вечеров — «сейчас ~44 мин» без настоящих поездок. Встаёт в ту же
    /// очередь, что и чтение с диска, — после него, и прочитанное его не
    /// затрёт; на диск не пишется.
    func seedDemo(home: CLLocationCoordinate2D, work: CLLocationCoordinate2D, now: Date = Date()) {
        func variant(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, hour: Int,
                     minutes: [Double]) -> CommuteProfile.Variant {
            let length = GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude)
            let count = max(1, Int(length / 200))
            var line: [Int32] = []
            for k in 0...count {
                let t = Double(k) / Double(count)
                line.append(Int32(((a.latitude + (b.latitude - a.latitude) * t) * 1e5).rounded()))
                line.append(Int32(((a.longitude + (b.longitude - a.longitude) * t) * 1e5).rounded()))
            }
            let ends = (1...count).map { Float(length * Double($0) / Double(count)) }
            let rows = minutes.enumerated().map { i, total in
                let day = Calendar.current.date(byAdding: .day, value: -(i + 1) * 7 / 5 - 1, to: now) ?? now
                let departure = Calendar.current.date(bySettingHour: hour, minute: 20, second: 0, of: day) ?? day
                return CommuteProfile.Row(tripID: departure.timeIntervalSince1970, departure: departure,
                                          weekend: false, arrivalMinute: 0,
                                          seconds: [UInt16](repeating: UInt16(total * 60 / Double(count)),
                                                            count: count))
            }
            return CommuteProfile.Variant(id: UUID(), line: line, ends: ends, limitKmh: [], rows: rows,
                                          lastUsed: now)
        }
        var book = CommuteProfile.Book()
        book.toWork = [variant(home, work, hour: 8, minutes: [44, 41, 47, 43, 45])]
        book.toHome = [variant(work, home, hour: 18, minutes: [39, 37, 42, 38, 40])]
        enqueue { store in
            store.isDemo = true
            store.book = book
            store.onLoaded?()
        }
    }
    #endif

    // MARK: - Журнал

    /// Журнал после изменившейся истории (финиш, склейка): новый журнал —
    /// им и считается «дорога». До чтения файлов — только в памяти.
    @discardableResult
    func updateLedger(with history: [TripRecord]) -> [CommuteLedger.Entry] {
        let next = CommuteLedger.updated(ledger, with: history, now: Date())
        guard next != ledger else { return next }
        ledger = next
        if isLoaded { saveLedger() }
        return next
    }

    /// Человек стёр поездки (nil — всю историю): журнал и строки профиля
    /// забывают их тоже — стёртое не должно жить в медиане и на диске.
    func forget(_ ids: Set<Double>?) {
        guard let ids else { return clear() }
        ledger.removeAll { ids.contains($0.id) }
        for direction in Commute.Direction.allCases {
            book[direction] = book[direction].map { variant in
                var variant = variant
                variant.rows.removeAll { ids.contains($0.tripID) }
                return variant
            }
        }
        guard isLoaded else { return }
        saveLedger()
        let book = book
        let started = generation
        enqueue { store in
            guard store.generation == started else { return }
            #if DEBUG
            if store.isDemo { return }
            #endif
            await Self.save(book, to: Self.profileURL)
        }
    }

    /// Выключили «Время дороги на работу» или стёрли историю — выученное
    /// стирается целиком. Через очередь: запись, начатая раньше, кончится до
    /// удаления файлов, а не после.
    func clear() {
        generation += 1
        book = CommuteProfile.Book()
        ledger = []
        enqueue { _ in await Self.removeFiles() }
    }

    private func saveLedger() {
        let ledger = ledger
        let started = generation
        enqueue { store in
            guard store.generation == started else { return }
            await Self.save(ledger, to: Self.ledgerURL)
        }
    }

    // MARK: - Диск

    @concurrent
    private static func read() async -> (CommuteProfile.Book?, [CommuteLedger.Entry]?) {
        (JSONFile.load(CommuteProfile.Book.self, from: profileURL, log: Log.trips),
         JSONFile.load([CommuteLedger.Entry].self, from: ledgerURL, log: Log.trips))
    }

    @concurrent
    private static func save<T: Encodable & Sendable>(_ value: T, to url: URL) async {
        prepareDirectory()
        _ = JSONFile.save(value, to: url, log: Log.trips)
    }

    @concurrent
    private static func removeFiles() async {
        for url in [profileURL, ledgerURL] where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                Log.trips.error("профиль дороги не стёрт: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated private static let directory: URL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Commute", isDirectory: true)
    nonisolated private static let profileURL = directory.appendingPathComponent("profiles.json")
    nonisolated private static let ledgerURL = directory.appendingPathComponent("ledger.json")

    /// Папка — вне резервной копии: один флаг закрывает оба файла.
    nonisolated private static func prepareDirectory() {
        var url = directory
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            Log.trips.error("папка профиля дороги: \(error.localizedDescription, privacy: .public)")
        }
    }
}
