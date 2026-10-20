//
//  WidgetCommute.swift
//  RadarMap
//
//  Виджет «Дорога на работу» (план 19.10, 9.4): «На работу · обычно 42 мин ·
//  выезжайте до 8:10». Компилируется и в приложение, и в виджет: приложение
//  кладёт готовые числа в App Group, виджет решает только, какую строку
//  показать сейчас — утром дорогу на работу, вечером домой.
//
//  В App Group лежат минуты и длительности, без координат: дом и работа —
//  самые личные данные приложения, и виджету они не нужны. Виджет на экране
//  — выбор человека, который его добавил.
//
//  Чистая логика без часов и диска — WidgetCommuteTests.
//

import Foundation

nonisolated struct CommuteWidgetData: Codable, Equatable, Sendable {
    struct Direction: Codable, Equatable, Sendable {
        /// «Обычно» — медиана за 30 дней, с.
        var usualSeconds: Double
        /// Обычный выезд, минута суток.
        var usualDepartureMinute: Int?
        /// Окно, где доезжают быстрее (совет), минута суток, и его медиана, с.
        var bestStartMinute: Int?
        var bestSeconds: Double?
        /// «Выезжайте до» — к сроку «быть к 9:00» на ближайший день, когда срок
        /// действует (будни, суббота шестидневки, не праздник); nil — срока нет.
        /// Дата, а не минута: в воскресенье «выезжайте до 8:10» было бы неправдой.
        var leaveBy: Date?
    }

    var toWork: Direction?
    var toHome: Direction?
    var updatedAt: Date
}

nonisolated enum WidgetCommute {
    static let key = "widget.commute"
    /// Старше месяца — это уже не «обычно»: дорогу могли сменить.
    static let maxAge: TimeInterval = 30 * 86_400
    /// С этого часа виджет показывает дорогу домой.
    static let eveningHour = 14

    struct Line: Equatable, Sendable {
        let toWork: Bool
        let usualSeconds: Double
        /// Что делать сейчас: «выезжайте до 8:10», «в 7:45 — 36 мин» или
        /// «выезд около 8:20».
        let hint: Hint?
    }

    enum Hint: Equatable, Sendable {
        case leaveBy(minute: Int)
        case best(minute: Int, seconds: Double)
        case usualDeparture(minute: Int)
    }

    /// Строка на сейчас: утром — на работу, с 14:00 — домой (нет одной —
    /// другая); nil — данных нет или они старше месяца.
    static func line(_ data: CommuteWidgetData?, now: Date, calendar: Calendar = .current) -> Line? {
        guard let data, now.timeIntervalSince(data.updatedAt) <= maxAge else { return nil }
        let evening = calendar.component(.hour, from: now) >= eveningHour
        let order: [(Bool, CommuteWidgetData.Direction?)] = evening
            ? [(false, data.toHome), (true, data.toWork)]
            : [(true, data.toWork), (false, data.toHome)]
        guard let (toWork, direction) = order.first(where: { $0.1 != nil }).map({ ($0.0, $0.1!) }) else { return nil }
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let hint: Hint?
        if let leaveBy = direction.leaveBy, calendar.isDate(leaveBy, inSameDayAs: now), now <= leaveBy {
            hint = .leaveBy(minute: calendar.component(.hour, from: leaveBy) * 60
                                + calendar.component(.minute, from: leaveBy))
        } else if let best = direction.bestStartMinute, let seconds = direction.bestSeconds, minute <= best {
            hint = .best(minute: best, seconds: seconds)
        } else if let usual = direction.usualDepartureMinute {
            hint = .usualDeparture(minute: usual)
        } else {
            hint = nil
        }
        return Line(toWork: toWork, usualSeconds: direction.usualSeconds, hint: hint)
    }

    /// Когда перерисовать: на минуте подсказки (после неё она уже другая), на
    /// переходе к вечеру и в полночь — что наступит раньше.
    static func nextRefresh(after now: Date, data: CommuteWidgetData?, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: now)
        var moments: [Date] = [calendar.date(byAdding: .day, value: 1, to: day) ?? now.addingTimeInterval(86_400),
                               day.addingTimeInterval(Double(eveningHour) * 3600)]
        for direction in [data?.toWork, data?.toHome].compactMap({ $0 }) {
            if let best = direction.bestStartMinute { moments.append(day.addingTimeInterval(Double(best + 1) * 60)) }
            if let leaveBy = direction.leaveBy { moments.append(leaveBy.addingTimeInterval(60)) }
        }
        return moments.filter { $0 > now }.min() ?? now.addingTimeInterval(3600)
    }

    static func write(_ data: CommuteWidgetData?) {
        guard let store = SharedDefaults.store else { return }
        guard let data, let encoded = try? JSONEncoder().encode(data) else {
            store.removeObject(forKey: key)
            return
        }
        store.set(encoded, forKey: key)
    }

    /// Битая запись — как её отсутствие: виджет покажет приглашение, а
    /// приложение перепишет снимок при следующем уходе в фон.
    static func read() -> CommuteWidgetData? {
        guard SharedDefaults.hasAppGroup, let raw = SharedDefaults.store?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CommuteWidgetData.self, from: raw)
    }

    /// Те же числа (без отметки времени) — перерисовывать незачем.
    static func sameNumbers(_ a: CommuteWidgetData?, _ b: CommuteWidgetData?) -> Bool {
        a?.toWork == b?.toWork && a?.toHome == b?.toHome && (a == nil) == (b == nil)
    }
}
