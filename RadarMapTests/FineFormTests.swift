//
//  FineFormTests.swift
//  RadarMapTests
//
//  Форма штрафа (этап 17.2): разбор подставляет только найденное, проезд —
//  только когда и где, пустое поле остаётся пустым и в штрафе становится
//  nil, а не нулём или «сегодня».
//

import XCTest
@testable import RadarMap

final class FineFormTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        return calendar
    }

    /// Разбор кладёт найденное, сомнительное помечает, вписанное руками не трогает.
    func testApplyFillsOnlyFoundFields() {
        var form = FineForm()
        form.resolution = "вписано руками"
        let draft = FineTextParser.parse("Штраф от 14.10.2026, 340 000 сум")
        form.apply(draft, calendar: calendar)
        XCTAssertEqual(form.day, calendar.date(from: DateComponents(year: 2026, month: 10, day: 14)))
        XCTAssertFalse(form.timeKnown)
        XCTAssertEqual(form.amount, FineForm.grouped(340_000))
        XCTAssertEqual(FineForm.integer(form.amount), 340_000)
        XCTAssertEqual(form.resolution, "вписано руками")
        XCTAssertEqual(form.speed, "")
        XCTAssertEqual(form.unsure, [.date])
        XCTAssertTrue(form.fromText)
    }

    /// Не штраф — форма не меняется вовсе.
    func testForeignTextChangesNothing() {
        var form = FineForm()
        form.apply(FineTextParser.parse("Karta: Pokupka 45 000 UZS 12.10.2026 18:45"), calendar: calendar)
        XCTAssertEqual(form, FineForm())
    }

    /// «Пришёл» на проезде: когда и где — из проезда; скорость, лимит и
    /// сумма — только из постановления, не из нашего замера.
    func testPrefillFromPassTakesOnlyWhenAndWhere() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 18, minute: 47))!
        let pass = PassedCamera(id: UUID(), cameraID: 1, typeRaw: "Стационар радар", location: "Юнусабад",
                                speedKmh: 88, date: date, lat: 41.31, lon: 69.28, limitKmh: 60)
        let form = FineForm(pass: pass, calendar: calendar)
        XCTAssertEqual(form.violationAt(calendar: calendar), date)
        XCTAssertTrue(form.timeKnown)
        XCTAssertEqual(form.place, "Юнусабад")
        XCTAssertEqual(form.speed, "")
        XCTAssertEqual(form.limit, "")
        XCTAssertEqual(form.amount, "")
    }

    /// Пустые поля — nil, разделители тысяч — одно число, без дня — не сохранить.
    func testFineFromFieldsInventsNothing() {
        var form = FineForm()
        XCTAssertFalse(form.canSave)
        XCTAssertNil(form.query(calendar: calendar))
        form.day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))
        form.amount = "1 650 000"
        form.place = "   "
        let fine = form.fine(updating: ReceivedFine(), calendar: calendar)
        XCTAssertTrue(form.canSave)
        XCTAssertEqual(fine.amount, 1_650_000)
        XCTAssertEqual(fine.violationAt, form.day, "без времени — начало дня")
        XCTAssertEqual(fine.timeKnown, false)
        XCTAssertNil(fine.place)
        XCTAssertNil(fine.speedKmh)
        XCTAssertNil(fine.limitKmh)
        XCTAssertNil(fine.resolution)
        XCTAssertNil(fine.dueAt)
        XCTAssertEqual(fine.sourceKind, .manual)
    }

    /// Правка сохраняет то, чего форма не касается: id, оплату, напоминание, сверку.
    func testEditKeepsUntouchedState() {
        var original = ReceivedFine()
        original.violationAt = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9, minute: 5))
        original.timeKnown = true
        original.amount = 412_000
        original.paidAt = Date(timeIntervalSince1970: 1_800_000_000)
        original.reminderAt = Date(timeIntervalSince1970: 1_800_100_000)
        original.source = FineSourceKind.pasted.rawValue
        var form = FineForm(fine: original, calendar: calendar)
        XCTAssertEqual(form.hour, 9)
        XCTAssertEqual(form.minute, 5)
        form.amount = "440000"
        let edited = form.fine(updating: original, calendar: calendar)
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.paidAt, original.paidAt)
        XCTAssertEqual(edited.reminderAt, original.reminderAt)
        XCTAssertEqual(edited.amount, 440_000)
        XCTAssertEqual(edited.violationAt, original.violationAt)
        XCTAssertEqual(edited.sourceKind, .pasted)
    }

    /// Сумма с разделителями разрядов — сверять с постановлением глазами;
    /// разбор при этом берёт только цифры.
    func testAmountIsGroupedAndStillParses() {
        let grouped = FineForm.groupedDigits("2200000")
        XCTAssertNotEqual(grouped, "2200000", "разряды разделены")
        XCTAssertEqual(FineForm.integer(grouped), 2_200_000)
        XCTAssertEqual(FineForm.groupedDigits(grouped), grouped, "повторная группировка ничего не меняет")
        XCTAssertEqual(FineForm.groupedDigits(""), "")
        XCTAssertEqual(FineForm.groupedDigits("сум"), "")
    }
}
