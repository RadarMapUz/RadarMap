//
//  StreetName.swift
//  RadarMap
//
//  Название улицы в манёвре — на языке приложения.
//
//  OSRM отдаёт `name` из OSM как есть, а в Ташкенте это узбекская латиница:
//  «Beruniy shoh ko'chasi». В русской версии баннер манёвра читался
//  «держитесь правее на Beruniy shoh ko'chasi», а русский синтезатор
//  произносил латиницу по буквам или по-английски — за рулём это шум, а не
//  подсказка.
//
//  Правило узкое и проверяемое: переписываем ТОЛЬКО имя, у которого узнан
//  узбекский тип («ko'chasi», «prospekti», «berk ko'chasi», …). Тип становится
//  русским словом впереди, как пишут в городе («улица Беруни»), имя — кириллицей
//  по русскому произношению (ў → у, қ → к, конечное «-iy» → «-и»: Navoiy →
//  Навои). Имя без узнанного типа не трогаем вовсе: «Tashkent City» или уже
//  русское «улица Фурката» переписывать не за что, а угадывать опаснее, чем
//  оставить. В узбекской версии имя не меняется никогда.
//
//  «shoh ko'chasi» (главная улица) — тоже «улица»: дословное «шох улица» по-
//  русски не говорят, а «проспект» был бы выдумкой — в городе одна и та же
//  shoh ko'chasi зовётся то улицей, то проспектом.
//
//  Чистая логика, покрыта StreetNameTests.
//

import Foundation

nonisolated enum StreetName {

    /// Падеж, в котором имя встаёт во фразу. Манёвр говорит «на %@» —
    /// «поверните налево на улицу Беруни», поэтому фраза просит винительный.
    enum GrammaticalCase: Sendable {
        case nominative
        case accusative
    }

    /// Имя улицы для показа и голоса. `language` — код языка приложения
    /// (`AppLanguage.mapCode`: «ru» / «uz»).
    static func display(_ raw: String, language: String,
                        grammaticalCase: GrammaticalCase = .nominative) -> String {
        guard language != "uz" else { return raw }
        let normalized = normalizeApostrophes(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = normalized.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard words.count >= 2 else { return raw }

        for kind in kinds {
            for form in kind.forms {
                guard let match = match(words: words, form: form) else { continue }
                let name = russianName(match.head.joined(separator: " "))
                var typeWord = grammaticalCase == .accusative ? kind.accusative : kind.nominative
                if let ordinal = match.ordinal {
                    let ending = grammaticalCase == .accusative
                        ? kind.gender.accusativeEnding : kind.gender.nominativeEnding
                    typeWord = "\(ordinal)-\(ending) \(typeWord)"
                }
                return "\(typeWord) \(name)"
            }
        }
        return raw
    }

    // MARK: - Типы улиц

    enum Gender: Sendable {
        case masculine, feminine, neuter

        var nominativeEnding: String {
            switch self {
            case .masculine: return "й"
            case .feminine:  return "я"
            case .neuter:    return "е"
            }
        }

        var accusativeEnding: String {
            switch self {
            case .masculine: return "й"
            case .feminine:  return "ю"
            case .neuter:    return "е"
            }
        }
    }

    struct Kind: Sendable {
        /// Написания типа в нижнем регистре, слова через пробел. Латиница и
        /// узбекская кириллица — в OSM встречаются обе.
        let forms: [String]
        let nominative: String
        let accusative: String
        let gender: Gender
    }

    /// Порядок значим: длинные типы раньше коротких, иначе «berk ko'chasi»
    /// узнаётся как «ko'chasi», и тупик становится улицей «Руставели берк».
    static let kinds: [Kind] = [
        Kind(forms: ["halqa yo'li", "ҳалқа йўли", "халқа йўли"],
             nominative: "кольцевая дорога", accusative: "кольцевую дорогу", gender: .feminine),
        Kind(forms: ["shoh ko'chasi", "шоҳ кўчаси", "шох кўчаси"],
             nominative: "улица", accusative: "улицу", gender: .feminine),
        Kind(forms: ["berk ko'chasi", "berk ko'cha", "берк кўчаси", "берк кўча"],
             nominative: "тупик", accusative: "тупик", gender: .masculine),
        Kind(forms: ["tor ko'chasi", "tor ko'cha", "тор кўчаси", "тор кўча"],
             nominative: "переулок", accusative: "переулок", gender: .masculine),
        Kind(forms: ["ko'chasi", "ko'cha", "кўчаси", "кўча"],
             nominative: "улица", accusative: "улицу", gender: .feminine),
        Kind(forms: ["prospekti", "проспекти"],
             nominative: "проспект", accusative: "проспект", gender: .masculine),
        Kind(forms: ["maydoni", "майдони"],
             nominative: "площадь", accusative: "площадь", gender: .feminine),
        Kind(forms: ["ko'prigi", "кўприги"],
             nominative: "мост", accusative: "мост", gender: .masculine),
        Kind(forms: ["shossesi", "шоссеси"],
             nominative: "шоссе", accusative: "шоссе", gender: .neuter),
        Kind(forms: ["xiyoboni", "хиёбони"],
             nominative: "аллея", accusative: "аллею", gender: .feminine),
        Kind(forms: ["massivi", "массиви"],
             nominative: "массив", accusative: "массив", gender: .masculine),
        Kind(forms: ["yo'li", "йўли"],
             nominative: "дорога", accusative: "дорогу", gender: .feminine),
    ]

    private struct Match {
        let head: [String]
        let ordinal: String?
    }

    /// Совпадает ли хвост имени с типом. Номер может прилипать к типу через
    /// дефис («Shota Rustaveli 1-berk ko'chasi») — тогда он уходит в
    /// порядковое «1-й тупик».
    private static func match(words: [String], form: String) -> Match? {
        let typeWords = form.split(separator: " ").map(String.init)
        guard words.count > typeWords.count else { return nil }
        var tail = Array(words.suffix(typeWords.count)).map { $0.lowercased() }
        var ordinal: String?
        if let dash = tail[0].firstIndex(of: "-") {
            let number = String(tail[0][..<dash])
            if !number.isEmpty, number.allSatisfy(\.isNumber) {
                ordinal = number
                tail[0] = String(tail[0][tail[0].index(after: dash)...])
            }
        }
        guard tail == typeWords else { return nil }
        let head = Array(words.dropLast(typeWords.count))
        guard !head.isEmpty else { return nil }
        return Match(head: head, ordinal: ordinal)
    }

    // MARK: - Имя по-русски

    /// Все виды узбекского апострофа (ʻ ʼ ‘ ’ `) — к одному «'»: OSM пишет
    /// кто как привык, а сравнение типов должно видеть одну букву.
    static func normalizeApostrophes(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\u{02BB}", "\u{02BC}", "\u{2018}", "\u{2019}", "`", "\u{00B4}":
                result.append("'")
            default:
                result.append(character)
            }
        }
        return result
    }

    /// Имя кириллицей по русскому произношению.
    static func russianName(_ name: String) -> String {
        let hasLatin = name.unicodeScalars.contains {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0)
        }
        let words = name.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return words.map { hasLatin ? latinWord($0) : cyrillicWord($0) }
            .joined(separator: " ")
    }

    /// Узбекская кириллица → русская: особых букв русский читатель (и голос)
    /// не знает.
    private static func cyrillicWord(_ word: String) -> String {
        var result = ""
        for character in word {
            switch character {
            case "ў": result.append("у")
            case "Ў": result.append("У")
            case "қ": result.append("к")
            case "Қ": result.append("К")
            case "ғ": result.append("г")
            case "Ғ": result.append("Г")
            case "ҳ": result.append("х")
            case "Ҳ": result.append("Х")
            case "ъ", "'": break
            default: result.append(character)
            }
        }
        if result.count > 2, result.lowercased().hasSuffix("ий") {
            result.removeLast()
        }
        return result
    }

    private static let single: [Character: String] = [
        "a": "а", "b": "б", "d": "д", "e": "е", "f": "ф", "g": "г", "h": "х",
        "i": "и", "j": "ж", "k": "к", "l": "л", "m": "м", "n": "н", "o": "о",
        "p": "п", "q": "к", "r": "р", "s": "с", "t": "т", "u": "у", "v": "в",
        "x": "х", "y": "й", "z": "з", "c": "ц", "w": "в",
    ]

    /// Узбекская латиница → кириллица. Диграфы (sh, ch, o', g', ya, yo, yu,
    /// ye) — раньше одиночных букв; «yo'» — это «йў», по-русски «ю»
    /// (Yo'ldosh → Юлдаш), а не «ё» с лишним апострофом.
    private static func latinWord(_ word: String) -> String {
        var letters = Array(word)
        // Конечное «-iy» по-русски читается «-и»: Navoiy → Навои, Beruniy → Беруни.
        if letters.count > 2, letters.suffix(2).map({ Character($0.lowercased()) }) == ["i", "y"] {
            letters.removeLast()
        }
        var result = ""
        var index = 0
        func lower(_ offset: Int) -> Character? {
            let position = index + offset
            guard position < letters.count else { return nil }
            return Character(letters[position].lowercased())
        }
        func emit(_ cyrillic: String, upper: Bool) {
            result += upper ? cyrillic.prefix(1).uppercased() + cyrillic.dropFirst() : cyrillic
        }
        while index < letters.count {
            let character = letters[index]
            let upper = character.isUppercase
            guard let current = lower(0) else { break }
            let next = lower(1)
            let afterNext = lower(2)
            let atWordStart = index == 0 || !(letters[index - 1].isLetter)
            switch current {
            case "o" where next == "'":
                emit("у", upper: upper); index += 2
            case "g" where next == "'":
                emit("г", upper: upper); index += 2
            case "s" where next == "h":
                emit("ш", upper: upper); index += 2
            case "c" where next == "h":
                emit("ч", upper: upper); index += 2
            case "y" where next == "o" && afterNext == "'":
                emit("ю", upper: upper); index += 3   // yo'l → юл (Yo'ldosh → Юлдаш)
            case "y" where next == "o":
                emit("ё", upper: upper); index += 2
            case "y" where next == "a":
                emit("я", upper: upper); index += 2
            case "y" where next == "u":
                emit("ю", upper: upper); index += 2
            case "y" where next == "e":
                emit("е", upper: upper); index += 2
            case "e" where atWordStart:
                emit("э", upper: upper); index += 1
            case "'":
                index += 1   // тутуқ белгиси: по-русски не пишется
            default:
                if let mapped = single[current] {
                    emit(mapped, upper: upper)
                } else {
                    result.append(character)   // цифры, дефис, точка — как есть
                }
                index += 1
            }
        }
        return result
    }
}
