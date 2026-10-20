//
//  AddressText.swift
//  RadarMap
//
//  Адреса камер из реестра — одним алфавитом (план 19.10, 11.6). Реестр
//  набирают с переключённой раскладкой: в 665 адресах v12 кириллические
//  «а», «е», «о» стоят внутри латинских слов («Dаhаsi», «Kеsishgan»). Глаз
//  разницы не видит, а синтез речи читает такое слово по-другому, и
//  совпадение строк (история, «зона риска») ломается. Шесть адресов набраны
//  целиком кириллицей, хотя база латинская. Пайплайн базы теперь чистит
//  это сам (server/update_cameras.py, smart); здесь — то же для базы, уже
//  лежащей на телефонах.
//
//  Чистая логика — AddressTextTests.
//

import Foundation

nonisolated enum AddressText {
    /// Буквы-двойники: кириллица → латиница того же вида.
    private static let homoglyphs: [Character: Character] = [
        "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C",
        "Т": "T", "Х": "X", "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x",
        "к": "k",
    ]

    /// Узбекская кириллица → латиница (алфавит 1995 года).
    private static let uzLatin: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo", "ж": "j", "з": "z",
        "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "x", "ц": "s", "ч": "ch", "ш": "sh", "ъ": "ʼ",
        "ь": "", "э": "e", "ю": "yu", "я": "ya", "ў": "o‘", "қ": "q", "ғ": "g‘", "ҳ": "h",
    ]
    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "а", "е", "ё", "и", "о", "у", "э", "ю", "я", "ў"]

    static func normalized(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isCyrillic) else { return text }
        guard text.unicodeScalars.contains(where: isLatin) else { return transliterated(text) }
        return text.split(separator: " ", omittingEmptySubsequences: false)
            .map { folded(String($0)) }
            .joined(separator: " ")
    }

    /// Слово с латиницей и кириллицей — двойники в латиницу, прочие
    /// кириллические буквы (опечатки реестра: «Kфo‘chasi», «Sаnъаt»,
    /// «aulы») — по таблице алфавита; чистое слово — как есть.
    private static func folded(_ word: String) -> String {
        guard word.unicodeScalars.contains(where: isCyrillic),
              word.unicodeScalars.contains(where: isLatin) else { return word }
        return word.map { character -> String in
            if let latin = homoglyphs[character] { return String(latin) }
            guard character.unicodeScalars.contains(where: isCyrillic) else { return String(character) }
            let lower = Character(character.lowercased())
            let latin = lower == "ы" ? "i" : (uzLatin[lower] ?? "")
            return character != lower && !latin.isEmpty ? latin.prefix(1).uppercased() + latin.dropFirst() : latin
        }.joined()
    }

    /// «Е» в начале слова и после гласной — «ye», как в алфавите.
    private static func transliterated(_ text: String) -> String {
        var out = ""
        var previous: Character?
        for character in text {
            let lower = Character(character.lowercased())
            let latin: String
            if lower == "е", previous.map({ !$0.isLetter || vowels.contains(Character($0.lowercased())) }) ?? true {
                latin = "ye"
            } else {
                latin = uzLatin[lower] ?? String(character)
            }
            out += character != lower && !latin.isEmpty ? latin.prefix(1).uppercased() + latin.dropFirst() : latin
            previous = character
        }
        return out
    }

    private static func isCyrillic(_ scalar: Unicode.Scalar) -> Bool {
        (0x0400...0x04FF).contains(scalar.value)
    }

    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }
}
