//
//  FineReceiptTests.swift
//  RadarMapTests
//
//  «Штраф пришёл» по внесённому постановлению (этап 17.1) — обратное
//  правилу «не пришёл» (FineDismissTests): деньги уходят из «возможных» и
//  приходят в «пришло» суммой постановления; поведение — превышения,
//  рейтинг, «Где теряете баллы» — не меняется. День чинится парой
//  unfolded/folded и обязан сойтись с пересборкой по записям.
//

import XCTest
@testable import RadarMap

final class FineReceiptTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func pass(_ id: Int, speed: Double, limit: Int?, assumed: Bool? = nil) -> PassedCamera {
        var pass = PassedCamera(id: UUID(), cameraID: id, typeRaw: "Стационар радар", location: "Юнусабад",
                                speedKmh: speed, date: now.addingTimeInterval(-86400), lat: 41.31, lon: 69.28,
                                limitKmh: limit)
        pass.limitAssumed = assumed
        return pass
    }

    private func record(_ passes: [PassedCamera]) -> TripRecord {
        let start = now.addingTimeInterval(-86400 - 600)
        return TripRecord(id: start.timeIntervalSince1970, startedAt: start, endedAt: start.addingTimeInterval(1800),
                          distanceMeters: 12_000, maxSpeedKmh: 95, passed: passes, score: 72)
    }

    /// Сверка ставит «пришёл» с суммой постановления; риск записи падает на
    /// оценку, «пришло» — ровно сумма постановления; балл не трогается.
    func testLinkMovesMoneyNotBehavior() throws {
        let over = pass(1, speed: 88, limit: 60)        // +28 → 5 БРВ
        let other = pass(2, speed: 92, limit: 60)
        let original = record([over, other])
        let fineID = UUID()
        let linked = try XCTUnwrap(TripHistory.linkingReceivedFine(original, passID: over.id, fineID: fineID,
                                                                   amount: 2_100_000))
        let marked = try XCTUnwrap(linked.passed.first { $0.id == over.id })
        XCTAssertEqual(marked.finePaid, true)
        XCTAssertNil(marked.fineDismissed)
        XCTAssertEqual(marked.fineReceiptID, fineID)
        XCTAssertEqual(marked.fineAmount, 2_100_000)
        XCTAssertEqual(TripHistory.fineRisk(of: linked.passed),
                       TripHistory.fineRisk(of: original.passed) - 5 * FineSchedule.brv, accuracy: 0.01)
        XCTAssertEqual(TripHistory.finesPaid(of: linked.passed), 2_100_000, accuracy: 0.01)
        XCTAssertEqual(linked.score, original.score, "рейтинг — про езду, не про почту")
        XCTAssertNil(linked.passed.first { $0.id == other.id }?.fineReceiptID)
    }

    /// День чинится хирургически и сходится с пересборкой по записям, а
    /// превышения и рейтинг дня не меняются.
    func testDayRollupRepairMatchesRebuild() throws {
        let over = pass(1, speed: 88, limit: 60)
        let original = record([over])
        let days = TripDayBook.folded(original, into: [], calendar: utc)
        let linked = try XCTUnwrap(TripHistory.linkingReceivedFine(original, passID: over.id, fineID: UUID(),
                                                                   amount: 2_100_000))
        let repaired = TripDayBook.replaced([original], with: [linked], in: days, calendar: utc)
        XCTAssertEqual(repaired, TripDayBook.rebuilt(from: [linked], calendar: utc))
        XCTAssertEqual(repaired[0].fineRisk, 0, accuracy: 0.01)
        XCTAssertEqual(repaired[0].finePaid ?? 0, 2_100_000, accuracy: 0.01)
        XCTAssertEqual(repaired[0].overPasses, days[0].overPasses)
        XCTAssertEqual(repaired[0].rating, days[0].rating)
        // Сводка периода по записям и по дням — одни и те же деньги.
        let interval = DateInterval(start: now.addingTimeInterval(-7 * 86400), end: now)
        XCTAssertEqual(TripDayBook.summary(repaired, in: interval).finesPaid, 2_100_000, accuracy: 0.01)
    }

    /// Отвязка возвращает проезд в «ожидается», а день — ровно в исходный.
    func testUnlinkRestoresExactly() throws {
        let over = pass(1, speed: 88, limit: 60)
        let original = record([over])
        let days = TripDayBook.folded(original, into: [], calendar: utc)
        let fineID = UUID()
        let linked = try XCTUnwrap(TripHistory.linkingReceivedFine(original, passID: over.id, fineID: fineID,
                                                                   amount: 2_100_000))
        let linkedDays = TripDayBook.replaced([original], with: [linked], in: days, calendar: utc)
        let unlinked = try XCTUnwrap(TripHistory.unlinkingReceivedFine(linked, passID: over.id, fineID: fineID))
        let back = TripDayBook.replaced([linked], with: [unlinked], in: linkedDays, calendar: utc)
        XCTAssertEqual(back, days)
        XCTAssertEqual(unlinked.passed[0].fineOutcome, .pending)
        XCTAssertNil(unlinked.passed[0].fineAmount)
        // Чужая сверка не снимается.
        XCTAssertNil(TripHistory.unlinkingReceivedFine(linked, passID: over.id, fineID: UUID()))
    }

    /// Один проезд — одно постановление: второе к нему не привязать.
    func testSecondFineOnSamePassIsRefused() throws {
        let over = pass(1, speed: 88, limit: 60)
        let first = UUID()
        let linked = try XCTUnwrap(TripHistory.linkingReceivedFine(record([over]), passID: over.id, fineID: first,
                                                                   amount: 2_100_000))
        XCTAssertNil(TripHistory.linkingReceivedFine(linked, passID: over.id, fineID: UUID(), amount: 1))
        // Тот же штраф (правка суммы) — можно.
        XCTAssertNotNil(TripHistory.linkingReceivedFine(linked, passID: over.id, fineID: first, amount: 412_000))
    }

    /// Постановление — факт и без нашего лимита: проезд с предположенным
    /// лимитом и сверкой считается в «пришло» суммой постановления, а кнопки
    /// «Не пришёл»/«Вернуть» его больше не трогают.
    func testReceiptCountsEvenWithAssumedLimitAndLocksButtons() throws {
        let guessed = pass(1, speed: 88, limit: 60, assumed: true)
        let fineID = UUID()
        let linked = try XCTUnwrap(TripHistory.linkingReceivedFine(record([guessed]), passID: guessed.id,
                                                                   fineID: fineID, amount: 412_000))
        XCTAssertEqual(linked.passed[0].paidAmount, 412_000)
        XCTAssertEqual(TripHistory.finesPaid(of: linked.passed), 412_000, accuracy: 0.01)
        XCTAssertNil(TripHistory.settingFineOutcome(linked, passID: guessed.id, outcome: .pending))
        XCTAssertNil(TripHistory.settingFineOutcome(linked, passID: guessed.id, outcome: .dismissed))
    }

    /// «Пришёл» кнопкой без постановления — по-прежнему оценка по ступени.
    func testButtonPaidStillUsesEstimate() throws {
        let over = pass(1, speed: 88, limit: 60)
        let paid = try XCTUnwrap(TripHistory.settingFineOutcome(record([over]), passID: over.id, outcome: .paid))
        XCTAssertEqual(paid.passed[0].paidAmount ?? 0, 5 * FineSchedule.brv, accuracy: 0.01)
        let days = TripDayBook.rebuilt(from: [paid], calendar: utc)
        XCTAssertEqual(days[0].finePaid ?? 0, 5 * FineSchedule.brv, accuracy: 0.01)
    }

    /// Проезд без лимита со сверкой: «пришло» — в дне тоже (до проверки лимита).
    func testReceiptWithoutLimitFoldsIntoDay() throws {
        let unknown = pass(1, speed: 70, limit: nil)
        let original = record([unknown])
        let days = TripDayBook.folded(original, into: [], calendar: utc)
        let linked = try XCTUnwrap(TripHistory.linkingReceivedFine(original, passID: unknown.id, fineID: UUID(),
                                                                   amount: 412_000))
        let repaired = TripDayBook.replaced([original], with: [linked], in: days, calendar: utc)
        XCTAssertEqual(repaired[0].finePaid ?? 0, 412_000, accuracy: 0.01)
        XCTAssertEqual(repaired[0].overPasses, 0, "без лимита превышение не выдумываем")
        XCTAssertEqual(TripDayBook.replaced([linked], with: [original], in: repaired, calendar: utc), days)
    }

    /// Сверка с днём (запись вычищена): перенос и возврат — одни и те же числа.
    func testDayShiftIsReversible() throws {
        let over = pass(1, speed: 88, limit: 60)
        let days = TripDayBook.folded(record([over]), into: [], calendar: utc)
        let day = days[0].day
        let shifted = try XCTUnwrap(TripDayBook.shiftingFine(day: day, riskMoved: 5 * FineSchedule.brv,
                                                             paidAdded: 2_100_000, reverse: false, in: days))
        XCTAssertEqual(shifted[0].fineRisk, 0, accuracy: 0.01)
        XCTAssertEqual(shifted[0].finePaid ?? 0, 2_100_000, accuracy: 0.01)
        XCTAssertEqual(shifted[0].overPasses, days[0].overPasses)
        let back = try XCTUnwrap(TripDayBook.shiftingFine(day: day, riskMoved: 5 * FineSchedule.brv,
                                                          paidAdded: 2_100_000, reverse: true, in: shifted))
        XCTAssertEqual(back[0].fineRisk, days[0].fineRisk, accuracy: 0.01)
        XCTAssertEqual(back[0].finePaid ?? 0, 0, accuracy: 0.01)
        XCTAssertNil(TripDayBook.shiftingFine(day: day.addingTimeInterval(86400), riskMoved: 1, paidAdded: 1,
                                              reverse: false, in: days), "строки дня нет — правки нет")
    }

    /// Старые файлы без новых полей читаются, новые поля переживают кодирование.
    func testCodableMigration() throws {
        let legacy = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","cameraID":1,"typeRaw":"Стационар радар","location":"x","speedKmh":80,"date":0}"#
        let decoded = try JSONDecoder().decode(PassedCamera.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.fineReceiptID)
        XCTAssertNil(decoded.fineAmount)
        XCTAssertNil(decoded.paidAmount)

        var fine = ReceivedFine(addedAt: now)
        fine.amount = 412_000
        fine.link = .pass(tripID: 1, passID: UUID())
        let roundTrip = try JSONDecoder().decode(ReceivedFine.self, from: JSONEncoder().encode(fine))
        XCTAssertEqual(roundTrip, fine)
        // Связь из будущей сборки с незнакомыми полями — «без поездки», а не битый штраф.
        let future = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","addedAt":0,"link":{"registryID":"x"},"source":"registry"}"#
        let read = try JSONDecoder().decode(ReceivedFine.self, from: Data(future.utf8))
        XCTAssertEqual(read.link?.kind, .unknown)
        XCTAssertEqual(read.sourceKind, .manual)
    }
}
