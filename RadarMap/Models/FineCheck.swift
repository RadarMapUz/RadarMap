//
//  FineCheck.swift
//  RadarMap
//
//  «Проверить штрафы» (план 19.10, 12б.8). Узнать, пришло ли постановление,
//  можно только на официальном портале — приложение туда ведёт и не делает
//  вид, что знает больше: никакого разбора чужих сайтов, номер в адрес
//  ссылки не кладётся (адрес уходит в историю браузера, в логи прокси, на
//  чужой сервер аналитики). Номер копируется в буфер — человек вставит его
//  сам.
//
//  Рядом — своя оценка «по нашим замерам за 30 дней». Это не постановление:
//  лимит мог быть другим, камера могла не работать, и об этом строка
//  говорит прямо. Сумма — из дневных сводок (TripDay), которые переживают
//  чистку записей, и по тем же воротам достоверности, что везде: деньги —
//  только по известному лимиту и без «штраф не пришёл».
//
//  Чистая логика — FineCheckTests.
//

import Foundation

nonisolated enum FineCheck {
    /// Буквы, которые на клавиатуре кириллицей выглядят так же, как на
    /// номере латиницей: «01 А 123 ВС» набирают и так.
    private static let lookalikes: [Character: Character] = [
        "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O",
        "Р": "P", "С": "C", "Т": "T", "У": "Y", "Х": "X",
    ]

    /// Номер в каноническом виде («01A123BC») или nil, если это не номер
    /// Узбекистана: частный «01 A 123 BC» или юрлица «01 123 ABC».
    static func normalizedPlate(_ raw: String) -> String? {
        let compact = raw.uppercased().compactMap { char -> Character? in
            if char == " " || char == "-" { return nil }
            return lookalikes[char] ?? char
        }
        let plate = String(compact)
        guard plate.count == 8, plate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let chars = Array(plate)
        let digit = { (i: Int) in chars[i].isNumber }
        let letter = { (i: Int) in chars[i].isLetter }
        guard digit(0), digit(1) else { return nil }
        let personal = letter(2) && digit(3) && digit(4) && digit(5) && letter(6) && letter(7)
        let company = digit(2) && digit(3) && digit(4) && letter(5) && letter(6) && letter(7)
        return personal || company ? plate : nil
    }

    /// Номер для глаз: «01 A 123 BC» / «01 123 ABC».
    static func displayPlate(_ plate: String) -> String {
        let chars = Array(plate)
        guard chars.count == 8 else { return plate }
        let region = String(chars[0..<2])
        if chars[2].isLetter {
            return "\(region) \(chars[2]) \(String(chars[3..<6])) \(String(chars[6..<8]))"
        }
        return "\(region) \(String(chars[2..<5])) \(String(chars[5..<8]))"
    }

    /// Оценка за последние 30 дней по дневным сводкам: окно — от полуночи
    /// дня 29 дней назад до конца сегодняшнего (30 календарных дней).
    static func estimate(days: [TripDay], now: Date, calendar: Calendar = .current) -> Double {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(AppConfig.fineCheckWindowDays - 1), to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return 0 }
        return TripDayBook.days(days, in: DateInterval(start: start, end: end)).reduce(0) { $0 + $1.fineRisk }
    }
}
