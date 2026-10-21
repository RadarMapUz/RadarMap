//
//  FineTextPlace.swift
//  RadarMap
//
//  Место нарушения из текста уведомления (часть FineTextParser). Адрес в СМС
//  — это несколько частей через запятую посреди обычных слов: «… 05.10.2026
//  soat 08:12 da Toshkent sh., Chilonzor tumani, Bunyodkor ko‘chasida
//  tezlikni oshirgan …». Берём части, похожие на адрес: имена (с заглавной),
//  номера и служебные слова адреса («ул.», «tumani», «ko‘chasida»); первое
//  обычное слово после адреса («tezlikni», «зафиксировано») его заканчивает.
//
//  Подписанное место («по адресу:», «manzil:») — уверенное; найденное по
//  слову улицы — «проверьте». Ничего не нашли — поля нет.
//

import Foundation

nonisolated enum FineTextPlace {
    /// Текст уже без дат, сумм, скоростей и номеров (их места забиты
    /// пробелами), поэтому в адрес они не попадут.
    static func find(in text: String) -> FineDraft.Field<String>? {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        if let label = labelPattern.firstMatch(in: text, range: all) {
            let start = label.range.location + label.range.length
            let line = lineRange(containing: start, in: ns)
            let span = ns.substring(with: NSRange(location: start, length: line.upperBound - start))
            var chosen: [String] = []
            for part in parts(of: span) {
                let clean = cleaned(part)
                // Адрес уже начат, а часть открывается обычным словом — дальше
                // не адрес («…, зафиксировано превышение, Постановление…»).
                if !chosen.isEmpty, clean.leadingSkipped || clean.tokens.isEmpty { break }
                if !clean.tokens.isEmpty { chosen.append(clean.text) }
                if clean.stopped { break }
            }
            return joined(chosen).map { FineDraft.Field(value: $0, sure: true) }
        }
        guard let marker = streetPattern.firstMatch(in: text, range: all) else { return nil }
        let line = lineRange(containing: marker.range.location, in: ns)
        let lineText = ns.substring(with: NSRange(location: line.lowerBound, length: line.upperBound - line.lowerBound))
        let pieces = parts(of: lineText)
        // Часть со словом улицы — по смещению внутри строки.
        let offset = marker.range.location - line.lowerBound
        var position = 0
        var index = 0
        for (i, piece) in pieces.enumerated() {
            let end = position + (piece as NSString).length
            if offset < end { index = i; break }
            position = end + 1   // запятая
        }
        var chosen = [cleaned(pieces[index]).text]
        // Назад — пока части называют город, район, область.
        var back = index - 1
        while back >= 0, cleaned(pieces[back]).tokens.contains(where: { areaMarkers.contains(normalizedToken($0)) }) {
            chosen.insert(cleaned(pieces[back]).text, at: 0)
            back -= 1
        }
        // Вперёд — улица после района («…, Chilonzor tumani, Bunyodkor
        // ko‘chasida …») и номер дома отдельной частью («…, 108»), пока адрес
        // не закончился обычным словом.
        var current = cleaned(pieces[index])
        var forward = index + 1
        while !current.stopped, forward < pieces.count {
            let next = cleaned(pieces[forward])
            guard !next.tokens.isEmpty, !next.leadingSkipped else { break }
            let isHouse = next.tokens.first?.first?.isNumber == true && next.tokens.count <= 2
            guard isHouse || next.tokens.contains(where: { markers.contains(normalizedToken($0)) }) else { break }
            chosen.append(next.text)
            current = next
            forward += 1
        }
        return joined(chosen).map { FineDraft.Field(value: $0, sure: false) }
    }

    // MARK: - Части адреса

    private struct Cleaned {
        let tokens: [String]
        /// Встретилось обычное слово после адреса — адрес закончился.
        let stopped: Bool
        /// Часть начиналась с обычных слов, отброшенных до адреса.
        let leadingSkipped: Bool
        var text: String { tokens.joined(separator: " ") }
    }

    private static func parts(of span: String) -> [String] {
        span.components(separatedBy: ",")
    }

    /// Слова части: ведущие обычные слова («da», «соат») отброшены, первое
    /// обычное слово после адресных — конец.
    private static func cleaned(_ part: String) -> Cleaned {
        var kept: [String] = []
        var skipped = false
        for raw in part.split(whereSeparator: \.isWhitespace) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}\"«»:;!?—"))
            guard !token.isEmpty else { continue }
            if isAddressToken(token) {
                kept.append(token)
            } else if !kept.isEmpty {
                return Cleaned(tokens: kept, stopped: true, leadingSkipped: skipped)
            } else {
                skipped = true
            }
        }
        return Cleaned(tokens: kept, stopped: false, leadingSkipped: skipped)
    }

    private static func isAddressToken(_ token: String) -> Bool {
        guard let first = token.first else { return false }
        if first.isUppercase || first.isNumber { return true }
        return markers.contains(normalizedToken(token))
    }

    private static func normalizedToken(_ token: String) -> String {
        String(token.lowercased().map { "ʻʼ‘’`´".contains($0) ? "'" : $0 })
    }

    private static func joined<S: Sequence>(_ parts: S) -> String? where S.Element == String {
        let text = parts.filter { !$0.isEmpty }.joined(separator: ", ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.-—"))
        guard text.contains(where: \.isLetter) else { return nil }
        return String(text.prefix(120))
    }

    private static func lineRange(containing location: Int, in text: NSString) -> Range<Int> {
        let separators = CharacterSet(charactersIn: "\n;!")
        var start = location
        while start > 0, let scalar = UnicodeScalar(text.character(at: start - 1)),
              !separators.contains(scalar) { start -= 1 }
        var end = location
        while end < text.length, let scalar = UnicodeScalar(text.character(at: end)),
              !separators.contains(scalar) { end += 1 }
        return start..<end
    }

    // MARK: - Слова

    /// Служебные слова адреса — строчные, апостроф приведён к «'».
    private static let markers: Set<String> = [
        "г.", "г", "ул.", "ул", "улица", "пр.", "пр-т", "просп.", "проспект", "шоссе", "массив",
        "мкр.", "мкр", "кв.", "дом", "д.", "район", "р-н", "обл.", "область", "пересечение",
        "перекрёсток", "перекресток", "и", "sh.", "sh", "shahri", "shahar", "tumani", "tuman",
        "viloyati", "ko'chasi", "ko'chasida", "ko'chalari", "ko'chalarining", "ko'cha", "shoh",
        "prospekti", "massivi", "mavzesi", "mahallasi", "kesishmasi", "kesishmasida", "kesishgan",
        "chorrahasi", "chorrahada", "yo'li", "yo'lida", "yo'lining", "va", "ш.", "ш", "шаҳри",
        "тумани", "кўчаси", "кўчасида", "кўчалари", "шоҳ", "кесишмаси", "кесишмасида", "массиви",
        "вилояти", "чорраҳаси", "йўли", "ва", "uy", "km", "км",
    ]

    /// Город, район, область — части, которые тянутся к адресу перед улицей.
    private static let areaMarkers: Set<String> = [
        "г.", "г", "город", "sh.", "sh", "shahri", "ш.", "ш", "шаҳри", "tumani", "тумани",
        "район", "р-н", "viloyati", "вилояти", "обл.", "область",
    ]

    private static let labelPattern = pattern(
        "(?:по\\s+адресу|адрес\\w*|место\\s+(?:нарушени|совершени)\\w*|manzil\\w*|манзил\\w*|"
        + "sodir\\s+etilgan\\s+joy\\w*|содир\\s+этилган\\s+жой\\w*)\\s*[:\\-—]?\\s*")

    private static let streetPattern = pattern(
        "ko[ʻʼ'‘’`]?cha|кўча|улиц|(?<![\\p{L}])ул\\.|проспект|prospekt|шоссе|(?<![\\p{L}])shoh(?![\\p{L}])|"
        + "(?<![\\p{L}])шоҳ(?![\\p{L}])|kesishma|кесишма|chorraha|чорраҳа|перекр[её]ст|пересечени|"
        + "massiv|массив|avtomobil\\s+yo|автомобил\\w*\\s+йўл|трасс|tumani|тумани")

    private static func pattern(_ source: String) -> NSRegularExpression {
        // Шаблоны — константы этого файла: ошибку в одном из них ловит первый
        // же тест разбора (FineTextParserTests), до сборки в TestFlight.
        try! NSRegularExpression(pattern: source, options: [.caseInsensitive])
    }
}
