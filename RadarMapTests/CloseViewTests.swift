//
//  CloseViewTests.swift
//  RadarMapTests
//
//  Вид вблизи: когда схема переходит к полосам.
//
//  Сторожатся не картинки, а решения. Их два вида, и оба ломаются молча:
//  вид, который не включился на манёвре, оставляет водителя без ответа на
//  «в какой я полосе»; вид, который дёргается между масштабами на каждом
//  перекрёстке, хуже любого из двух.
//

import XCTest
@testable import RadarMap

final class CloseViewTests: XCTestCase {

    private func reason(maneuver: Double? = nil, camera: Double? = nil,
                        speed: Double = 60, crawling: Double = 0,
                        wasClose: Bool = false) -> RoadSketch.CloseReason? {
        RoadSketch.closeReason(toManeuver: maneuver, toCamera: camera,
                               speedKmh: speed, crawlingSeconds: crawling,
                               wasClose: wasClose)
    }

    // MARK: - Что включает

    func testManeuverAheadTurnsItOn() {
        XCTAssertEqual(reason(maneuver: 120), .maneuver)
    }

    func testFarManeuverDoesNot() {
        XCTAssertNil(reason(maneuver: 400))
    }

    func testAlertCameraTurnsItOn() {
        XCTAssertEqual(reason(camera: 100), .camera)
    }

    func testCameraThresholdIsTighterThanManeuver() {
        // У камеры не надо перестраиваться, надо сбросить скорость: ближе.
        XCTAssertNil(reason(camera: 140))
        XCTAssertEqual(reason(maneuver: 140), .maneuver)
    }

    func testCrawlTurnsItOn() {
        XCTAssertEqual(reason(speed: 10, crawling: 6), .crawl)
    }

    func testSlowButBrieflyDoesNot() {
        // Притормозил перед лежачим — это не двор.
        XCTAssertNil(reason(speed: 10, crawling: 2))
    }

    func testFastAndNothingAheadStaysWide() {
        XCTAssertNil(reason(speed: 90, crawling: 0))
    }

    // MARK: - Гистерезис

    func testItHoldsPastTheEntryThreshold() {
        // Вошли на 150 м; на 200 м вид обязан ДЕРЖАТЬСЯ, иначе он моргает на
        // каждом перекрёстке.
        XCTAssertNil(reason(maneuver: 200))
        XCTAssertEqual(reason(maneuver: 200, wasClose: true), .maneuver)
    }

    func testItDoesLetGoEventually() {
        // Но не держится вечно: манёвр пройден — возвращаемся к обзору.
        XCTAssertNil(reason(maneuver: 400, wasClose: true))
    }

    func testCrawlAlsoHoldsWithMargin() {
        // На светофоре тронулись — вид не должен моргать на каждом трогании.
        XCTAssertNil(reason(speed: 28, crawling: 9))
        XCTAssertEqual(reason(speed: 28, crawling: 9, wasClose: true), .crawl)
    }

    // MARK: - Порядок причин

    func testManeuverWinsOverCamera() {
        // Обе причины разом: манёвр важнее — он про решение, а не про скорость.
        XCTAssertEqual(reason(maneuver: 100, camera: 100), .maneuver)
    }

    func testCloseSpanIsSmallerThanTheUsualFloor() {
        // Ступень вблизи обязана быть ниже обычной нижней: иначе это не новый
        // вид, а тот же самый.
        XCTAssertLessThan(RoadSketch.closeSpanMeters, RoadSketch.minSpanMeters)
    }

    func testExitIsFartherThanEntry() {
        XCTAssertGreaterThan(RoadSketch.closeExitMeters,
                             RoadSketch.closeManeuverMeters)
    }
}
