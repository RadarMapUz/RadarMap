//
//  FineMatch.swift
//  RadarMap
//
//  Пришедший штраф → проезд в истории (этап 17.1). Чистая логика, тесты —
//  FineMatchTests.
//
//  Правило то же, что у ворот оповещения, только с другой стороны: молча не
//  угадываем. Проезд-кандидат — в окне по времени (часы камер уходят на
//  минуты); место и скорость могут кандидата ОТВЕРГНУТЬ (координата дальше
//  порога, скорость не сходится с нашим замером) или ПОДТВЕРДИТЬ. Один
//  кандидат с подтверждением — сверено. Два близких по времени, ничем не
//  различимых, — спрашиваем человека, а не выбираем за него. Один без
//  подтверждений (ни места, ни скорости в штрафе) — тоже спрашиваем.
//
//  Записи поездок чистятся раньше, чем приходит поздний штраф: тогда сверка
//  смотрит в дневную сводку — было ли в тот день превышение, которого нет в
//  сохранённых записях. Деньги дня переносятся хирургически (dayShift), и
//  отвязка возвращает ровно перенесённое.
//
//  Штраф без проезда — нормальный исход: он хранится и показывается
//  «без поездки в истории». Рейтинг и «Где теряете баллы» сверка не трогает
//  никогда: они про езду, а не про почту.
//

import Foundation

nonisolated enum FineMatch {

    /// Что известно о штрафе для сверки.
    struct Query: Equatable, Sendable {
        var at: Date
        /// Известно время суток. Нет — ищем по всему календарному дню.
        var timeKnown: Bool
        var place: String?
        var lat: Double?
        var lon: Double?
        var speedKmh: Int?
    }

    enum Agreement: Equatable, Sendable {
        case agrees
        /// Данных для суждения нет (у штрафа или у проезда) — не довод ни за, ни против.
        case unknown
        case disagrees
    }

    struct Candidate: Identifiable, Equatable, Sendable {
        let tripID: Double
        let passID: UUID
        /// Проезд минус штраф, секунды.
        let timeDelta: TimeInterval
        let place: Agreement
        let speed: Agreement
        var id: UUID { passID }
        /// Сколько независимых подтверждений кроме времени.
        var support: Int { (place == .agrees ? 1 : 0) + (speed == .agrees ? 1 : 0) }
    }

    enum Result: Equatable, Sendable {
        /// Один проезд, и есть чем подтвердить.
        case matched(Candidate)
        /// Решает человек: несколько равных кандидатов или один без подтверждений.
        case choose([Candidate])
        /// Проезда в записях нет, но дневная сводка этого дня помнит превышение
        /// у камеры, чья запись уже вычищена.
        case day(Date)
        /// Ничего — штраф «без поездки в истории».
        case none
    }

    /// Сверить штраф с историей. `taken` — проезды, уже сверенные с ДРУГИМИ
    /// штрафами: один проезд — одно постановление.
    static func match(_ query: Query, history: [TripRecord], days: [TripDay],
                      taken: Set<UUID> = [], calendar: Calendar = .current) -> Result {
        let found = candidates(query, history: history, taken: taken, calendar: calendar)
        if found.isEmpty {
            let day = calendar.startOfDay(for: query.at)
            return orphanOverPasses(day: day, history: history, days: days, calendar: calendar) > 0
                ? .day(day) : .none
        }
        let best = found.map(\.support).max() ?? 0
        let leaders = found.filter { $0.support == best }
        if best > 0, leaders.count == 1 { return .matched(leaders[0]) }
        return .choose(found)
    }

    /// Проезды, которые могут быть этим штрафом: в окне по времени и ничем
    /// не опровергнутые. Ближние по времени — первыми.
    static func candidates(_ query: Query, history: [TripRecord], taken: Set<UUID> = [],
                           calendar: Calendar = .current) -> [Candidate] {
        var result: [Candidate] = []
        for record in history {
            // Поездка целиком вне окна — её проезды не смотрим.
            guard inWindow(query, from: record.startedAt, to: record.endedAt, calendar: calendar) else { continue }
            for pass in record.passed where !taken.contains(pass.id) {
                guard inWindow(query, from: pass.date, to: pass.date, calendar: calendar) else { continue }
                let place = placeAgreement(query, pass: pass)
                let speed = speedAgreement(query.speedKmh, passSpeed: pass.speedKmh)
                guard place != .disagrees, speed != .disagrees else { continue }
                result.append(Candidate(tripID: record.id, passID: pass.id,
                                        timeDelta: pass.date.timeIntervalSince(query.at),
                                        place: place, speed: speed))
            }
        }
        return result.sorted { abs($0.timeDelta) < abs($1.timeDelta) }
    }

    /// Все проезды календарного дня штрафа — для ручного выбора «из проездов
    /// этого дня» (форма) и для «не тот проезд».
    static func passes(onDayOf date: Date, history: [TripRecord],
                       calendar: Calendar = .current) -> [(record: TripRecord, pass: PassedCamera)] {
        history.flatMap { record in
            record.passed.filter { calendar.isDate($0.date, inSameDayAs: date) }
                .map { (record: record, pass: $0) }
        }
        .sorted { $0.pass.date < $1.pass.date }
    }

    // MARK: - Доводы

    private static func inWindow(_ query: Query, from start: Date, to end: Date,
                                 calendar: Calendar) -> Bool {
        if query.timeKnown {
            let window = AppConfig.fineMatchWindowSeconds
            return start.timeIntervalSince(query.at) <= window && query.at.timeIntervalSince(end) <= window
        }
        let day = calendar.startOfDay(for: query.at)
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
        return start < next && end >= day
    }

    /// Место: координата решает в обе стороны (камера одна и та же — расходятся
    /// метры, а не километры). Текст адреса может только подтвердить: «Чиланзар»
    /// в СМС и «Бунёдкор» у камеры бывают одним местом, и несовпадение слов —
    /// не доказательство, что это другая камера.
    static func placeAgreement(_ query: Query, pass: PassedCamera) -> Agreement {
        if let lat = query.lat, let lon = query.lon, let plat = pass.lat, let plon = pass.lon {
            let distance = GeoMath.fastDistance(lat, lon, plat, plon)
            return distance <= AppConfig.fineMatchPlaceMeters ? .agrees : .disagrees
        }
        if let place = query.place, !pass.location.isEmpty,
           FinePlace.similarity(place, pass.location) >= AppConfig.fineMatchPlaceSimilarity {
            return .agrees
        }
        return .unknown
    }

    /// Скорость: камера меряет в своей точке, мы — минимум в зоне измерения.
    /// Камера может показать заметно больше нашего минимума и почти никогда —
    /// заметно меньше.
    static func speedAgreement(_ fineSpeed: Int?, passSpeed: Double) -> Agreement {
        guard let fineSpeed else { return .unknown }
        let delta = Double(fineSpeed) - passSpeed
        return delta <= AppConfig.fineMatchSpeedAboveKmh && delta >= -AppConfig.fineMatchSpeedBelowKmh
            ? .agrees : .disagrees
    }

    // MARK: - Дневная сводка (запись вычищена)

    /// Превышения дня, которых нет в сохранённых записях этого дня: проезды,
    /// чьи записи уже вычищены. Ноль — сверять в дне не с чем.
    static func orphanOverPasses(day: Date, history: [TripRecord], days: [TripDay],
                                 calendar: Calendar = .current) -> Int {
        guard let row = days.first(where: { $0.day == day }) else { return 0 }
        let kept = records(onDay: day, history: history, calendar: calendar).reduce(0) { total, record in
            total + record.passed.count { pass in
                guard let limit = pass.limitKmh else { return false }
                return FineSchedule.fine(overKmh: pass.speedKmh - Double(limit)) > 0
            }
        }
        return max(0, row.overPasses - kept)
    }

    /// Сколько денег дня перенести, когда штраф сверен с днём: «возможные»
    /// дня, которые не принадлежат сохранённым записям (вычищенным проездам),
    /// уменьшаются не больше чем на оценку штрафа; в «пришло» кладётся сумма
    /// постановления (или та же оценка). Оценки нет (ни суммы, ни скорости с
    /// лимитом) — не переносим ничего: деньги по догадке не двигаем.
    static func dayShift(day: Date, amount: Double?, speedKmh: Int?, limitKmh: Int?,
                         history: [TripRecord], days: [TripDay],
                         calendar: Calendar = .current) -> (riskMoved: Double, paidAdded: Double) {
        guard let row = days.first(where: { $0.day == day }) else { return (0, 0) }
        let keptRisk = records(onDay: day, history: history, calendar: calendar)
            .reduce(0.0) { $0 + TripHistory.fineRisk(of: $1.passed) }
        let orphanRisk = max(0, row.fineRisk - keptRisk)
        let estimate: Double? = {
            guard let speedKmh, let limitKmh else { return nil }
            let fine = FineSchedule.fine(overKmh: Double(speedKmh - limitKmh))
            return fine > 0 ? fine : nil
        }()
        guard let unit = estimate ?? amount else { return (0, 0) }
        return (min(orphanRisk, unit), amount ?? unit)
    }

    private static func records(onDay day: Date, history: [TripRecord],
                                calendar: Calendar) -> [TripRecord] {
        history.filter { calendar.startOfDay(for: $0.startedAt) == day }
    }
}

// MARK: - Адрес словами

/// Сравнение адреса из уведомления с подписью камеры. Подписи в базе — на
/// узбекской латинице и кириллице вперемешку, в СМС — по-русски: «ул. Амира
/// Темура». Приведение то же, что у поиска адресов (`AddressBook.fold`: одна
/// латиница, oʻ/ў, q→k, o→a — «Чиланзар» и «Chilonzor» одно слово), сверху
/// выброшены служебные слова адреса камеры («тумани», «kesishmasi», «oldi»),
/// а слова сравниваются мягко — по общему корню («Амира» и «Amir»).
nonisolated enum FinePlace {
    /// Доля совпавших значимых слов от меньшего из двух наборов, 0…1.
    static func similarity(_ a: String, _ b: String) -> Double {
        let left = tokens(a), right = tokens(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let (small, large) = left.count <= right.count ? (left, right) : (right, left)
        let matched = small.filter { token in large.contains { same(token, $0) } }
        // Совпали одни числа (дом 12 и км 12) — это не адрес.
        guard matched.contains(where: { $0.contains(where: \.isLetter) }) else { return 0 }
        return Double(matched.count) / Double(small.count)
    }

    /// Значимые слова адреса в приведённом виде, без повторов.
    static func tokens(_ text: String) -> [String] {
        var seen = Set<String>()
        return AddressBook.fold(text).split(separator: " ").map(String.init).filter { word in
            guard !AddressBook.noise.contains(word), !noise.contains(word) else { return false }
            guard word.allSatisfy(\.isNumber) ? word.count >= 2 : word.count >= 3 else { return false }
            return seen.insert(word).inserted
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard !a.allSatisfy(\.isNumber), !b.allSatisfy(\.isNumber) else { return false }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if short.count >= 4, long.hasPrefix(short) { return true }
        return a.commonPrefix(with: b).count >= 5
    }

    /// Служебные слова адресов камер и уведомлений — в том же приведённом
    /// виде, что слова (через fold: «ko‘chalari» → «kuchalari»).
    private static let noise: Set<String> = Set([
        // по-русски
        "улица", "улицы", "проспект", "проспекта", "переулок", "шоссе", "массив", "мкр", "квартал",
        "дом", "район", "района", "область", "области", "город", "пересечение", "перекресток",
        "перекрёсток", "площадь", "напротив", "возле", "рядом", "около", "адрес", "адресу", "место",
        // по-узбекски
        "ko‘chasi", "ko‘chalari", "ko‘chalar", "ko‘chasida", "ko‘chasidan", "ko‘chalarining",
        "prospekti", "massivi", "mavzesi", "mavze", "mahallasi", "daha", "dahasi", "kesishmasi",
        "kesishmasida", "kesishgan", "kesishuvi", "chorraha", "chorrahasi", "chorrahada",
        "tumani", "tuman", "shahri", "shahar", "sh", "viloyati", "viloyat", "yo‘lining", "avtomobil",
        "oldi", "oldida", "qarshisi", "qarshisida", "ro‘parasi", "yonida", "bilan", "uy", "uyi",
        "manzil", "manzili", "hududida", "hududi", "aholi", "punkti", "yashash", "nuqta", "nuqtasi",
        "km", "joy", "joyi", "va",
    ].flatMap { AddressBook.fold($0).split(separator: " ").map(String.init) })
}
