//
//  CarPlayAheadTests.swift
//  RadarMapTests
//
//  Лента «что впереди» на экране машины. Тесты написаны против двух ошибок,
//  каждая из которых дороже пустой ленты: камера, которую мы уже проехали,
//  показанная как предстоящая, и тревожная камера, выпавшая из списка, —
//  водитель слышит про неё голосом, а на экране её нет.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class CarPlayAheadTests: XCTestCase {

    private let me = CLLocationCoordinate2D(latitude: 41.3111, longitude: 69.2797)

    /// Камера в `metres` по азимуту `bearing` от точки «я».
    private func camera(id: Int, metres: Double, bearing: Double,
                        type: String = "Стационар камера") -> Camera {
        let point = GeoMath.destination(from: me, bearing: bearing, distanceMeters: metres)
        return Camera(id: id, region: "Т", city: "Ташкент", location: "тест",
                      lat: point.latitude, lon: point.longitude,
                      type: type, violations: [], needsReview: false)
    }

    // MARK: - Направление

    func testCameraBehindIsNotAhead() {
        // Проехали — значит проехали. Строка «камера через 30 метров» о том,
        // что уже позади, заставит искать глазами то, чего впереди нет.
        let items = CarPlayAhead.items(cameras: [camera(id: 1, metres: 300, bearing: 180)],
                                        from: me, course: 0, targetID: nil) { _ in true }
        XCTAssertTrue(items.isEmpty)
    }

    func testCameraAheadIsListed() {
        let items = CarPlayAhead.items(cameras: [camera(id: 1, metres: 300, bearing: 0)],
                                        from: me, course: 0, targetID: nil) { _ in true }
        XCTAssertEqual(items.map(\.id), [1])
        XCTAssertEqual(items[0].distance, 300, accuracy: 12)
    }

    func testNoCourseMeansNoRibbon() {
        // Без курса «впереди» — это круг вокруг машины. Лучше пусто, чем
        // перечисление камер во всех направлениях сразу.
        let items = CarPlayAhead.items(cameras: [camera(id: 1, metres: 300, bearing: 0)],
                                        from: me, course: -1, targetID: nil) { _ in true }
        XCTAssertTrue(items.isEmpty)
    }

    func testGateDecidesWhatIsOurRoad() {
        // Своего коридора у ленты нет: «наша ли дорога» решает тот же гейт,
        // что и у оповещений. Здесь это проверяется буквально — гейт сказал
        // «нет», и камеры в ленте не оказалось, хотя она строго впереди.
        let ahead = camera(id: 7, metres: 300, bearing: 0)
        let listed = CarPlayAhead.items(cameras: [ahead], from: me, course: 0,
                                         targetID: nil) { _ in false }
        XCTAssertTrue(listed.isEmpty, "гейт старше собственных догадок ленты")
    }

    func testGateIsAskedOnlyAboutCamerasAhead() {
        // Гейт считает геометрию дороги — дорого. Камеры позади и за пределом
        // ленты отсеиваются ДО него, дешёвой арифметикой.
        var asked: [Int] = []
        _ = CarPlayAhead.items(cameras: [camera(id: 1, metres: 300, bearing: 180),
                                          camera(id: 2, metres: 2600, bearing: 0),
                                          camera(id: 3, metres: 300, bearing: 0)],
                                from: me, course: 0, targetID: nil) { camera in
            asked.append(camera.id); return true
        }
        XCTAssertEqual(asked, [3])
    }

    // MARK: - Дальность и порядок

    func testBeyondRangeIsDropped() {
        let items = CarPlayAhead.items(cameras: [camera(id: 1, metres: 2600, bearing: 0)],
                                        from: me, course: 0, targetID: nil) { _ in true }
        XCTAssertTrue(items.isEmpty)
    }

    func testSortedByDistance() {
        let list = [camera(id: 3, metres: 1200, bearing: 0),
                    camera(id: 1, metres: 200, bearing: 0),
                    camera(id: 2, metres: 700, bearing: 0)]
        let items = CarPlayAhead.items(cameras: list, from: me, course: 0, targetID: nil) { _ in true }
        XCTAssertEqual(items.map(\.id), [1, 2, 3])
    }

    func testFractionGrowsWithDistance() {
        // Доля — это положение точки на ленте; ближняя камера обязана быть
        // ниже дальней, иначе лента рисует обратный порядок.
        let list = [camera(id: 1, metres: 500, bearing: 0),
                    camera(id: 2, metres: 1500, bearing: 0)]
        let items = CarPlayAhead.items(cameras: list, from: me, course: 0, targetID: nil) { _ in true }
        XCTAssertLessThan(items[0].fraction, items[1].fraction)
        XCTAssertLessThanOrEqual(items[1].fraction, 1)
    }

    func testRibbonIsCapped() {
        let list = (1...9).map { camera(id: $0, metres: Double($0) * 180, bearing: 0) }
        let items = CarPlayAhead.items(cameras: list, from: me, course: 0, targetID: nil) { _ in true }
        XCTAssertEqual(items.count, CarPlayAhead.maxItems)
    }

    // MARK: - Тревожная камера

    func testTargetIsMarked() {
        let list = [camera(id: 1, metres: 200, bearing: 0),
                    camera(id: 2, metres: 800, bearing: 0)]
        let items = CarPlayAhead.items(cameras: list, from: me, course: 0, targetID: 2) { _ in true }
        XCTAssertEqual(items.first(where: \.isTarget)?.id, 2)
    }

    func testTargetSurvivesTheCap() {
        // Голос говорит про камеру, которая по расстоянию не влезла в ленту.
        // Показать ленту без неё — значит противоречить самому себе.
        var list = (1...6).map { camera(id: $0, metres: Double($0) * 150, bearing: 0) }
        list.append(camera(id: 99, metres: 1400, bearing: 0))
        let items = CarPlayAhead.items(cameras: list, from: me, course: 0, targetID: 99) { _ in true }
        XCTAssertTrue(items.contains { $0.id == 99 }, "тревожная камера обязана остаться")
        XCTAssertEqual(items.count, CarPlayAhead.maxItems)
    }

    // MARK: - Разведение налезающих меток

    /// Быстрый способ собрать ленту из голых долей.
    private func items(_ fractions: [Double]) -> [CarPlayAhead.Item] {
        fractions.enumerated().map { index, f in
            CarPlayAhead.Item(id: index, kind: .stationaryCamera,
                              distance: f * 2000, fraction: f, isTarget: false)
        }
    }

    func testSpreadLeavesRoomyRibbonAlone() {
        let source = items([0.1, 0.5, 0.9])
        XCTAssertEqual(CarPlayAhead.spread(source, minGap: 0.08).map(\.fraction),
                       [0.1, 0.5, 0.9])
    }

    func testOverlappingMarkersArePushedApart() {
        // Камеры на перекрёстке: 40 метров разницы на ленте в два километра —
        // это один пиксель, и подписи ложатся буква на букву.
        let spread = CarPlayAhead.spread(items([0.30, 0.32]), minGap: 0.10)
        XCTAssertEqual(spread[0].fraction, 0.30, accuracy: 0.001,
                       "ближняя камера остаётся на своём месте")
        XCTAssertGreaterThanOrEqual(spread[1].fraction - spread[0].fraction, 0.099)
    }

    func testNearestStaysPutWhenThereIsRoomAbove() {
        let spread = CarPlayAhead.spread(items([0.05, 0.06, 0.07]), minGap: 0.1)
        XCTAssertEqual(spread[0].fraction, 0.05, accuracy: 0.001)
        XCTAssertEqual(spread.map(\.fraction).sorted(), spread.map(\.fraction),
                       "порядок не переставился")
    }

    func testCrowdedTopIsPackedDownwardsInsteadOfSpillingOut() {
        // Четыре камеры у самого верха: раздвинуть вверх некуда, и лента
        // обязана уложиться в свои границы, а не уехать за край.
        let spread = CarPlayAhead.spread(items([0.90, 0.92, 0.94, 0.96]), minGap: 0.12)
        XCTAssertLessThanOrEqual(spread.last!.fraction, 1.0001)
        XCTAssertGreaterThanOrEqual(spread.first!.fraction, 0)
        for index in 1..<spread.count {
            XCTAssertGreaterThanOrEqual(spread[index].fraction - spread[index - 1].fraction,
                                        0.119, "зазор выдержан после поджатия")
        }
    }

    func testSpreadNeverDropsACamera() {
        // Правило проекта: камера не пропадает молча — ни на карте, ни здесь.
        let source = items([0.5, 0.5, 0.5, 0.5])
        XCTAssertEqual(CarPlayAhead.spread(source, minGap: 0.15).count, source.count)
    }

    // MARK: - Подпись

    func testSummaryIsSilentForASingleCamera() {
        // «1 впереди» рядом с одной точкой — шум: точка и так одна.
        let items = CarPlayAhead.items(cameras: [camera(id: 1, metres: 300, bearing: 0)],
                                        from: me, course: 0, targetID: nil) { _ in true }
        XCTAssertNil(CarPlayAhead.summary(items))
    }

    func testSummaryCountsWhatIsShown() {
        let list = [camera(id: 1, metres: 200, bearing: 0),
                    camera(id: 2, metres: 900, bearing: 0)]
        let items = CarPlayAhead.items(cameras: list, from: me, course: 0, targetID: nil) { _ in true }
        XCTAssertNotNil(CarPlayAhead.summary(items))
    }
}
