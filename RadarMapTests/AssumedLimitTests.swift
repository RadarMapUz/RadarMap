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

    // MARK: - Справочник

    func testAssumedLimitsAreOrderedByRoadClass() {
        let motorway = try? XCTUnwrap(RoadClass.motorway.assumedLimitKmh)
        let trunk = try? XCTUnwrap(RoadClass.trunk.assumedLimitKmh)
        let primary = try? XCTUnwrap(RoadClass.primary.assumedLimitKmh)
        let residential = try? XCTUnwrap(RoadClass.residential.assumedLimitKmh)
        XCTAssertGreaterThan(motorway ?? 0, trunk ?? 0)
        XCTAssertGreaterThan(trunk ?? 0, primary ?? 0)
        XCTAssertGreaterThan(primary ?? 0, residential ?? 0)
    }

    func testNoGuessWhereThereIsNothingToGuessFrom() {
        XCTAssertNil(RoadClass.unknown.assumedLimitKmh,
                     "неизвестный класс — не повод выдумывать лимит")
        XCTAssertNil(RoadClass.pedestrian.assumedLimitKmh,
                     "тротуар — ошибка снапа, а не дорога с лимитом")
    }

    func testAssumptionsAreNotLowballed() {
        // Заниженное предположение рисует превышение там, где его нет, — это
        // худшая из двух ошибок: приложение начинает врать в свою пользу.
        XCTAssertGreaterThanOrEqual(RoadClass.primary.assumedLimitKmh ?? 0, 70,
                                    "в населённом пункте Узбекистана 70 с 2021 года")
        XCTAssertGreaterThanOrEqual(RoadClass.trunk.assumedLimitKmh ?? 0, 100)
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
