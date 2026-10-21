//
//  CommuteAccuracy.swift
//  RadarMap
//
//  Журнал точности прибытия (этап 24.1): что призрак сказал и когда
//  приехали на самом деле. До него точность прогноза не мерилась нигде —
//  «дал 8:25, приехал 8:38» владелец заметил сам, а сколько таких дней,
//  в какую сторону и в какой час, не знал никто.
//
//  На поездку дом↔работа — одна запись: направление, выезд, прогноз
//  прибытия в трёх точках (первый показанный — с ~300 м, после 1,5 км и на
//  середине линии) и факт. Из записей — статистика (средняя абсолютная
//  ошибка и сдвиг, по направлению и часу выезда) и медленная поправка
//  остаточного сдвига для базы (biasFactor → CommuteGhost.baseline).
//
//  Только на телефоне, рядом с профилем дороги (CommuteProfileStore, вне
//  копии): время выезда из дома — самое личное, что знает приложение.
//
//  Чистая логика без часов и диска — CommuteAccuracyTests.
//

import Foundation

/// Направление пишется в журнал на диск строкой «toWork»/«toHome».
extension Commute.Direction: Codable {}

nonisolated enum CommuteAccuracy {

    /// Что сказали: прибытие и когда сказали. `factor` — поправка сдвига
    /// журнала, с которой посчитан прогноз (nil — 1): без неё поправка
    /// училась бы на своих же поправленных ошибках и раскачивалась.
    struct Checkpoint: Codable, Equatable, Sendable {
        let at: Date
        let arrival: Date
        var factor: Double?
    }

    /// Одна поездка. Новые поля — только Optional (ARCHITECTURE.md, правило 18).
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let tripID: Double
        let direction: Commute.Direction
        let departure: Date
        /// Когда доехали до конца своей линии (иначе — конец поездки).
        let arrival: Date
        /// Первый показанный прогноз (с 24.3 — с ~300 м пути).
        var start: Checkpoint?
        /// После 1,5 км — с этого места прогноз и звучит.
        var confirmed: Checkpoint?
        /// На середине линии.
        var middle: Checkpoint?

        var id: Double { tripID }

        /// Точка, по которой судим «ошибался на N мин»: самая ранняя — та, что
        /// водитель увидел первой и по которой решал, успевает ли.
        var headline: Checkpoint? { start ?? confirmed ?? middle }

        /// Факт минус сказанное, с: плюс — приехали позже, чем обещали.
        func error(_ checkpoint: Checkpoint) -> TimeInterval {
            arrival.timeIntervalSince(checkpoint.arrival)
        }
    }

    // MARK: - Запись в пути

    /// Копит точки одной поездки; на финише — запись (или nil). Чистая
    /// структура: её кормит CommuteLiveService пересчётами призрака.
    struct Recorder: Equatable, Sendable {
        let direction: Commute.Direction
        let departure: Date
        let factor: Double
        private(set) var start: Checkpoint?
        private(set) var confirmed: Checkpoint?
        private(set) var middle: Checkpoint?
        private(set) var reachedEnd: Date?
        /// Сошли с линии после первого прогноза: приехали другой дорогой — это
        /// не ошибка прогноза, в статистику не идёт.
        private(set) var leftLine = false

        init(direction: Commute.Direction, departure: Date, factor: Double = 1) {
            self.direction = direction
            self.departure = departure
            self.factor = factor
        }

        /// Пересчёт призрака: прибытие, где мы на линии и ранний ли он.
        mutating func note(arrival: Date, along: Double, length: Double, early: Bool, now: Date) {
            let point = Checkpoint(at: now, arrival: arrival, factor: factor == 1 ? nil : factor)
            if start == nil { start = point }
            if !early, confirmed == nil { confirmed = point }
            if length > 0, along >= length / 2, middle == nil { middle = point }
            if reachedEnd == nil, length - along <= AppConfig.commuteAccuracyEndMeters { reachedEnd = now }
        }

        /// Прогноз спрятан «другой дорогой».
        mutating func noteLeftLine() {
            if start != nil, reachedEnd == nil { leftLine = true }
        }

        /// Запись по закончившейся поездке. nil — нечего мерить: ни одного
        /// прогноза, ушли с линии, стояли по дороге (магазин — не ошибка
        /// прогноза) или время не сходится.
        func entry(tripID: Double, endedAt: Date, stops: [ClosedRange<Date>]) -> Entry? {
            guard let first = start, !leftLine else { return nil }
            let arrival = reachedEnd ?? endedAt
            guard arrival > first.at,
                  !stops.contains(where: { $0.upperBound > first.at && $0.lowerBound < arrival })
            else { return nil }
            return Entry(tripID: tripID, direction: direction, departure: departure, arrival: arrival,
                         start: start, confirmed: confirmed, middle: middle)
        }
    }

    // MARK: - Журнал

    /// Новая запись: та же поездка (склейка финиширует её второй раз) —
    /// заменяется; старше `commuteAccuracyKeepDays` и сверх
    /// `commuteAccuracyMaxEntries` — вон. Новые первыми.
    static func appended(_ journal: [Entry], _ entry: Entry, now: Date) -> [Entry] {
        let oldest = now.addingTimeInterval(-AppConfig.commuteAccuracyKeepDays * 86_400)
        let kept = journal.filter { $0.tripID != entry.tripID && $0.departure >= oldest }
        return Array(([entry] + kept).sorted { $0.departure > $1.departure }
            .prefix(AppConfig.commuteAccuracyMaxEntries))
    }

    // MARK: - Статистика

    struct Stats: Equatable, Sendable {
        let trips: Int
        /// Средняя абсолютная ошибка, с.
        let meanAbsolute: TimeInterval
        /// Средний сдвиг (факт − прогноз), с: плюс — приезжали позже обещанного.
        let bias: TimeInterval

        /// «В среднем на N мин» — округлено, не меньше 1 (меньше минуты —
        /// «точно»: см. isExact).
        var meanMinutes: Int { max(1, Int((meanAbsolute / 60).rounded())) }
        var isExact: Bool { meanAbsolute < 30 }
        var biasMinutes: Int { Int((bias / 60).rounded()) }
    }

    /// Ошибка по `headline` последних `commuteAccuracyStatsTrips` поездок
    /// направления; `hour` — только с выездом в этот час. nil — записей нет.
    static func stats(_ journal: [Entry], direction: Commute.Direction? = nil, hour: Int? = nil,
                      calendar: Calendar = .current) -> Stats? {
        let errors = journal
            .filter { direction == nil || $0.direction == direction }
            .filter { hour == nil || calendar.component(.hour, from: $0.departure) == hour }
            .sorted { $0.departure > $1.departure }
            .prefix(AppConfig.commuteAccuracyStatsTrips)
            .compactMap { entry in entry.headline.map(entry.error) }
        guard !errors.isEmpty else { return nil }
        let n = Double(errors.count)
        return Stats(trips: errors.count,
                     meanAbsolute: errors.reduce(0) { $0 + abs($1) } / n,
                     bias: errors.reduce(0, +) / n)
    }

    /// Строка в «Дорога на работу» — только с `commuteAccuracyMinTrips`
    /// поездок: средняя по двум — не «в среднем».
    static func shownStats(_ journal: [Entry], direction: Commute.Direction) -> Stats? {
        guard let stats = stats(journal, direction: direction),
              stats.trips >= AppConfig.commuteAccuracyMinTrips else { return nil }
        return stats
    }

    /// По часам выезда — для выгрузки и разбора: в восемь ошибается, в семь нет?
    static func byHour(_ journal: [Entry], direction: Commute.Direction,
                       calendar: Calendar = .current) -> [Int: Stats] {
        let hours = Set(journal.filter { $0.direction == direction }
            .map { calendar.component(.hour, from: $0.departure) })
        var result: [Int: Stats] = [:]
        for hour in hours {
            result[hour] = stats(journal, direction: direction, hour: hour, calendar: calendar)
        }
        return result
    }

    // MARK: - Поправка сдвига (24.2)

    /// Множитель базы направления: во сколько раз остаток пути на деле дольше
    /// сказанного (без прежней поправки), медиана по последним
    /// `commuteAccuracyBiasWindow` поездкам, половиной найденного и в границах
    /// `commuteAccuracyBiasMin…Max`. Меньше `commuteAccuracyMinTrips` — 1.
    static func biasFactor(_ journal: [Entry], direction: Commute.Direction) -> Double {
        let ratios = journal
            .filter { $0.direction == direction }
            .sorted { $0.departure > $1.departure }
            .compactMap { entry -> Double? in
                guard let point = entry.headline else { return nil }
                let said = point.arrival.timeIntervalSince(point.at)
                let real = entry.arrival.timeIntervalSince(point.at)
                guard said >= AppConfig.commuteAccuracyMinRemainingSeconds, real > 0 else { return nil }
                return real / (said / (point.factor ?? 1))
            }
            .prefix(AppConfig.commuteAccuracyBiasWindow)
        guard ratios.count >= AppConfig.commuteAccuracyMinTrips else { return 1 }
        let median = CommuteGhost.quantile(ratios.sorted(), 0.5)
        let factor = 1 + (median - 1) * AppConfig.commuteAccuracyBiasGain
        return min(max(factor, AppConfig.commuteAccuracyBiasMin), AppConfig.commuteAccuracyBiasMax)
    }

    // MARK: - Выгрузка

    static let csvHeader = ["direction", "departure", "arrival", "said_start", "said_1_5km", "said_middle",
                            "error_min"]

    /// `commute_forecast.csv` в архиве «Экспорт всех поездок» (24.1): без
    /// координат и номера поездки. Направление — сознательно: без него журнал
    /// не читается. Цена известна — по времени выезда строка находит свою
    /// поездку в trips.csv, и её GPX начинается у дома; архив уходит туда,
    /// куда его отправит сам человек, и лист «Поделиться» это подразумевает.
    static func csv(_ journal: [Entry], timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        func stamp(_ point: Checkpoint?) -> String { point.map { formatter.string(from: $0.arrival) } ?? "" }
        var rows = [csvHeader.joined(separator: ",")]
        for entry in journal.sorted(by: { $0.departure < $1.departure }) {
            rows.append([
                entry.direction == .toWork ? "to_work" : "to_home",
                formatter.string(from: entry.departure),
                formatter.string(from: entry.arrival),
                stamp(entry.start), stamp(entry.confirmed), stamp(entry.middle),
                entry.headline.map { String(format: "%.1f", entry.error($0) / 60) } ?? "",
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }
}
