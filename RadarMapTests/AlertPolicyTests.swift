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

    /// Короткая обёртка: почти во всех кейсах тумблер «только при превышении» выключен.
    private func decide(mode: AlertMode = .auto, detected: AlertPolicy.Context,
                        sudden: Bool = false, over: Bool = false,
                        onlyWhenOver: Bool = false) -> AlertPolicy.Decision {
        AlertPolicy.decision(mode: mode, detected: detected, isSuddenCamera: sudden,
                             isOverspeeding: over, voiceOnlyWhenOverspeeding: onlyWhenOver)
    }

    func testCitySilentInLimit() {
        let decision = decide(detected: .city)
        XCTAssertEqual(decision.style, .silent, "город, едем в лимите — тихо")
        XCTAssertFalse(decision.beeps)
        XCTAssertFalse(decision.voice)
    }

    /// Главное изменение: трасса в лимите больше не кричит, а спокойно сообщает.
    func testHighwayIsCalmNotUrgentInLimit() {
        let decision = decide(detected: .highway)
        XCTAssertEqual(decision.style, .calm)
        XCTAssertTrue(decision.voice, "на трассе о камере говорим")
        XCTAssertFalse(decision.beeps, "но без сирены — мы не превышаем")
        XCTAssertFalse(decision.escalates, "и без эскалации по мере приближения")
    }

    func testOverspeedingIsUrgentEverywhere() {
        for context in [AlertPolicy.Context.city, .highway] {
            let decision = decide(detected: context, over: true)
            XCTAssertEqual(decision.style, .urgent, "превышение у камеры — срочно (\(context))")
            XCTAssertTrue(decision.beeps)
            XCTAssertTrue(decision.escalates)
        }
    }

    func testSuddenCameraIsUrgentEvenInSilentCity() {
        let decision = decide(detected: .city, sudden: true)
        XCTAssertEqual(decision.style, .urgent, "передвижной внезапен — о нём всегда громко")
    }

    /// Тумблер полной тишины не должен заглушать то, ради чего приложение и нужно.
    func testVoiceOnlyWhenOverspeedingStillShoutsAboutSuddenAndOverspeed() {
        XCTAssertEqual(decide(detected: .highway, onlyWhenOver: true).style, .silent,
                       "тумблер включён, в лимите — полная тишина даже на трассе")
        XCTAssertEqual(decide(detected: .city, sudden: true, onlyWhenOver: true).style, .urgent,
                       "передвижной радар тумблером не заглушить")
        XCTAssertEqual(decide(detected: .city, over: true, onlyWhenOver: true).style, .urgent,
                       "превышение тумблером не заглушить")
    }

    func testManualOverrideBeatsDetector() {
        XCTAssertEqual(decide(mode: .highway, detected: .city).style, .calm,
                       "ручная «Трасса» сильнее детектора")
        XCTAssertEqual(decide(mode: .city, detected: .highway).style, .silent,
                       "ручной «Город» сильнее детектора")
    }
}
