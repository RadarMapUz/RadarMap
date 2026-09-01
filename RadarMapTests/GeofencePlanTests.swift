//
//  GeofencePlanTests.swift
//  RadarMapTests
//
//  Проверка «а изменилось ли что-нибудь» перед пересборкой геозон.
//
//  Пересборка стоит сорока синхронных походов в locationd на главном потоке.
//  Пока её звал только ретайл раз в 300–1500 м, цена была терпимой. С хуком
//  доставки отметок её зовёт каждый опрос сервера, принёсший изменение, —
//  а изменением считается и чужая отметка за пять километров, которая в
//  двадцатку ближайших не попадает. Без этой проверки краудсорс оплачивался
//  бы батареей стоящего телефона.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class GeofencePlanTests: XCTestCase {

    private func camera(_ id: Int, lat: Double = 41.31, lon: Double = 69.25) -> Camera {
        Camera(id: id, region: "", city: "", location: "", lat: lat, lon: lon,
               type: "Стационар радар", violations: [], needsReview: nil, mobileConfirmed: nil)
    }

    func testEmptyPlanAlwaysNeedsArming() {
        let plan = GeofencePlan()
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.needsRearm(cameras: [camera(1)], radius: 400))
    }

    func testSameSetIsNotRearmed() {
        var plan = GeofencePlan()
        let set = [camera(1), camera(2, lat: 41.4)]
        plan.arm(cameras: set, radius: 400)
        XCTAssertFalse(plan.needsRearm(cameras: set, radius: 400))
    }

    func testOrderDoesNotMatter() {
        // `nearest` отсортирован по расстоянию, и на ходу те же двадцать камер
        // меняются местами каждый фикс. Для геозон порядок не значит ничего.
        var plan = GeofencePlan()
        plan.arm(cameras: [camera(1), camera(2, lat: 41.4)], radius: 400)
        XCTAssertFalse(plan.needsRearm(cameras: [camera(2, lat: 41.4), camera(1)], radius: 400))
    }

    func testDifferentCameraNeedsRearm() {
        var plan = GeofencePlan()
        plan.arm(cameras: [camera(1)], radius: 400)
        XCTAssertTrue(plan.needsRearm(cameras: [camera(3)], radius: 400))
    }

    func testMovedCameraNeedsRearm() {
        // Отметку могут уточнить (amend): id тот же, координата другая —
        // а геозона стоит вокруг координаты.
        var plan = GeofencePlan()
        plan.arm(cameras: [camera(1, lat: 41.31)], radius: 400)
        XCTAssertTrue(plan.needsRearm(cameras: [camera(1, lat: 41.35)], radius: 400))
    }

    func testChangedRadiusNeedsRearm() {
        var plan = GeofencePlan()
        plan.arm(cameras: [camera(1)], radius: 400)
        XCTAssertTrue(plan.needsRearm(cameras: [camera(1)], radius: 600))
    }

    func testDisarmForgetsEverything() {
        var plan = GeofencePlan()
        plan.arm(cameras: [camera(1)], radius: 400)
        plan.disarm()
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.needsRearm(cameras: [camera(1)], radius: 400))
    }
}
