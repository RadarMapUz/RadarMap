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
                        inYard: Bool = true,
                        wasClose: Bool = false) -> RoadSketch.CloseReason? {
        RoadSketch.closeReason(toManeuver: maneuver, toCamera: camera,
                               speedKmh: speed, crawlingSeconds: crawling,
                               onMinorRoad: inYard, wasClose: wasClose)
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

    func testCrawlInAYardTurnsItOn() {
        XCTAssertEqual(reason(speed: 10, crawling: 6), .crawl)
    }

    func testCrawlOnAMainRoadDoesNot() {
        // Пробка на прямом проспекте — не повод смотреть вблизи: там нечего
        // разглядывать, а масштаб, залипший на светофоре, потом едет с
        // водителем весь маршрут. Ровно это и было на снимке живой поездки:
        // 29 км/ч, весь экран — стена асфальта.
        XCTAssertNil(reason(speed: 10, crawling: 30, inYard: false))
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

    func testCrawlHoldsWithMarginButLetsGoInTraffic() {
        // На светофоре тронулись — вид не должен моргать на каждом трогании,
        // поэтому выход по скорости с запасом. Но запас МАЛЕНЬКИЙ: был 1,6
        // (то есть до 32 км/ч), а 32 км/ч — это скорость городского потока, а
        // не признак двора. С таким запасом вид вблизи не отпускал никогда.
        XCTAssertEqual(reason(speed: 22, crawling: 9, wasClose: true), .crawl)
        XCTAssertNil(reason(speed: 28, crawling: 9, wasClose: true),
                     "поток 28 км/ч держал схему на пятидесяти пяти метрах")
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

    // MARK: - Вид вблизи обязан вмещать свою причину

    func testCloseViewShowsTheCameraThatTurnedItOn() {
        // Самое стыдное из найденного: вид включался при камере в 120 метрах
        // и показывал вперёд 43 метра, то есть первым делом стирал с экрана
        // ту самую камеру. Она возвращалась только с сорока метров — почти
        // восемьдесят метров подхода водитель смотрел на пустой асфальт и
        // цифру в карточке.
        for distance in stride(from: 40.0, through: 250, by: 10) {
            let span = RoadSketch.closeSpan(reason: .camera, toManeuver: nil,
                                            toCamera: distance)
            XCTAssertTrue(RoadSketch.isInRange(distance: distance, span: span),
                          "камера в \(distance) м не попала в вид вблизи")
        }
    }

    func testCloseSpanShrinksToTheStepAsWeArrive() {
        // Чем ближе причина, тем крупнее план: на последних метрах охват
        // приходит к самой ступени и не идёт ниже — иначе схему затрясло бы
        // от шума GPS.
        let far = RoadSketch.closeSpan(reason: .camera, toManeuver: nil, toCamera: 200)
        let near = RoadSketch.closeSpan(reason: .camera, toManeuver: nil, toCamera: 30)
        XCTAssertGreaterThan(far, near)
        XCTAssertEqual(near, RoadSketch.closeSpanMeters)
    }

    func testCrawlHasNoCauseToFrame() {
        // У ползания причины на местности нет — берём саму ступень.
        XCTAssertEqual(RoadSketch.closeSpan(reason: .crawl, toManeuver: nil,
                                            toCamera: 900),
                       RoadSketch.closeSpanMeters)
    }

    func testExitIsFartherThanEntry() {
        XCTAssertGreaterThan(RoadSketch.closeExitMeters,
                             RoadSketch.closeManeuverMeters)
    }
}
