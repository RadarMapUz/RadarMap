//
//  AssumedLimitTests.swift
//  RadarMapTests
//
//  Фолбэк лимита по классу дороги. Проверяем не столько сам справочник,
//  сколько ГРАНИЦУ: предположение годится для рейтинга и голоса, но не для
//  суммы штрафа в сумах. Ошибиться здесь — значит соврать пользователю про
//  деньги, а это худший вид неправды в приложении про штрафы.
//

import XCTest
@testable import RadarMap

final class AssumedLimitTests: XCTestCase {

    // MARK: - Справочник: решает населённый пункт, а не класс дороги

    func testInsideSettlementEveryRoadIsSeventy() {
        // Пункт 10 ПДД РУз: в населённом пункте легковому 70 км/ч, и класс
        // дороги в этом правиле не участвует вовсе — ни проспект, ни жилая
        // улица не делают из него исключения.
        for road in [RoadClass.trunk, .primary, .secondary, .tertiary, .residential] {
            XCTAssertEqual(road.assumedLimitKmh(inSettlement: true), 70,
                           "\(road) в населённом пункте — 70 по ПДД")
        }
    }

    func testOutsideSettlementOrdinaryRoadsAreHundred() {
        for road in [RoadClass.trunk, .primary, .secondary, .tertiary, .residential] {
            XCTAssertEqual(road.assumedLimitKmh(inSettlement: false), 100,
                           "\(road) вне населённого пункта — 100 по ПДД")
        }
    }

    func testMotorwayIsOneHundredTenEverywhere() {
        XCTAssertEqual(RoadClass.motorway.assumedLimitKmh(inSettlement: true), 110)
        XCTAssertEqual(RoadClass.motorway.assumedLimitKmh(inSettlement: false), 110)
    }

    func testNoGuessWhereThereIsNothingToGuessFrom() {
        for inSettlement in [true, false] {
            XCTAssertNil(RoadClass.unknown.assumedLimitKmh(inSettlement: inSettlement),
                         "неизвестный класс — не повод выдумывать лимит")
            XCTAssertNil(RoadClass.pedestrian.assumedLimitKmh(inSettlement: inSettlement),
                         "тротуар — ошибка снапа, а не дорога с лимитом")
            XCTAssertNil(RoadClass.service.assumedLimitKmh(inSettlement: inSettlement),
                         "камера главной улицы, севшая на служебный проезд, объявляла бы "
                         + "нарушением любое движение")
        }
    }

    func testNoAssumptionEverInventsAViolation() {
        // Главная защита этого справочника. Заниженная догадка рисует
        // превышение там, где его нет; завышенная только промолчит о нём.
        // Ни одно значение не имеет права оказаться ниже законного минимума
        // для своего места.
        for road in [RoadClass.motorway, .trunk, .primary, .secondary, .tertiary, .residential] {
            XCTAssertGreaterThanOrEqual(road.assumedLimitKmh(inSettlement: true) ?? 0, 70,
                                        "\(road): в городе законные 70 объявлены нарушением")
            XCTAssertGreaterThanOrEqual(road.assumedLimitKmh(inSettlement: false) ?? 0, 100,
                                        "\(road): за городом законные 100 объявлены нарушением")
        }
    }

    func testOfflineGuessTreatsHighwayClassesAsOutOfTown() {
        // Карточка камеры живого контекста не знает: класс — единственный признак.
        XCTAssertEqual(RoadClass.trunk.assumedLimitKmhOffline, 100)
        XCTAssertEqual(RoadClass.motorway.assumedLimitKmhOffline, 110)
        XCTAssertEqual(RoadClass.primary.assumedLimitKmhOffline, 70)
        XCTAssertEqual(RoadClass.residential.assumedLimitKmhOffline, 70)
    }

    // MARK: - Граница «догадка не превращается в деньги»

    private func pass(speed: Double, limit: Int?, assumed: Bool?) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: 1, typeRaw: "Стационар радар",
                     location: "Тест", speedKmh: speed, date: Date(),
                     lat: 41.31, lon: 69.25, limitKmh: limit, limitAssumed: assumed)
    }

    func testCertainLimitProducesAFine() {
        let risk = TripHistory.fineRisk(of: [pass(speed: 95, limit: 60, assumed: nil)])
        XCTAssertGreaterThan(risk, 0)
    }

    func testAssumedLimitProducesNoMoney() {
        let risk = TripHistory.fineRisk(of: [pass(speed: 95, limit: 60, assumed: true)])
        XCTAssertEqual(risk, 0,
                       "сумма в сумах, названная по догадке о классе дороги, — ложь про деньги")
    }

    func testOldRecordsWithoutTheFlagCountAsCertain() {
        // У записей, сделанных до появления фолбэка, поля нет вовсе, и лимит
        // в них мог быть только настоящим — иначе история молча обесценится.
        XCTAssertTrue(pass(speed: 95, limit: 60, assumed: nil).limitIsCertain)
        XCTAssertFalse(pass(speed: 95, limit: 60, assumed: true).limitIsCertain)
        XCTAssertFalse(pass(speed: 95, limit: nil, assumed: nil).limitIsCertain)
    }

    func testAssumedViolationStillCountsAsOverspeed() {
        // Нарушение видно (рейтинг и «где теряете баллы» на него опираются),
        // но денег за него не начисляется.
        let record = TripDay.self
        _ = record
        let assumed = pass(speed: 95, limit: 60, assumed: true)
        XCTAssertNotNil(assumed.overLimitKmh)
        XCTAssertEqual(assumed.overLimitKmh ?? 0, 35, accuracy: 0.001)
        XCTAssertGreaterThan(DrivingScore.penaltyPoints(overKmh: 35), 0,
                             "рейтинг обязан видеть превышение и по предположенному лимиту")
    }

    // MARK: - Persist

    func testDecodingOldRecordWithoutTheNewField() throws {
        // Правило 18 ARCHITECTURE.md: новое поле в персистентной структуре —
        // только Optional, иначе один старый файл валит декод всей истории.
        let old = """
        {"id":"\(UUID().uuidString)","cameraID":1,"typeRaw":"Стационар радар",
         "location":"Старая запись","speedKmh":72.0,
         "date":\(Date().timeIntervalSinceReferenceDate),"limitKmh":60}
        """
        let decoded = try JSONDecoder().decode(PassedCamera.self,
                                               from: Data(old.utf8))
        XCTAssertNil(decoded.limitAssumed)
        XCTAssertTrue(decoded.limitIsCertain)
    }
}
