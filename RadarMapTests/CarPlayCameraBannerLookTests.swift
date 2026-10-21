//
//  CarPlayCameraBannerLookTests.swift
//  RadarMapTests
//
//  Картинки баннера камеры на iOS 27 (25.H1): полоса — та же доля, что на
//  телефоне, ступенями (растр в машину — только при смене ступени или
//  знака); размер вписывается в предел системы.
//

import UIKit
import XCTest
@testable import RadarMap

final class CarPlayCameraBannerLookTests: XCTestCase {

    func testProximityMatchesThePhoneBar() {
        XCTAssertEqual(CarPlayCameraBannerLook.proximity(distance: 400, radius: 400), 0)
        XCTAssertEqual(CarPlayCameraBannerLook.proximity(distance: 100, radius: 400), 0.75)
        XCTAssertEqual(CarPlayCameraBannerLook.proximity(distance: 0, radius: 400), 1)
        XCTAssertEqual(CarPlayCameraBannerLook.proximity(distance: 900, radius: 400), 0, "за радиусом — пусто")
        XCTAssertEqual(CarPlayCameraBannerLook.proximity(distance: 10, radius: 0), 0, "радиус 0 не делит на ноль")
    }

    /// Полоса не обгоняет машину: ступень — вниз.
    func testStepsRoundDown() {
        XCTAssertEqual(CarPlayCameraBannerLook.step(proximity: 0.79, steps: 10), 7)
        XCTAssertEqual(CarPlayCameraBannerLook.step(proximity: 1, steps: 10), 10)
        XCTAssertEqual(CarPlayCameraBannerLook.step(proximity: -1, steps: 10), 0)
        XCTAssertEqual(CarPlayCameraBannerLook.step(proximity: 0.5, steps: 0), 0, "ступеней не меньше одной")
    }

    /// Подъезд от края радиуса до камеры — не больше `steps + 1` разных
    /// картинок, сколько бы фиксов ни пришло.
    func testOneApproachRedrawsAtMostOncePerStep() {
        var arts: [CarPlayCameraBannerLook.Art] = []
        for distance in stride(from: 400.0, through: 0, by: -2.5) {
            let art = CarPlayCameraBannerLook.art(limit: 60, distance: distance, radius: 400)
            if arts.last != art { arts.append(art) }
        }
        XCTAssertEqual(arts.count, AppConfig.carPlayBannerProximitySteps + 1)
        XCTAssertEqual(arts.first?.lead, .limit(60))
    }

    func testUnknownLimitLeadsWithTheType() {
        XCTAssertEqual(CarPlayCameraBannerLook.art(limit: nil, distance: 200, radius: 400).lead, .type)
        XCTAssertNotEqual(CarPlayCameraBannerLook.art(limit: nil, distance: 200, radius: 400),
                          CarPlayCameraBannerLook.art(limit: 60, distance: 200, radius: 400))
    }

    func testFitKeepsAspectWithinTheSystemLimit() {
        let fitted = CarPlayCameraBannerLook.fit(CGSize(width: 220, height: 40),
                                                into: CGSize(width: 110, height: 60))
        XCTAssertEqual(fitted, CGSize(width: 110, height: 20))
        XCTAssertEqual(CarPlayCameraBannerLook.fit(CGSize(width: 40, height: 40), into: CGSize(width: 80, height: 80)),
                       CGSize(width: 40, height: 40), "меньшее не растягиваем")
        XCTAssertEqual(CarPlayCameraBannerLook.fit(CGSize(width: 40, height: 40), into: .zero),
                       CGSize(width: 40, height: 40), "предел не сообщён — желаемый")
    }
}
