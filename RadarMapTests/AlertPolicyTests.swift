//
//  AlertPolicyTests.swift
//  RadarMapTests
//
//  Умный режим оповещений: детектор город/трасса и матрица решений.
//

import XCTest
@testable import RadarMap

final class AlertPolicyTests: XCTestCase {

    // MARK: - Детектор

    func testHighwayByLimitAndSpeed() {
        var detector = AlertPolicy.Detector()
        let start = Date()
        // Устойчивая трасса: лимит 100, скорость 95, камер нет.
        for tick in 0..<400 {
            detector.update(roadLimitKmh: 100, camerasWithin3km: 0,
                            speedKmh: 95, now: start.addingTimeInterval(Double(tick)))
        }
        XCTAssertEqual(detector.context, .highway)
    }

    func testCityByDensityAndLimit() {
        var detector = AlertPolicy.Detector()
        let start = Date()
        for tick in 0..<400 {
            detector.update(roadLimitKmh: 60, camerasWithin3km: 12,
                            speedKmh: 40, now: start.addingTimeInterval(Double(tick)))
        }
        XCTAssertEqual(detector.context, .city)
    }

    func testTrafficLightOnHighwayDoesNotFlipToCity() {
        var detector = AlertPolicy.Detector()
        let start = Date()
        for tick in 0..<400 {   // едем по трассе
            detector.update(roadLimitKmh: 100, camerasWithin3km: 0,
                            speedKmh: 95, now: start.addingTimeInterval(Double(tick)))
        }
        XCTAssertEqual(detector.context, .highway)
        // Минутная остановка (пост/светофор): лимита нет, скорость 0 — гистерезис
        // держит трассу (переключение не раньше alertContextSwitchSeconds).
        for tick in 400..<460 {
            detector.update(roadLimitKmh: nil, camerasWithin3km: 0,
                            speedKmh: 0, now: start.addingTimeInterval(Double(tick)))
        }
        XCTAssertEqual(detector.context, .highway, "минутная остановка — ещё не город")
    }

    func testEnteringCityAfterHighwaySwitchesEventually() {
        var detector = AlertPolicy.Detector()
        let start = Date()
        for tick in 0..<400 {
            detector.update(roadLimitKmh: 100, camerasWithin3km: 0,
                            speedKmh: 95, now: start.addingTimeInterval(Double(tick)))
        }
        // Въехали в город: лимит 50, плотная сетка камер, городской ритм.
        for tick in 400..<1200 {
            detector.update(roadLimitKmh: 50, camerasWithin3km: 10,
                            speedKmh: 35, now: start.addingTimeInterval(Double(tick)))
        }
        XCTAssertEqual(detector.context, .city)
    }

    // MARK: - Матрица решений

    func testCityQuietInLimit() {
        let decision = AlertPolicy.decision(mode: .auto, detected: .city,
                                            isSuddenCamera: false, isOverspeeding: false)
        XCTAssertFalse(decision.sound, "город, едем в лимите — тихо")
        XCTAssertFalse(decision.voice)
    }

    func testCitySpeaksWhenOverspeeding() {
        let decision = AlertPolicy.decision(mode: .auto, detected: .city,
                                            isSuddenCamera: false, isOverspeeding: true)
        XCTAssertTrue(decision.voice, "превышение у камеры — говорим и в городе")
    }

    func testCitySpeaksAboutMobileRadar() {
        let decision = AlertPolicy.decision(mode: .auto, detected: .city,
                                            isSuddenCamera: true, isOverspeeding: false)
        XCTAssertTrue(decision.voice, "передвижной — внезапный, о нём всегда")
    }

    func testHighwayAlwaysFull() {
        let decision = AlertPolicy.decision(mode: .auto, detected: .highway,
                                            isSuddenCamera: false, isOverspeeding: false)
        XCTAssertTrue(decision.sound)
        XCTAssertTrue(decision.voice)
    }

    func testManualOverrideBeatsDetector() {
        let decision = AlertPolicy.decision(mode: .highway, detected: .city,
                                            isSuddenCamera: false, isOverspeeding: false)
        XCTAssertTrue(decision.voice, "ручная «Трасса» сильнее детектора")
        let quiet = AlertPolicy.decision(mode: .city, detected: .highway,
                                         isSuddenCamera: false, isOverspeeding: false)
        XCTAssertFalse(quiet.voice, "ручной «Город» сильнее детектора")
    }
}
