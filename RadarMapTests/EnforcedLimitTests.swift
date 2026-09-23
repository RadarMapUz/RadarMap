//
//  EnforcedLimitTests.swift
//  RadarMapTests
//
//  Пол фиксации. Правило приехало из поездки: «в городе нет камер на 50,
//  всё начинается с 60». Замер боевой базы это подтвердил — 15 % сегментов
//  Ташкента несут тег ниже 60, и по ним выписывались штрафы, которых камера
//  не выписывает.
//
//  Направление правки односторонее, и тесты сторожат именно это: лимит можно
//  только ПОДНЯТЬ до пола, и только для денег и рейтинга.
//

import XCTest
@testable import RadarMap

final class EnforcedLimitTests: XCTestCase {

    /// Тот самый случай: улица с тегом 50, проезд на 66.
    func testFiftyTagStopsCostingMoney() {
        XCTAssertEqual(EnforcedLimit.applied(to: 50), 60)
        // По тегу 50 превышение было 16 км/ч — целый БРВ и минус 14 баллов.
        XCTAssertGreaterThan(FineSchedule.fine(overKmh: 66 - 50), 0)
        XCTAssertEqual(DrivingScore.penaltyPoints(overKmh: 66 - 50), 14)
        // По полу — 6 км/ч: штраф по-прежнему есть (камера фиксирует с 66),
        // но это честная ступень, а не выдуманная.
        XCTAssertEqual(DrivingScore.penaltyPoints(overKmh: 66 - 60), 8)
    }

    /// Проезд в настоящем лимите перестаёт быть нарушением вовсе.
    func testCalmPassUnderTheFloorIsNoLongerAViolation() {
        XCTAssertGreaterThan(FineSchedule.fine(overKmh: 58 - 50), 0)
        XCTAssertEqual(FineSchedule.fine(overKmh: 58 - Double(EnforcedLimit.kmh(road: 50))), 0)
    }

    /// Главный запрет проекта: лимит выше пола не трогаем НИКОГДА.
    /// Поднять 70 до 100 «потому что данные так говорят» — это снять
    /// предупреждение о настоящем штрафе.
    func testLimitsAboveTheFloorAreNeverTouched() {
        for limit in [60, 70, 80, 90, 100, 110, 130] {
            XCTAssertEqual(EnforcedLimit.kmh(road: limit), limit)
            XCTAssertFalse(EnforcedLimit.isFloored(road: limit))
        }
    }

    /// «Лимита не было вовсе» — не то же самое, что «лимит ниже пола».
    /// Пол не вправе выдумывать лимит там, где его не нашли: из nil растёт
    /// «лимит неизвестен», и превращать это в 60 значит начать судить вслепую.
    func testMissingLimitStaysMissing() {
        XCTAssertNil(EnforcedLimit.applied(to: nil))
        XCTAssertFalse(EnforcedLimit.isFloored(road: nil))
    }

    func testFlooringIsReportedSoTheScreenCanSayIt() {
        XCTAssertTrue(EnforcedLimit.isFloored(road: 20))
        XCTAssertTrue(EnforcedLimit.isFloored(road: 59))
        XCTAssertFalse(EnforcedLimit.isFloored(road: 60))
    }

    /// Пол применён в ОДНОМ месте — при записи проезда, — и оттуда виден
    /// всем: и деньгам, и баллу, и «своим» камерам.
    func testRecordedPassCarriesBothLimits() {
        var pass = PassedCamera(id: UUID(), cameraID: 1, typeRaw: "Стационар радар",
                                location: "", speedKmh: 66, date: Date())
        pass.limitKmh = EnforcedLimit.applied(to: 50)
        pass.roadLimitKmh = 50
        XCTAssertEqual(pass.limitKmh, 60)
        XCTAssertEqual(pass.overLimitKmh, 6)
        XCTAssertTrue(pass.limitWasFloored)
    }
}
