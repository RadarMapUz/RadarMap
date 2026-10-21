//
//  FineTextParser.swift
//  RadarMap
//
//  «Вставить текст» (этап 17.2): разбор СМС или уведомления о штрафе в
//  черновик формы. Настоящих образцов пока нет (👤 владелец пришлёт 5–10 без
//  личных данных — RadarMapTests/FineTexts/README.md), поэтому разбор
//  терпимый, а не под один формат: даты dd.MM.yyyy / dd.MM.yy / «12 октября
//  2026», время HH:mm, суммы с «сум»/«so‘m»/пробелами/запятыми, скорость
//  «км/ч»/«km/soat», номер постановления.
//
//  Три правила:
//  - Поле НИКОГДА не выдумывается. Не нашли — поля нет, форма останется
//    пустой в этом месте. Нашли, но без подписи в тексте («78 км/ч» без
//    «скорость», две суммы без «к оплате») — поле помечено «проверьте».
//  - Текст, не похожий на штраф (СМС банка, чек), — честное «не распознали»,
//    даже если в нём есть дата и сумма: покупка в магазине — не штраф.
//  - Госномер распознаётся только чтобы его ВЫРЕЗАТЬ: его цифры не должны
//    стать суммой или номером постановления, а сам номер в черновик не идёт.
//
//  Чистая логика — FineTextParserTests (образцы — RadarMapTests/FineTexts).
//

import Foundation

nonisolated enum FineTextParser {

    static func parse(_ text: String) -> FineDraft {
        var draft = FineDraft()
        // Неразрывные пробелы — в обычные: длина в UTF-16 та же, позиции живы.
        var source = text
        for space in ["\u{00A0}", "\u{202F}", "\u{2009}", "\u{2007}"] {
            source = source.replacingOccurrences(of: space, with: " ")
        }
        guard matches(fineSignal, in: source) else { return draft }
        draft.looksLikeFine = true

        let masked = NSMutableString(string: source)
        // Госномер — вырезать до всего остального.
        for range in ranges(of: plates, in: masked) { mask(range, in: masked) }

        parseDates(masked, into: &draft)
        parseSpeeds(masked, into: &draft)
        parseAmounts(masked, into: &draft)
        parseResolution(masked, into: &draft)
        draft.place = FineTextPlace.find(in: masked as String)
        return draft
    }

    // MARK: - Даты и время

    private struct FoundDate {
        let range: NSRange
        let day: FineDraft.Day
        let role: Role
        var clock: FineDraft.Clock?
        enum Role { case due, issued, violation, plain }
    }

    private static func parseDates(_ text: NSMutableString, into draft: inout FineDraft) {
        var dates: [FoundDate] = []
        for (pattern, order) in [(numericDate, [1, 2, 3]), (isoDate, [3, 2, 1])] {
            for match in pattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                let numbers = order.map { Int(text.substring(with: match.range(at: $0))) ?? 0 }
                guard let day = validDay(day: numbers[0], month: numbers[1], year: numbers[2]) else { continue }
                dates.append(FoundDate(range: match.range, day: day, role: role(of: match.range, in: text)))
            }
        }
        for match in wordDate.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            let monthWord = text.substring(with: match.range(at: 2)).lowercased()
            guard let month = monthStems.firstIndex(where: { stems in stems.contains { monthWord.hasPrefix($0) } }),
                  let day = validDay(day: Int(text.substring(with: match.range(at: 1))) ?? 0, month: month + 1,
                                     year: Int(text.substring(with: match.range(at: 3))) ?? 0)
            else { continue }
            dates.append(FoundDate(range: match.range, day: day, role: role(of: match.range, in: text)))
        }
        dates.sort { $0.range.location < $1.range.location }
        for found in dates { mask(found.range, in: text) }

        // Время — к дате, рядом с которой стоит (до 25 знаков в любую сторону).
        var clocks: [(range: NSRange, clock: FineDraft.Clock, attached: Bool)] = []
        for match in clockPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            let clock = FineDraft.Clock(hour: Int(text.substring(with: match.range(at: 1))) ?? 0,
                                        minute: Int(text.substring(with: match.range(at: 2))) ?? 0)
            var attached = false
            if let index = dates.indices.min(by: { gap(dates[$0].range, match.range) < gap(dates[$1].range, match.range) }),
               gap(dates[index].range, match.range) <= 25, dates[index].clock == nil {
                dates[index].clock = clock
                attached = true
            }
            clocks.append((match.range, clock, attached))
            mask(match.range, in: text)
        }

        // Дата нарушения: подписанная; иначе неподписанная с временем рядом.
        // Прочие случаи — первая из найденных, но «проверьте».
        let labeled = dates.filter { $0.role == .violation }
        let plain = dates.filter { $0.role == .plain }
        var chosen: FoundDate?
        var sure = false
        if let first = labeled.first {
            chosen = first
            sure = labeled.count == 1
        } else if !plain.isEmpty {
            let timed = plain.filter { $0.clock != nil }
            if timed.count == 1 {
                chosen = timed[0]
                sure = true
            } else {
                // Без подписи и без времени рядом это может быть и дата
                // постановления — «проверьте».
                chosen = timed.first ?? plain.first
                sure = false
            }
        }
        if let chosen {
            draft.date = .init(value: chosen.day, sure: sure)
            if let clock = chosen.clock {
                draft.time = .init(value: clock, sure: sure)
            }
        }
        // Время без даты рядом: единственное в тексте — «проверьте».
        if draft.time == nil {
            let loose = clocks.filter { !$0.attached }
            if loose.count == 1, chosen != nil || dates.isEmpty {
                draft.time = .init(value: loose[0].clock, sure: false)
            }
        }
        let issued = dates.filter { $0.role == .issued }
        if let first = issued.first { draft.issued = .init(value: first.day, sure: issued.count == 1) }
        let due = dates.filter { $0.role == .due }
        if let first = due.first { draft.due = .init(value: first.day, sure: due.count == 1) }
    }

    private static func validDay(day: Int, month: Int, year: Int) -> FineDraft.Day? {
        let fullYear = year < 100 ? 2000 + year : year
        guard (2000...2099).contains(fullYear), (1...12).contains(month), day >= 1 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        guard let first = calendar.date(from: DateComponents(year: fullYear, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: first), days.contains(day)
        else { return nil }
        return FineDraft.Day(year: fullYear, month: month, day: day)
    }

    /// Что это за дата — по словам перед ней (и «gacha» после).
    private static func role(of range: NSRange, in text: NSString) -> FoundDate.Role {
        let before = context(before: range, in: text, length: 40)
        let after = context(after: range, in: text, length: 16)
        if matches(dueBefore, in: before) || matches(dueAfter, in: after) { return .due }
        if matches(issuedBefore, in: before) { return .issued }
        if matches(violationBefore, in: before) { return .violation }
        return .plain
    }

    // MARK: - Скорость

    private static func parseSpeeds(_ text: NSMutableString, into draft: inout FineDraft) {
        var speeds: [Int] = [], limits: [Int] = [], excess: [Int] = [], plain: [Int] = []
        for match in speedPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            guard let value = Int(text.substring(with: match.range(at: 1))), (5...300).contains(value) else { continue }
            let before = context(before: match.range, in: text, length: 30)
            let after = context(after: match.range, in: text, length: 12)
            if matches(excessBefore, in: before) || matches(excessAfter, in: after) {
                excess.append(value)
            } else if matches(limitBefore, in: before) {
                limits.append(value)
            } else if matches(speedBefore, in: before) {
                speeds.append(value)
            } else {
                plain.append(value)
            }
            mask(match.range, in: text)
        }
        if let first = speeds.first {
            draft.speedKmh = .init(value: first, sure: speeds.count == 1)
        }
        if let first = limits.first {
            draft.limitKmh = .init(value: first, sure: limits.count == 1)
        }
        // Неподписанные: одна — скорость «проверьте»; две разные без подписей
        // — большая похожа на скорость, меньшая на лимит, обе «проверьте».
        if draft.speedKmh == nil, plain.count == 1, draft.limitKmh?.value != plain[0] {
            draft.speedKmh = .init(value: plain[0], sure: false)
        } else if draft.speedKmh == nil, draft.limitKmh == nil, plain.count == 2,
                  let high = plain.max(), let low = plain.min(), high > low {
            draft.speedKmh = .init(value: high, sure: false)
            draft.limitKmh = .init(value: low, sure: false)
        }
        // «Превышение на 22 км/ч при ограничении 60» — скорость складывается,
        // но это вывод, а не прочитанное: «проверьте».
        if draft.speedKmh == nil, excess.count == 1, let limit = draft.limitKmh {
            draft.speedKmh = .init(value: limit.value + excess[0], sure: false)
        }
    }

    // MARK: - Сумма

    private static func parseAmounts(_ text: NSMutableString, into draft: inout FineDraft) {
        var labeled: [Double] = [], plain: [Double] = []
        var estimated: Double?
        func classify(_ value: Double, _ range: NSRange) {
            guard (10_000...200_000_000).contains(value) else { return }
            let before = context(before: range, in: text, length: 30)
            if matches(discountBefore, in: before) { return }
            if matches(amountLabel, in: before) { labeled.append(value) } else { plain.append(value) }
        }
        for match in moneyPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            if let value = number(text.substring(with: match.range(at: 1))) { classify(value, match.range) }
            mask(match.range, in: text)
        }
        // Подписанная сумма без валюты: «Сумма штрафа: 340000».
        for match in labeledNumber.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            if let value = number(text.substring(with: match.range(at: 1))),
               (10_000...200_000_000).contains(value) {
                labeled.append(value)
                mask(match.range(at: 1), in: text)
            }
        }
        // «5 БРВ» — по нынешней БРВ: на дату постановления она могла быть
        // другой, поэтому только «проверьте».
        for match in brvPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            if let count = Int(text.substring(with: match.range(at: 1))), (1...50).contains(count) {
                estimated = Double(count) * FineSchedule.brv
                mask(match.range, in: text)
            }
        }
        if let first = labeled.first {
            draft.amount = .init(value: first, sure: Set(labeled).count == 1)
        } else if let high = plain.max() {
            draft.amount = .init(value: high, sure: Set(plain).count == 1)
        } else if let estimated {
            draft.amount = .init(value: estimated, sure: false)
        }
    }

    private static func number(_ raw: String) -> Double? {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty, digits.count <= 10 else { return nil }
        return Double(digits)
    }

    // MARK: - Номер постановления

    private static func parseResolution(_ text: NSMutableString, into draft: inout FineDraft) {
        for (pattern, sure) in [(resolutionLabeled, true), (resolutionNumbered, false)] {
            for match in pattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                let raw = text.substring(with: match.range(at: 1))
                let value = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -/."))
                guard value.filter(\.isNumber).count >= 5 else { continue }
                draft.resolution = .init(value: value, sure: sure)
                mask(match.range(at: 1), in: text)
                return
            }
        }
    }

    // MARK: - Помощники

    static func matches(_ pattern: NSRegularExpression, in text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func ranges(of pattern: NSRegularExpression, in text: NSString) -> [NSRange] {
        pattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map(\.range)
    }

    /// Заменить найденное пробелами той же длины: позиции остального живы,
    /// а цифры уже разобранного не станут суммой или номером.
    static func mask(_ range: NSRange, in text: NSMutableString) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        text.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
    }

    /// Текст перед найденным — до начала строки или предложения.
    private static func context(before range: NSRange, in text: NSString, length: Int) -> String {
        let start = max(0, range.location - length)
        var chunk = text.substring(with: NSRange(location: start, length: range.location - start))
        for separator in ["\n", ";", "!", ". "] {
            if let cut = chunk.range(of: separator, options: .backwards) {
                chunk = String(chunk[cut.upperBound...])
            }
        }
        return chunk.lowercased()
    }

    private static func context(after range: NSRange, in text: NSString, length: Int) -> String {
        let start = range.location + range.length
        let available = min(length, text.length - start)
        guard available > 0 else { return "" }
        return text.substring(with: NSRange(location: start, length: available)).lowercased()
    }

    private static func gap(_ a: NSRange, _ b: NSRange) -> Int {
        if b.location >= a.location + a.length { return b.location - (a.location + a.length) }
        if a.location >= b.location + b.length { return a.location - (b.location + b.length) }
        return 0
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Шаблоны — константы этого файла: ошибку в одном из них ловит первый
        // же тест разбора (FineTextParserTests), до сборки в TestFlight.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // MARK: - Шаблоны

    /// Признак штрафа. Без него текст — не уведомление о штрафе.
    private static let fineSignal = regex(
        "штраф|jarima|жарима|постановлени|qaror|қарор|нарушени|qoidabuzarlik|қоидабузарлик|"
        + "huquqbuzarlik|ҳуқуқбузарлик|пдд|yhxb|йҳхб|гибдд|ГУБДД|превышени|скорост|tezlik|тезлик|"
        + "радар|radar|фото.?видео|foto.?video|бхм|bhm|брв|km/soat|км/соат|км/ч|km/h")

    private static let apostrophe = "[ʻʼ'‘’`´]?"

    /// Госномер: «01 A 123 BC» и «01 123 ABC» (латиница и кириллица-двойник).
    /// Буквы — только заглавные (без флага регистра): иначе «50 000 сум»
    /// читалось бы номером юрлица «50 000 СУМ».
    private static let plates = regex(
        "(?-i)(?<![\\p{L}\\d])\\d{2}\\s?(?:[A-ZА-Я]\\s?\\d{3}\\s?[A-ZА-Я]{2}"
        + "|\\d{3}\\s?(?!СУМ|СЎМ|SUM|UZS)[A-ZА-Я]{3})(?![\\p{L}\\d])")

    private static let numericDate = regex("(?<![\\d.])(\\d{1,2})[./-](\\d{1,2})[./-](\\d{4}|\\d{2})(?![\\d])")
    private static let isoDate = regex("(?<![\\d.])(\\d{4})-(\\d{2})-(\\d{2})(?![\\d])")
    private static let wordDate = regex(
        "(?<!\\d)(\\d{1,2})\\s*[-–]?\\s*([\\p{L}]{3,10})\\s+(\\d{4})(?!\\d)")
    /// Корни месяцев по-русски, по-узбекски латиницей и кириллицей.
    private static let monthStems: [[String]] = [
        ["январ", "yanvar"], ["феврал", "fevral"], ["март", "mart"], ["апрел", "aprel"],
        ["мая", "май", "may"], ["июн", "iyun"], ["июл", "iyul"], ["август", "avgust"],
        ["сентябр", "sentabr", "sentyabr"], ["октябр", "oktabr", "oktyabr"],
        ["ноябр", "noyabr"], ["декабр", "dekabr"],
    ]
    private static let clockPattern = regex("(?<![\\d:])([01]?\\d|2[0-3])[:]([0-5]\\d)(?::[0-5]\\d)?(?![\\d:])")

    private static let dueBefore = regex(
        "срок\\w*\\s+(?:уплат|оплат)|(?:оплат|уплат)\\w*(?:\\s+\\S+)?\\s+до\\s*:?\\s*$|\\bдо\\s*:?\\s*$|"
        + "muddat|муддат")
    private static let dueAfter = regex("^\\s*(?:й\\.|y\\.|yil\\w*|йил\\w*)?\\s*(?:gacha|гача)")
    private static let issuedBefore = regex(
        "(?:№|n[º°o]?\\.|постановлени\\w*|qaror\\w*|қарор\\w*)[^\\n]{0,30}\\s(?:от|dan|дан)\\s*$|"
        + "дата\\s+постановлени|вынесен|qaror\\s+sanasi|қарор\\s+санаси")
    private static let violationBefore = regex(
        "нарушени|зафиксир|sodir|содир|qayd|қайд|aniqlan|аниқлан|время|vaqt|вақт")

    private static let speedPattern = regex(
        "(?<![\\d.,])(\\d{2,3})\\s*(?:км\\s*/\\s*ч(?:ас)?|км\\s*/\\s*соат|km\\s*/\\s*h|km\\s*/\\s*soat|kmh)(?![\\p{L}])")
    private static let limitBefore = regex(
        "огранич|разреш|допуст|ruxsat|рухсат|cheklov|чеклов|лимит|limit|belgilangan|белгиланган")
    private static let excessBefore = regex("(?:превышени|превысил)[^\\d]{0,30}\\sна\\s*$")
    private static let excessAfter = regex("^\\s*(?:ga|га)?\\s*(?:ortiq|ортиқ|oshirgan|оширган)")
    private static let speedBefore = regex(
        "скорост|tezlik|тезлик|двигал|harakatlan|ҳаракатлан|фактическ|oshirgan|оширган")

    private static let moneyPattern = regex(
        "(?<![\\d.,])(\\d{1,3}(?:[ .,'’]\\d{3})+|\\d{4,10})(?:[.,]\\d{1,2})?\\s*"
        + "(?:сум|сўм|so\(apostrophe)m|sum(?!m)|uzs)(?![\\p{L}])")
    private static let labeledNumber = regex(
        "(?:сумм\\w*(?:\\s+штраф\\w*)?|jarima\\s+miqdori|жарима\\s+миқдори|к\\s+оплате|"
        + "to\(apostrophe)lov\\s+summasi|тўлов\\s+суммаси)\\s*[:\\-—]?\\s*(\\d{1,3}(?:[ .,'’]\\d{3})+|\\d{4,10})(?![\\d])")
    private static let amountLabel = regex(
        "сумм|штраф|jarima|жарима|miqdor|миқдор|к\\s+оплате|итого|to\(apostrophe)lov|тўлов")
    private static let discountBefore = regex("скидк|льгот|chegirma|чегирма|%")
    private static let brvPattern = regex("(?<![\\d])(\\d{1,2})\\s*(?:брв|bhm|бхм)(?![\\p{L}])")

    private static let resolutionLabeled = regex(
        "(?:постановлени\\w*|qaror\\w*|қарор\\w*|протокол\\w*|bayonnoma\\w*|баённома\\w*|уин|uin)"
        + "\\s*(?:серии\\s*)?(?:№|n[º°o]?\\.?|номер|raqami|рақами|#)?\\s*[:\\-]?\\s*"
        + "((?-i:[A-ZА-ЯЁ]{1,4})?[\\s-]?\\d[\\d\\s-]{3,24}\\d)(?![\\d])")
    private static let resolutionNumbered = regex(
        "(?:№|(?-i:N)[º°o]?\\.)\\s*([A-ZА-ЯЁ0-9][A-ZА-ЯЁ0-9\\-/]{4,30})")
}
