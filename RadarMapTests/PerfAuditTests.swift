//
//  PerfAuditTests.swift
//  RadarMapTests
//
//  Правила из аудита производительности 11.10 (docs/perf_audit_2026-10-11.md).
//  Флаги близости камеры стали хранимыми — их правило вынесено в чистые
//  функции, и оно обязано остаться прежним: от него зависит, накроет ли
//  экран предупреждение. Граница частых обновлений Live Activity теперь
//  следует за зоной оповещения, а не стоит на 1,2 км.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class PerfAuditTests: XCTestCase {

    // MARK: - Предупреждение о камере

    private var moving: Double { AppConfig.directionalMinSpeedKmh + 10 }

    func testApproachingInsideRadiusWhileMoving() {
        XCTAssertTrue(LocationService.isApproaching(distance: 200, speedKmh: moving,
                                                    radius: 300, signalStale: false))
        XCTAssertTrue(LocationService.isApproaching(distance: 300, speedKmh: moving,
                                                    radius: 300, signalStale: false),
                      "граница радиуса — уже предупреждение")
    }

    func testNotApproachingOutsideRadius() {
        XCTAssertFalse(LocationService.isApproaching(distance: 301, speedKmh: moving,
                                                     radius: 300, signalStale: false))
        XCTAssertFalse(LocationService.isApproaching(distance: nil, speedKmh: moving,
                                                     radius: 300, signalStale: false))
    }

    /// Стоим — экран не накрываем; без свежего фикса — тоже: расстояние на
    /// экране уже не правда.
    func testStandingOrStaleSignalHidesTheWarning() {
        XCTAssertFalse(LocationService.isApproaching(
            distance: 100, speedKmh: AppConfig.directionalMinSpeedKmh - 1,
            radius: 300, signalStale: false))
        XCTAssertFalse(LocationService.isApproaching(distance: 100, speedKmh: moving,
                                                     radius: 300, signalStale: true))
    }

    func testAlertLevelLadder() {
        XCTAssertEqual(LocationService.alertLevel(distance: 80, radius: 300, tripActive: true), 3)
        XCTAssertEqual(LocationService.alertLevel(distance: 150, radius: 300, tripActive: true), 2)
        XCTAssertEqual(LocationService.alertLevel(distance: 290, radius: 300, tripActive: true), 1)
        XCTAssertEqual(LocationService.alertLevel(distance: 400, radius: 300, tripActive: true), 0)
        XCTAssertEqual(LocationService.alertLevel(distance: 80, radius: 300, tripActive: false), 0,
                       "уровень для часов и машины — только в поездке")
        XCTAssertEqual(LocationService.alertLevel(distance: nil, radius: 300, tripActive: true), 0)
    }

    // MARK: - Live Activity

    /// В городе (радиус ~300 м) частая ступень — не на 1,2 км, а около
    /// зоны оповещения; на трассе граница не уже прежней.
    func testLiveActivityNearZoneFollowsTheAlertRadius() {
        let city = LiveActivityService.nearZone(alertRadius: 300)
        XCTAssertLessThan(city, AppConfig.liveActivityNearMeters)
        XCTAssertGreaterThanOrEqual(city, 300, "зона оповещения целиком в частой ступени")
        XCTAssertEqual(LiveActivityService.nearZone(alertRadius: 100),
                       AppConfig.liveActivityMinNearMeters)
        XCTAssertEqual(LiveActivityService.nearZone(alertRadius: 2000),
                       AppConfig.liveActivityNearMeters)
    }

    func testLiveActivityStepsOutsideTheZone() {
        var state = CameraActivityAttributes.ContentState(
            nearestTitle: "Камера", nearestSymbol: "camera", distanceMeters: 812)
        let far = LiveActivityService.quantize(state, nearMeters: 400)
        XCTAssertEqual(far.distanceMeters, 800, "вне зоны — шаг 200 м")
        XCTAssertEqual(LiveActivityService.interval(for: far, nearMeters: 400),
                       AppConfig.liveActivityFarInterval)
        state.distanceMeters = 312
        let near = LiveActivityService.quantize(state, nearMeters: 400)
        XCTAssertEqual(near.distanceMeters, 300, "в зоне — шаг 50 м")
    }

    /// Течение времени — не повод будить плашку: полосу приближения ведёт
    /// система по `arrivesAt`. Повод — камера, ступень дистанции или
    /// заметная смена скорости (аудит энергии 19.10).
    func testLiveActivityIsNotWokenByTimeAlone() {
        let t0 = Date(timeIntervalSince1970: 1_760_900_000)
        let sent = CameraActivityAttributes.ContentState(
            nearestTitle: "Камера", nearestSymbol: "camera", distanceMeters: 300,
            arrivesAt: t0.addingTimeInterval(20), since: t0)
        var same = sent
        same.since = t0.addingTimeInterval(4)
        same.arrivesAt = t0.addingTimeInterval(20.5)
        XCTAssertFalse(LiveActivityService.differs(same, from: sent, now: t0.addingTimeInterval(4)))
        var slower = same
        slower.arrivesAt = t0.addingTimeInterval(40)   // встали в пробку перед камерой
        XCTAssertTrue(LiveActivityService.differs(slower, from: sent, now: t0.addingTimeInterval(4)))
        var stopped = same
        stopped.arrivesAt = nil
        XCTAssertTrue(LiveActivityService.differs(stopped, from: sent, now: t0.addingTimeInterval(4)))
        var nextStep = same
        nextStep.distanceMeters = 250
        XCTAssertTrue(LiveActivityService.differs(nextStep, from: sent, now: t0.addingTimeInterval(4)))
        XCTAssertNil(LiveActivityService.arrival(distance: 300, speedKmh: 2, now: t0), "стоим — полоса не едет")
        XCTAssertEqual(LiveActivityService.arrival(distance: 300, speedKmh: 54, now: t0), t0.addingTimeInterval(20))
    }
}
