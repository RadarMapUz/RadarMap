//
//  CommuteProfileStore.swift
//  RadarMap
//
//  Где живут профиль дороги по участкам (CommuteProfile), журнал поездок
//  для «дороги» (CommuteLedger) и журнал точности прибытия (CommuteAccuracy,
//  24.1): Application Support/Commute, вне резервной
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
    /// Что призрак обещал и когда доехали (24.1), новые первыми.
    private(set) var accuracy: [CommuteAccuracy.Entry] = [] { didSet { revision &+= 1 } }
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
        guard !isLoaded else { return }
        let started = generation
        let (book, ledger, accuracy) = await Self.read()
        // Файл есть, но не читается (процесс подняли до первой разблокировки):
        // загруженным не считаем — свёртка поездки поверх пустого профиля
        // затёрла бы месяц дороги на работу (ревью S9). Повтор с паузой.
        if case .unreadable = book { return retryLoad() }
        if case .unreadable = ledger { return retryLoad() }
        if case .unreadable = accuracy { return retryLoad() }
        // Стёрли, пока читали, — прочитанное уже не наше.
        if started == generation {
            // Битый откладываем; не вышло отложить — как «не читается»:
            // запись поверх затёрла бы его без копии.
            if case .corrupt = book, !JSONFile.setAside(Self.profileURL, log: Log.trips) { return retryLoad() }
            if case .corrupt = ledger, !JSONFile.setAside(Self.ledgerURL, log: Log.trips) { return retryLoad() }
            if case .corrupt = accuracy, !JSONFile.setAside(Self.accuracyURL, log: Log.trips) { return retryLoad() }
            if case .loaded(let value) = book { self.book = value }
            if case .loaded(let value) = ledger { self.ledger = value }
            if case .loaded(let value) = accuracy { self.accuracy = value }
        }
        blocked = false
        isLoaded = true
        // Стёртое человеком, пока файлы не читались, — и из прочитанного.
        if !pendingForget.isEmpty {
            let ids = pendingForget
            pendingForget = []
            forget(ids)
        }
        onLoaded?()
    }

    @ObservationIgnored private var retryDelay = AppConfig.storeRetrySeconds
    @ObservationIgnored private var blocked = false
    /// Поездки, стёртые до чтения файлов (S9): применить к прочитанному.
    @ObservationIgnored private var pendingForget: Set<Double> = []

    private func retryLoad() {
        blocked = true
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, AppConfig.storeRetryMaxSeconds)
        Log.trips.notice("профиль дороги не читается — повтор через \(Int(delay), privacy: .public) с")
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            await Task.pause(seconds: delay)
            guard !Task.isCancelled else { return }
            self?.enqueue { store in await store.loadFromDisk() }
        }
    }

    @ObservationIgnored private var retryTask: Task<Void, Never>?

    /// Данные стали доступны (разблокировка) — читать сейчас, не дожидаясь
    /// паузы повтора. Лишний вызов безвреден: чтение идёт через ту же
    /// очередь и выходит, если уже прочитано.
    func retryLoadNow() {
        guard blocked, !isLoaded else { return }
        retryTask?.cancel()
        retryTask = nil
        enqueue { store in await store.loadFromDisk() }
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
            // Профиль не прочитан (до первой разблокировки) — свёртка поверх
            // пустого затёрла бы его на диске: эту поездку пропускаем.
            guard store.generation == started else { return }
            guard store.isLoaded else {
                Log.trips.notice("профиль дороги ещё не прочитан — поездка в него не свёрнута")
                return
            }
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
    /// затрёт; на диск не пишется. С `trips` (демо-история «дороги») строки —
    /// по этим поездкам, а лишнее против обычного лежит посередине пути: так
    /// у медленных поездок есть «где ушло время» (8.8.8).
    func seedDemo(home: CLLocationCoordinate2D, work: CLLocationCoordinate2D,
                  trips: [TripRecord] = [], now: Date = Date()) {
        func line(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D)
            -> (line: [Int32], ends: [Float], count: Int) {
            let length = GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude)
            let count = max(1, Int(length / 200))
            var line: [Int32] = []
            for k in 0...count {
                let t = Double(k) / Double(count)
                line.append(Int32(((a.latitude + (b.latitude - a.latitude) * t) * 1e5).rounded()))
                line.append(Int32(((a.longitude + (b.longitude - a.longitude) * t) * 1e5).rounded()))
            }
            return (line, (1...count).map { Float(length * Double($0) / Double(count)) }, count)
        }
        func variant(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, hour: Int,
                     minutes: [Double]) -> CommuteProfile.Variant {
            let path = line(a, b)
            let rows = minutes.enumerated().map { i, total in
                let day = Calendar.current.date(byAdding: .day, value: -(i + 1) * 7 / 5 - 1, to: now) ?? now
                let departure = Calendar.current.date(bySettingHour: hour, minute: 20, second: 0, of: day) ?? day
                return CommuteProfile.Row(tripID: departure.timeIntervalSince1970, departure: departure,
                                          weekend: false, arrivalMinute: 0,
                                          seconds: [UInt16](repeating: UInt16(total * 60 / Double(path.count)),
                                                            count: path.count))
            }
            return CommuteProfile.Variant(id: UUID(), line: path.line, ends: path.ends, limitKmh: [], rows: rows,
                                          lastUsed: now)
        }
        /// Строки по демо-поездкам: обычное время — ровно по участкам, лишнее
        /// против медианы — на участках 40–60 % пути (пробка посередине).
        func variant(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                     records: [any CommuteTripSource]) -> CommuteProfile.Variant? {
            guard records.count >= 4 else { return nil }
            let path = line(a, b)
            let durations = records.map(\.movingDuration).sorted()
            let usual = durations[durations.count / 2]
            let first = Int(Double(path.count) * 0.4)
            let jam = first..<max(Int(Double(path.count) * 0.6), first + 1)
            let rows = records.map { record -> CommuteProfile.Row in
                let base = min(record.movingDuration, usual) / Double(path.count)
                let extra = max(0, record.movingDuration - usual) / Double(jam.count)
                let seconds = (0..<path.count).map { UInt16(min(60_000, base + (jam.contains($0) ? extra : 0))) }
                return CommuteProfile.Row(tripID: record.id, departure: record.startedAt, weekend: false,
                                          arrivalMinute: Int16(CommuteProfile.minuteOfDay(record.endedAt,
                                                                                          calendar: .current)),
                                          seconds: seconds)
            }
            return CommuteProfile.Variant(id: UUID(), line: path.line, ends: path.ends, limitKmh: [],
                                          rows: rows.sorted { $0.departure > $1.departure }, lastUsed: now)
        }
        /// Старт неизвестен (демо прошлых сборок без точки старта) — по
        /// финишу: «дорога» связывает такие поездки цепочкой.
        func near(_ point: CLLocationCoordinate2D?, _ place: CLLocationCoordinate2D, unknown: Bool) -> Bool {
            guard let point else { return unknown }
            return GeoMath.fastDistance(point.latitude, point.longitude, place.latitude, place.longitude) < 400
        }
        func demoBook(from sources: [any CommuteTripSource]) -> CommuteProfile.Book {
            var seen = Set<Double>()
            let unique = sources.filter { seen.insert($0.id).inserted }
            let toWork = unique.filter { near($0.startCoordinate, home, unknown: true)
                && near($0.endCoordinate, work, unknown: false) }
            let toHome = unique.filter { near($0.startCoordinate, work, unknown: true)
                && near($0.endCoordinate, home, unknown: false) }
            var book = CommuteProfile.Book()
            book.toWork = [variant(home, work, records: toWork)
                           ?? variant(home, work, hour: 8, minutes: [44, 41, 47, 43, 45])]
            book.toHome = [variant(work, home, records: toHome)
                           ?? variant(work, home, hour: 18, minutes: [39, 37, 42, 38, 40])]
            return book
        }
        // После чтения с диска: журнал «дороги» уже в памяти, и его поездки
        // (демо прошлых запусков) тоже получают строки.
        enqueue { store in
            store.isDemo = true
            store.book = demoBook(from: trips.map { $0 as any CommuteTripSource }
                                  + store.ledger.map { $0 as any CommuteTripSource })
            store.onLoaded?()
        }
    }

    /// Учения призрака `-ghostDrill` (В5, 8.8.9): обычная дорога дом→работа
    /// по прямой — на скорости симулятора (`simctl location start --speed=14`),
    /// шесть будних поездок в этот же час с разбросом ±10 %. Так прогон в
    /// симуляторе за десять минут говорит «как обычно», а медленный отрезок —
    /// «дольше»; на диск не пишется.
    func seedDrill(home: CLLocationCoordinate2D, work: CLLocationCoordinate2D,
                   speedMps: Double = 14, now: Date = Date()) {
        let length = GeoMath.fastDistance(home.latitude, home.longitude, work.latitude, work.longitude)
        let count = max(1, Int(length / 200))
        var line: [Int32] = []
        for k in 0...count {
            let t = Double(k) / Double(count)
            line.append(Int32(((home.latitude + (work.latitude - home.latitude) * t) * 1e5).rounded()))
            line.append(Int32(((home.longitude + (work.longitude - home.longitude) * t) * 1e5).rounded()))
        }
        let ends = (1...count).map { Float(length * Double($0) / Double(count)) }
        let segment = length / Double(count) / speedMps
        let rows = [1.0, 0.92, 1.06, 0.97, 1.1, 0.95].enumerated().map { i, scale in
            let departure = Calendar.current.date(byAdding: .day, value: -(i + 1), to: now) ?? now
            return CommuteProfile.Row(tripID: departure.timeIntervalSince1970, departure: departure,
                                      weekend: UzHolidays.isDayOff(now), arrivalMinute: 0,
                                      seconds: [UInt16](repeating: UInt16((segment * scale).rounded()),
                                                        count: count))
        }
        var book = CommuteProfile.Book()
        book.toWork = [CommuteProfile.Variant(id: UUID(), line: line, ends: ends, limitKmh: [],
                                              rows: rows, lastUsed: now)]
        enqueue { store in
            store.isDemo = true
            store.book = book
            store.onLoaded?()
        }
    }

    /// Снимок `-demoForecastLog` (24.1): журнал точности за три недели будней
    /// — утром прогноз чаще опаздывает (+1…+4 мин), вечером точнее; на диск
    /// не пишется.
    func seedAccuracyDemo(now: Date = Date()) {
        let calendar = Calendar.current
        var entries: [CommuteAccuracy.Entry] = []
        let errors: [Commute.Direction: [Double]] = [.toWork: [4, -1, 2, 3, 0, 5, 1, -2, 3, 2, 1, 4, -1, 2],
                                                     .toHome: [1, -1, 0, 2, -2, 1, 0, 1, -1, 0, 2, 1, -1, 0]]
        for (direction, minutes) in errors {
            for (i, error) in minutes.enumerated() {
                guard let day = calendar.date(byAdding: .day, value: -(i + 1) * 7 / 5 - 1, to: now) else { continue }
                let hour = direction == .toWork ? 8 : 18
                let departure = calendar.date(bySettingHour: hour, minute: 15 + (i % 3) * 10, second: 0,
                                              of: day) ?? day
                let said = departure.addingTimeInterval(40 * 60)
                let point = CommuteAccuracy.Checkpoint(at: departure.addingTimeInterval(90), arrival: said)
                entries.append(CommuteAccuracy.Entry(tripID: departure.timeIntervalSince1970 + (direction == .toWork ? 0 : 1),
                                                     direction: direction, departure: departure,
                                                     arrival: said.addingTimeInterval(error * 60),
                                                     start: point, confirmed: point, middle: nil))
            }
        }
        enqueue { store in
            store.isDemo = true
            store.accuracy = entries.sorted { $0.departure > $1.departure }
        }
    }
    #endif

    // MARK: - Журнал точности (24.1)

    /// Запись по закончившейся поездке; nil — поездку не мерить, и прежняя
    /// запись о ней (склейка финиширует поездку второй раз) уходит.
    func recordAccuracy(_ entry: CommuteAccuracy.Entry?, tripID: Double) {
        let next = entry.map { CommuteAccuracy.appended(accuracy, $0, now: Date()) }
            ?? accuracy.filter { $0.tripID != tripID }
        guard next != accuracy else { return }
        accuracy = next
        if let entry, let said = entry.headline {
            Log.trips.info("точность прибытия: \(entry.direction.rawValue, privacy: .public), сказано \(CommuteGhost.clock(said.arrival), privacy: .public), доехали \(CommuteGhost.clock(entry.arrival), privacy: .public), ошибка \(Int(entry.error(said)), privacy: .public) с")
        }
        guard isLoaded else { return }
        #if DEBUG
        if isDemo { return }
        #endif
        saveAccuracy()
    }

    /// «Прогноз ошибался в среднем на N мин» направления — с пяти поездок.
    func accuracyStats(_ direction: Commute.Direction) -> CommuteAccuracy.Stats? {
        CommuteAccuracy.shownStats(accuracy, direction: direction)
    }

    private func saveAccuracy() {
        let accuracy = accuracy
        let started = generation
        enqueue { store in
            guard store.generation == started else { return }
            await Self.save(accuracy, to: Self.accuracyURL)
        }
    }

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
        let hadAccuracy = accuracy.contains { ids.contains($0.tripID) }
        if hadAccuracy { accuracy.removeAll { ids.contains($0.tripID) } }
        for direction in Commute.Direction.allCases {
            book[direction] = book[direction].map { variant in
                var variant = variant
                variant.rows.removeAll { ids.contains($0.tripID) }
                return variant
            }
        }
        guard isLoaded else {
            pendingForget.formUnion(ids)
            return
        }
        saveLedger()
        if hadAccuracy { saveAccuracy() }
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
        accuracy = []
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
    private static func read() async -> (JSONFile.LoadResult<CommuteProfile.Book>,
                                         JSONFile.LoadResult<[CommuteLedger.Entry]>,
                                         JSONFile.LoadResult<[CommuteAccuracy.Entry]>) {
        (JSONFile.loadChecked(CommuteProfile.Book.self, from: profileURL, log: Log.trips),
         JSONFile.loadChecked([CommuteLedger.Entry].self, from: ledgerURL, log: Log.trips),
         JSONFile.loadChecked([CommuteAccuracy.Entry].self, from: accuracyURL, log: Log.trips))
    }

    @concurrent
    private static func save<T: Encodable & Sendable>(_ value: T, to url: URL) async {
        prepareDirectory()
        _ = JSONFile.save(value, to: url, log: Log.trips)
    }

    @concurrent
    private static func removeFiles() async {
        for url in [profileURL, ledgerURL, accuracyURL] where FileManager.default.fileExists(atPath: url.path) {
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
    nonisolated private static let accuracyURL = directory.appendingPathComponent("accuracy.json")

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
