//
//  FineTextParserTests.swift
//  RadarMapTests
//
//  «Вставить текст» (этап 17.2). Главное — чего разбор делать НЕ должен:
//  выдумывать поле, принимать СМС банка за штраф, тащить госномер в сумму
//  или номер постановления. Образцы — RadarMapTests/FineTexts (пока
//  синтетические; настоящие пришлёт владелец, см. README там же).
//

import XCTest
@testable import RadarMap

final class FineTextParserTests: XCTestCase {

    // MARK: - Образцы из папки

    /// Папка образцов — рядом с этим файлом. У тестовой цели нет фазы
    /// ресурсов, а симулятор читает файлы мака напрямую: образец, положенный
    /// в папку, подхватывается без правки проекта.
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("FineTexts")
    }

    /// Каждый fine_*.txt разбирается ровно в свой fine_*.json: найденное
    /// совпадает, ненайденное — nil, «проверьте» — только у перечисленных.
    func testFixtures() throws {
        let texts = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("fine_") && $0.pathExtension == "txt" }
        XCTAssertGreaterThanOrEqual(texts.count, 8, "образцы не найдены")
        for url in texts {
            let name = url.deletingPathExtension().lastPathComponent
            let expectedURL = url.deletingPathExtension().appendingPathExtension("json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path), "нет \(name).json")
            let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL))
                                         as? [String: Any])
            let draft = FineTextParser.parse(try String(contentsOf: url, encoding: .utf8))
            check(draft, against: expected, name: name)
        }
    }

    private func check(_ draft: FineDraft, against expected: [String: Any], name: String) {
        let isFine = expected["fine"] as? Bool ?? true
        XCTAssertEqual(draft.looksLikeFine, isFine, "\(name): похоже ли на штраф")
        let unsure = Set((expected["unsure"] as? [String]) ?? [])
        for field in FineDraft.Name.allCases {
            let actual = value(of: field, in: draft)
            if let want = expected[field.rawValue] {
                XCTAssertEqual(actual, "\(want)", "\(name): \(field.rawValue)")
                XCTAssertEqual(draft.sureness(of: field), !unsure.contains(field.rawValue),
                               "\(name): уверенность \(field.rawValue)")
            } else {
                XCTAssertNil(actual, "\(name): \(field.rawValue) выдуман")
            }
        }
    }

    private func value(of field: FineDraft.Name, in draft: FineDraft) -> String? {
        func day(_ d: FineDraft.Day?) -> String? {
            d.map { String(format: "%04d-%02d-%02d", $0.year, $0.month, $0.day) }
        }
        switch field {
        case .date: return day(draft.date?.value)
        case .time: return draft.time.map { String(format: "%02d:%02d", $0.value.hour, $0.value.minute) }
        case .issued: return day(draft.issued?.value)
        case .due: return day(draft.due?.value)
        case .amount: return draft.amount.map { String(Int($0.value)) }
        case .speed: return draft.speedKmh.map { String($0.value) }
        case .limit: return draft.limitKmh.map { String($0.value) }
        case .resolution: return draft.resolution?.value
        case .place: return draft.place?.value
        }
    }

    // MARK: - Чужой текст и выдумки

    /// СМС банка с датой, временем и суммой — не штраф: ни одного поля.
    func testBankMessageIsNotAFine() {
        let draft = FineTextParser.parse("Karta *1234: Pokupka 45 000 UZS, 12.10.2026 18:45")
        XCTAssertFalse(draft.looksLikeFine)
        XCTAssertTrue(draft.isEmpty)
    }

    /// «Пришёл штраф» без цифр — похоже на штраф, но полей нет: форма
    /// остаётся пустой, «сегодня» и нули не подставляются.
    func testFineWordWithoutFieldsInventsNothing() {
        let draft = FineTextParser.parse("Вам пришёл штраф, проверьте")
        XCTAssertTrue(draft.looksLikeFine)
        XCTAssertTrue(draft.isEmpty)
        XCTAssertTrue(draft.foundFields.isEmpty)
    }

    /// Госномер не становится ни суммой, ни номером постановления и не
    /// попадает ни в одно поле.
    func testPlateNeverLeaksIntoFields() {
        for text in ["Штраф ПДД: 01 A 123 BC", "Jarima: 10777ABC avtomobil",
                     "Штраф: автомобиль 01А123ВС, номер постановления не указан"] {
            let draft = FineTextParser.parse(text)
            XCTAssertNil(draft.amount, text)
            XCTAssertNil(draft.resolution, text)
            XCTAssertNil(draft.speedKmh, text)
            let joined = [draft.place?.value, draft.resolution?.value].compactMap { $0 }.joined()
            XCTAssertFalse(joined.contains("123"), text)
        }
    }

    /// Сумма ровно 50 000 сум прописью заглавными — не номер юрлица «50 000 СУМ».
    func testCapitalCurrencyIsNotAPlate() {
        let draft = FineTextParser.parse("ШТРАФ ПДД 03.10.2026 07:58 СУММА 50 000 СУМ")
        XCTAssertEqual(draft.amount?.value, 50_000)
    }

    // MARK: - Скорость

    /// «Превышение на 22 км/ч при ограничении 60» — скорость выводится, но
    /// это вывод, а не прочитанное: «проверьте».
    func testExcessWithLimitGivesUnsureSpeed() {
        let draft = FineTextParser.parse("Штраф: превышение скорости на 22 км/ч при ограничении 60 км/ч")
        XCTAssertEqual(draft.limitKmh?.value, 60)
        XCTAssertEqual(draft.limitKmh?.sure, true)
        XCTAssertEqual(draft.speedKmh?.value, 82)
        XCTAssertEqual(draft.speedKmh?.sure, false)
    }

    /// Превышение без лимита — скорости нет (из одного превышения её не сложить).
    func testExcessAloneGivesNoSpeed() {
        let draft = FineTextParser.parse("Штраф ПДД: превышение скорости на 22 км/ч")
        XCTAssertNil(draft.speedKmh)
        XCTAssertNil(draft.limitKmh)
    }

    /// Две скорости без подписей — большая похожа на скорость, меньшая на
    /// лимит; обе «проверьте».
    func testTwoUnlabeledSpeedsAreUnsure() {
        let draft = FineTextParser.parse("Штраф: 84 км/ч / 60 км/ч, 03.10.2026 07:58")
        XCTAssertEqual(draft.speedKmh?.value, 84)
        XCTAssertEqual(draft.limitKmh?.value, 60)
        XCTAssertEqual(draft.speedKmh?.sure, false)
        XCTAssertEqual(draft.limitKmh?.sure, false)
    }

    // MARK: - Даты и суммы

    /// Дата без времени и без подписи — «проверьте» (может быть датой постановления).
    func testPlainDateWithoutTimeIsUnsure() {
        let draft = FineTextParser.parse("Штраф от 14.10.2026")
        XCTAssertEqual(draft.date?.value, FineDraft.Day(year: 2026, month: 10, day: 14))
        XCTAssertEqual(draft.date?.sure, false)
        XCTAssertNil(draft.time)
    }

    /// Невозможная дата не разбирается в «ближайшую» — её просто нет.
    func testImpossibleDateIsDropped() {
        let draft = FineTextParser.parse("Штраф 31.02.2026 12:00")
        XCTAssertNil(draft.date)
    }

    /// Срок оплаты отличается от даты нарушения по подписи («до», «gacha»).
    func testDueDateByLabelBeforeOrGachaAfter() {
        let ru = FineTextParser.parse("Штраф 01.10.2026 10:00. Оплатить до 31.10.2026")
        XCTAssertEqual(ru.due?.value, FineDraft.Day(year: 2026, month: 10, day: 31))
        XCTAssertEqual(ru.date?.value, FineDraft.Day(year: 2026, month: 10, day: 1))
        let uz = FineTextParser.parse("Jarima 01.10.2026 10:00, 31.10.2026 gacha to'lang")
        XCTAssertEqual(uz.due?.value, FineDraft.Day(year: 2026, month: 10, day: 31))
    }

    /// Сумма и скидка: в сумму идёт полная, а не льготная.
    func testDiscountedAmountIsNotTheAmount() {
        let draft = FineTextParser.parse("Штраф 412 000 сум. Со скидкой 50%: 206 000 сум")
        XCTAssertEqual(draft.amount?.value, 412_000)
    }

    /// Разделители тысяч: пробел, точка, запятая, апостроф — одно число.
    func testAmountSeparators() {
        for text in ["Jarima 1 650 000 so‘m", "Jarima 1.650.000 so'm", "Штраф 1,650,000 сум",
                     "Штраф 1650000,00 сум", "Jarima 1’650’000 UZS"] {
            XCTAssertEqual(FineTextParser.parse(text).amount?.value, 1_650_000, text)
        }
    }

    /// Неразрывные пробелы из уведомлений — как обычные.
    func testNonBreakingSpaces() {
        let draft = FineTextParser.parse("Штраф\u{00A0}03.10.2026\u{00A0}07:58, 412\u{202F}000\u{00A0}сум")
        XCTAssertEqual(draft.amount?.value, 412_000)
        XCTAssertEqual(draft.time?.value, FineDraft.Clock(hour: 7, minute: 58))
    }

    // MARK: - Место

    /// Подписанное место — уверенное и без хвоста предложения.
    func testLabeledPlaceStopsAtSentence() {
        let draft = FineTextParser.parse("Штраф. Адрес: ул. Навои, 12 зафиксировано нарушение")
        XCTAssertEqual(draft.place?.value, "ул. Навои, 12")
        XCTAssertEqual(draft.place?.sure, true)
    }

    // MARK: - Источник

    /// Шов 17.4: вставка текста — источник без сети; не штраф — пусто.
    func testPastedTextSourceReturnsDraftsOnlyForFines() async throws {
        let source = PastedTextFineSource()
        let found = try await source.drafts(from: .text("Jarima: 412 000 so'm, 03.10.2026 07:58"))
        XCTAssertEqual(found.count, 1)
        let none = try await source.drafts(from: .text("Karta: Pokupka 45 000 UZS"))
        XCTAssertTrue(none.isEmpty)
    }
}
