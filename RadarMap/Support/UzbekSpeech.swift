//
//  UzbekSpeech.swift
//  RadarMap
//
//  Узбекская речь на телефоне, где узбекского голоса нет.
//
//  В iOS 180 системных голосов и среди них НЕТ узбекского. Нет и казахского,
//  азербайджанского, киргизского — из тюркских есть только турецкий (tr-TR
//  Yelda). При этом интерфейс переведён полностью, и все фразы оповещений в
//  каталоге по-узбекски есть. То есть до сих пор происходило худшее из
//  возможного: русский синтезатор читал латиницу — за рулём это шум, а не речь.
//
//  Решение — читать узбекский текст ТУРЕЦКИМ голосом, предварительно переписав
//  орфографию под турецкую фонетику. Языки родственные, и после подстановки
//  (sh→ş, ch→ç, oʻ→ö, x→h, q→k, j→c) турецкий синтезатор произносит узбекские
//  слова разборчиво. Это не идеал — идеал это записанный диктор, — но разница
//  между «понятно» и «непонятно», а не между «хорошо» и «отлично».
//
//  Числа разворачиваем в слова САМИ. Иначе «300» турецкий голос прочтёт как
//  «üç yüz» по-турецки; узбекское «uch yuz» ему созвучно, но остальные
//  числительные расходятся сильнее, а «камера, 300 метров» — это ровно та
//  часть фразы, ради которой всё и говорится.
//
//  Чистая логика, покрыта UzbekSpeechTests.
//

import AVFoundation
import Foundation

nonisolated enum UzbekSpeech {

    /// Язык голоса для узбекского текста, когда своего в системе нет.
    static let voiceLanguage = "tr-TR"

    /// Настоящий узбекский голос, если он в системе есть.
    ///
    /// Проверено перечислением на iOS 26.2: 68 голосов, 48 языков, из тюркских
    /// ровно один — tr-TR. Узбекского нет ни встроенного, ни догружаемого из
    /// каталога Apple. Но появиться он может двумя путями: Apple добавит язык в
    /// свой список, либо пользователь поставит стороннее приложение с
    /// расширением синтеза речи (iOS 17+ регистрирует такие голоса системно и
    /// отдаёт их всем приложениям). Оба случая должны включаться сами: жёстко
    /// прибитый турецкий означал бы, что настоящий узбекский голос на телефоне
    /// есть, а мы продолжаем говорить чужим.
    ///
    /// Ищем по префиксу, а не по «uz-UZ»: у голоса может быть регион (uz-Latn,
    /// uz-Cyrl-UZ), и точное совпадение его не найдёт.
    static var nativeVoice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .first { $0.language.lowercased().hasPrefix("uz") }
    }

    /// Подготовить узбекскую фразу к произнесению турецким голосом.
    static func spoken(_ text: String) -> String {
        transliterate(spellingOutNumbers(text))
    }

    // MARK: - Числительные

    private static let ones = ["nol", "bir", "ikki", "uch", "to‘rt", "besh",
                               "olti", "yetti", "sakkiz", "to‘qqiz"]
    private static let tens = ["", "o‘n", "yigirma", "o‘ttiz", "qirq", "ellik",
                               "oltmish", "yetmish", "sakson", "to‘qson"]

    /// Число словами по-узбекски (0…9999 — больше в оповещениях не бывает:
    /// максимальный радиус километр, максимальная скорость трёхзначная).
    static func numeral(_ value: Int) -> String {
        if value < 0 { return String(value) }
        if value >= 10000 { return String(value) }
        var parts: [String] = []
        var rest = value

        if rest >= 1000 {
            let thousands = rest / 1000
            // «ming», а не «bir ming»: тысяча по-узбекски просто «ming».
            parts.append(thousands == 1 ? "ming" : "\(ones[thousands]) ming")
            rest %= 1000
        }
        if rest >= 100 {
            let hundreds = rest / 100
            parts.append(hundreds == 1 ? "yuz" : "\(ones[hundreds]) yuz")
            rest %= 100
        }
        if rest >= 10 {
            parts.append(tens[rest / 10])
            rest %= 10
        }
        if rest > 0 || parts.isEmpty {
            parts.append(ones[rest])
        }
        return parts.joined(separator: " ")
    }

    /// Заменить в тексте группы цифр на слова.
    static func spellingOutNumbers(_ text: String) -> String {
        var result = ""
        var digits = ""
        for character in text {
            if character.isNumber {
                digits.append(character)
            } else {
                if !digits.isEmpty {
                    result += Int(digits).map(numeral) ?? digits
                    digits = ""
                }
                result.append(character)
            }
        }
        if !digits.isEmpty {
            result += Int(digits).map(numeral) ?? digits
        }
        return result
    }

    // MARK: - Орфография под турецкий голос

    /// Пары «узбекское написание → как это прочтёт турецкий синтезатор».
    /// Порядок значим: диграфы разбираются раньше одиночных букв, иначе
    /// «sh» превратится в «s»+«h» и прозвучит как два звука.
    private static let replacements: [(String, String)] = [
        // Диграфы и модификаторы — первыми.
        ("o‘", "ö"), ("o'", "ö"), ("oʻ", "ö"), ("oʼ", "ö"),
        ("g‘", "g"), ("g'", "g"), ("gʻ", "g"), ("gʼ", "g"),
        ("sh", "ş"), ("ch", "ç"), ("ng", "ng"),
        ("Sh", "Ş"), ("Ch", "Ç"),
        // Одиночные буквы, которых в турецком нет или которые читаются иначе.
        ("x", "h"), ("X", "H"),
        ("q", "k"), ("Q", "K"),
        ("j", "c"), ("J", "C"),
        // Твёрдый знак узбекской латиницы не произносится вовсе.
        ("ʼ", ""), ("’", ""),
    ]

    static func transliterate(_ text: String) -> String {
        var result = text
        for (from, to) in replacements {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }
}
