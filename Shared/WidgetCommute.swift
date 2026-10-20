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
//  12б.2 добавил к этому три вещи, все — готовыми числами от приложения:
//    * таблицу «сейчас ~44 мин» по 15 минут на окно выезда (±90 мин от
//      обычного) — медиана своих поездок в этот час из профиля дороги. Окно
//      пишется заранее, на ближайший выезд, — утром таймлайн меняется сам,
//      без запуска приложения;
//    * пробки «+8 мин» с отметкой «на 7:52» — живут 30 минут: старше —
//      это уже не сегодняшние пробки, и строка молча пропадает;
//    * последнее место телефона: дом или работа, без координат. Лежит дома
//      вечером — «На работу» с утра понятна, а в 15:00 у дома человек едет
//      не домой, а на работу (вторая смена).
//
//  Чистая логика без часов и диска — WidgetCommuteTests.
//

import Foundation
import os

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
        /// «Сейчас ~N мин» на окно ближайшего выезда, по 15 минут; nil или
        /// пусто — у этих часов нет своих поездок, и обещать нечего.
        var slots: [Slot]? = nil
        /// Пробки сверх обычного и когда они посчитаны.
        var jam: Jam? = nil
    }

    struct Slot: Codable, Equatable, Sendable {
        /// Начало 15-минутного окна выезда.
        let start: Date
        /// Ожидаемое время в пути при выезде в это окно, с.
        let seconds: Double
    }

    struct Jam: Codable, Equatable, Sendable {
        /// Пробки сверх обычного, с (округлено до минуты).
        let extraSeconds: Double
        /// Когда посчитаны — «пробки на 7:52».
        let at: Date
    }

    /// Где телефон был последний раз, — без координат.
    enum Place: String, Codable, Sendable {
        case home, work
    }

    var toWork: Direction?
    var toHome: Direction?
    var updatedAt: Date
    var lastPlace: Place? = nil
    var lastPlaceAt: Date? = nil
}

nonisolated enum WidgetCommute {
    static let key = "widget.commute"
    /// Старше месяца — это уже не «обычно»: дорогу могли сменить.
    static let maxAge: TimeInterval = 30 * 86_400
    /// С этого часа виджет показывает дорогу домой.
    static let eveningHour = 14

    /// Окно таблицы «сейчас»: столько минут до и после обычного выезда.
    static let slotWindowMinutes = 90
    static let slotStepMinutes = 15
    /// Пробки старше — уже не сегодняшние.
    static let jamMaxAge: TimeInterval = 30 * 60
    /// Пробки меньше минуты — не повод для строки.
    static let jamMinSeconds: Double = 60
    /// Последнее место старше — уже не «где я сейчас».
    static let placeMaxAge: TimeInterval = 12 * 3600

    struct Line: Equatable, Sendable {
        let toWork: Bool
        let usualSeconds: Double
        /// Что делать сейчас: «выезжайте до 8:10», «в 7:45 — 36 мин» или
        /// «выезд около 8:20».
        let hint: Hint?
        /// «Сейчас ~N мин» — окно таблицы, в которое попадает «сейчас».
        var nowSeconds: Double? = nil
        /// Пробки сверх обычного, только свежие.
        var jam: CommuteWidgetData.Jam? = nil
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
        let order: [(Bool, CommuteWidgetData.Direction?)] = prefersWork(data, now: now, calendar: calendar)
            ? [(true, data.toWork), (false, data.toHome)]
            : [(false, data.toHome), (true, data.toWork)]
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
        return Line(toWork: toWork, usualSeconds: direction.usualSeconds, hint: hint,
                    nowSeconds: slot(direction.slots, now: now)?.seconds,
                    jam: freshJam(direction.jam, now: now))
    }

    /// Какое направление первое: у дома (свежая отметка) — на работу, у
    /// работы — домой; иначе по часам — утром на работу, с 14:00 домой.
    static func prefersWork(_ data: CommuteWidgetData, now: Date, calendar: Calendar = .current) -> Bool {
        if let place = data.lastPlace, let at = data.lastPlaceAt,
           now >= at, now.timeIntervalSince(at) <= placeMaxAge {
            return place == .home
        }
        return calendar.component(.hour, from: now) < eveningHour
    }

    /// Отметка места для новой записи. Точная позиция у дома или работы — она,
    /// с нынешним временем; позиция известна, но не там (или грубая) — отметки
    /// нет. Позиции нет вовсе — фоновый подъём перед выездом (процесс поднят
    /// без GPS) или запуск до первого фикса — прежняя отметка остаётся как
    /// была: «не знаю, где телефон» не значит «ушёл из дома», а свои 12 часов
    /// она отсчитывает от своего времени. Раньше такая запись стирала отметку
    /// ровно в фоновом подъёме, ради которого она и хранится (ревью 14.1).
    static func placeMark(current: CommuteWidgetData.Place?, positionKnown: Bool,
                          previous: CommuteWidgetData?, now: Date) -> (place: CommuteWidgetData.Place, at: Date)? {
        if let current { return (current, now) }
        guard !positionKnown, let place = previous?.lastPlace, let at = previous?.lastPlaceAt,
              now >= at, now.timeIntervalSince(at) <= placeMaxAge else { return nil }
        return (place, at)
    }

    /// Окно таблицы, в которое попадает `now`.
    static func slot(_ slots: [CommuteWidgetData.Slot]?, now: Date) -> CommuteWidgetData.Slot? {
        slots?.first { now >= $0.start && now < $0.start.addingTimeInterval(Double(slotStepMinutes) * 60) }
    }

    /// Пробки — только свежие и заметные.
    static func freshJam(_ jam: CommuteWidgetData.Jam?, now: Date) -> CommuteWidgetData.Jam? {
        guard let jam, jam.extraSeconds >= jamMinSeconds,
              now >= jam.at, now.timeIntervalSince(jam.at) <= jamMaxAge else { return nil }
        return jam
    }

    /// Начала 15-минутных окон на ближайший выезд: ±90 мин от обычного,
    /// сегодня, если окно ещё не кончилось, иначе завтра; прошедшие окна
    /// сегодняшнего выезда не пишутся.
    static func slotStarts(usualDepartureMinute: Int, now: Date, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        func window(on day: Date) -> (Date, Date) {
            let centre = day.addingTimeInterval(Double(usualDepartureMinute) * 60)
            return (centre.addingTimeInterval(-Double(slotWindowMinutes) * 60),
                    centre.addingTimeInterval(Double(slotWindowMinutes) * 60))
        }
        var (start, end) = window(on: today)
        if now >= end, let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) {
            (start, end) = window(on: tomorrow)
        }
        let step = Double(slotStepMinutes) * 60
        var result: [Date] = []
        var cursor = start
        while cursor < end {
            if cursor.addingTimeInterval(step) > now { result.append(cursor) }
            cursor = cursor.addingTimeInterval(step)
        }
        return result
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
            // Пробки гаснут через 30 минут — в этот момент строка другая.
            if let jam = direction.jam { moments.append(jam.at.addingTimeInterval(jamMaxAge + 1)) }
        }
        if let at = data?.lastPlaceAt { moments.append(at.addingTimeInterval(placeMaxAge + 1)) }
        return moments.filter { $0 > now }.min() ?? now.addingTimeInterval(3600)
    }

    /// Когда приложению проснуться в фоне за пробками (12б.2): за `lead`
    /// до ближайшего обычного выезда (сегодня, если он ещё не близко, иначе
    /// завтра). nil — выезда не знаем, будить незачем. Система вправе
    /// разбудить позже или не разбудить — тогда пробок на виджете просто нет.
    static func nextBackgroundRefresh(data: CommuteWidgetData?, now: Date, lead: TimeInterval,
                                      calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        let wakes = [data?.toWork, data?.toHome].compactMap { $0?.usualDepartureMinute }.compactMap { minute -> Date? in
            let todayWake = today.addingTimeInterval(Double(minute) * 60 - lead)
            if todayWake > now { return todayWake }
            return calendar.date(byAdding: .day, value: 1, to: todayWake)
        }
        return wakes.min()
    }

    /// Записи таймлайна: сейчас, каждое окно таблицы до следующей перерисовки
    /// — «~44 мин» меняется на 15-минутной границе без запуска приложения.
    static func entryDates(after now: Date, data: CommuteWidgetData?, calendar: Calendar = .current) -> [Date] {
        let until = nextRefresh(after: now, data: data, calendar: calendar)
        let starts = [data?.toWork?.slots, data?.toHome?.slots].compactMap { $0 }.flatMap { $0 }
            .map(\.start)
            .flatMap { [$0, $0.addingTimeInterval(Double(slotStepMinutes) * 60)] }
            .filter { $0 > now && $0 < until }
        return [now] + Array(Set(starts)).sorted()
    }

    /// Не закодировалось (NaN в длительностях — JSONEncoder такого не пишет) —
    /// запись снимается, как при «дороги нет»: старые числа виджет показывал бы
    /// как свежие. Но не молча (правило 3): Log приложения сюда не доходит —
    /// файл общий с виджетом, поэтому свой Logger той же подсистемы.
    static func write(_ data: CommuteWidgetData?) {
        guard let store = SharedDefaults.store else { return }
        guard let data else {
            store.removeObject(forKey: key)
            return
        }
        do {
            store.set(try JSONEncoder().encode(data), forKey: key)
        } catch {
            Logger(subsystem: "uz.radarmap.ios", category: "app")
                .error("виджет дороги не записан: \(error.localizedDescription, privacy: .public)")
            store.removeObject(forKey: key)
        }
    }

    /// Битая запись — как её отсутствие: виджет покажет приглашение, а
    /// приложение перепишет снимок при следующем уходе в фон.
    static func read() -> CommuteWidgetData? {
        guard SharedDefaults.hasAppGroup, let raw = SharedDefaults.store?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CommuteWidgetData.self, from: raw)
    }

    /// Те же числа (без отметки времени) — перерисовывать незачем.
    static func sameNumbers(_ a: CommuteWidgetData?, _ b: CommuteWidgetData?) -> Bool {
        sameDirection(a?.toWork, b?.toWork) && sameDirection(a?.toHome, b?.toHome)
            && (a == nil) == (b == nil)
            && a?.lastPlace == b?.lastPlace
            && sameHour(a?.lastPlaceAt, b?.lastPlaceAt)
    }

    /// Пробки пересчитываются каждые 2 минуты, и время у них новое каждый
    /// раз: сравнение «как есть» перезагружало бы виджет каждые 2 минуты и
    /// сжигало дневной бюджет WidgetKit. Те же минуты пробок в пределах
    /// `jamRewriteSeconds` — те же числа.
    static func sameDirection(_ a: CommuteWidgetData.Direction?, _ b: CommuteWidgetData.Direction?) -> Bool {
        guard var a, var b else { return a == nil && b == nil }
        let jamA = a.jam, jamB = b.jam
        a.jam = nil
        b.jam = nil
        guard a == b else { return false }
        switch (jamA, jamB) {
        case (nil, nil): return true
        case let (x?, y?):
            return x.extraSeconds == y.extraSeconds && abs(x.at.timeIntervalSince(y.at)) < jamRewriteSeconds
        default: return false
        }
    }

    /// Те же пробки, посчитанные позже этого, — переписать: иначе отметка
    /// «на 7:52» состарится и строка погаснет при живых пробках.
    static let jamRewriteSeconds: TimeInterval = 10 * 60

    /// Отметка места переписывается на каждом уходе в фон; перерисовывать
    /// ради сдвига на минуты незачем — срок «12 часов» от этого не меняется.
    private static func sameHour(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.timeIntervalSince(b)) < 3600
    }
}
