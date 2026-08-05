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
    /// По умолчанию проверяем «Обо всех» — там сохраняется прежняя матрица
    /// город/трасса. Режим «Умно» (боевой дефолт) проверяется отдельно.
    private func decide(voice: VoiceMode = .always,
                        mode: AlertMode = .auto, detected: AlertPolicy.Context,
                        sudden: Bool = false, over: Bool = false,
                        crawling: Bool = false) -> AlertPolicy.Decision {
        AlertPolicy.decision(voice: voice, mode: mode, detected: detected,
                             isSuddenCamera: sudden, isOverspeeding: over,
                             isCrawling: crawling)
    }

    /// Раньше город был полной тишиной, и это читалось как поломка: камера на
    /// карте есть, а голоса нет. Теперь о камере говорим и в городе — коротко.
    func testCitySpeaksBrieflyInLimit() {
        let decision = decide(detected: .city)
        XCTAssertEqual(decision.style, .brief, "город, едем в лимите — короткая фраза")
        XCTAssertTrue(decision.voice, "о камере в городе тоже говорим")
        XCTAssertTrue(decision.isBrief, "но в два слова, а не полной фразой")
        XCTAssertFalse(decision.beeps, "без сирены — мы не превышаем")
        XCTAssertFalse(decision.escalates)
    }

    /// В пробке и на светофоре камера в 300 м впереди — не решение водителя.
    func testCrawlingIsSilent() {
        XCTAssertEqual(decide(detected: .city, crawling: true).style, .silent)
        XCTAssertEqual(decide(detected: .highway, crawling: true).style, .silent,
                       "пробка на трассе — та же пробка")
        XCTAssertEqual(decide(detected: .city, sudden: true, crawling: true).style, .urgent,
                       "тренога на обочине важна и в пробке")
        XCTAssertEqual(decide(detected: .city, over: true, crawling: true).style, .urgent,
                       "превышение важнее любой тишины")
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

    // MARK: - «Умно» — боевой режим по умолчанию

    /// Главная жалоба: в городе фраза на каждую камеру звучала поверх музыки.
    /// В «Умно» голоса нет, пока едем в лимите, — камеру показывает панель.
    func testSmartIsSilentInLimitEverywhere() {
        for context in [AlertPolicy.Context.city, .highway] {
            let decision = decide(voice: .smart, detected: context)
            XCTAssertEqual(decision.style, .silent, "в лимите молчим (\(context))")
            XCTAssertFalse(decision.voice, "музыка не должна нырять на каждую камеру")
            XCTAssertFalse(decision.beeps)
        }
    }

    /// Но ради чего приложение и нужно — говорит.
    func testSmartSpeaksOnOverspeedAndSuddenPoints() {
        XCTAssertEqual(decide(voice: .smart, detected: .highway, over: true).style, .urgent,
                       "превысил на трассе — сказать про камеру")
        XCTAssertEqual(decide(voice: .smart, detected: .city, over: true).style, .urgent,
                       "превысил в городе — тоже сказать")
        XCTAssertEqual(decide(voice: .smart, detected: .city, sudden: true).style, .urgent,
                       "передвижной радар нельзя знать заранее — говорим всегда")
    }

    /// «Молча» — это действительно молча: ни слова, что бы ни случилось.
    func testOffIsSilentEvenOnOverspeed() {
        XCTAssertEqual(decide(voice: .off, detected: .highway, over: true).style, .silent)
        XCTAssertEqual(decide(voice: .off, detected: .city, sudden: true).style, .silent)
        XCTAssertFalse(decide(voice: .off, detected: .city, over: true).voice,
                       "пользователь попросил тишину — она безусловная")
    }

    func testManualOverrideBeatsDetector() {
        XCTAssertEqual(decide(mode: .highway, detected: .city).style, .calm,
                       "ручная «Трасса» сильнее детектора")
        XCTAssertEqual(decide(mode: .city, detected: .highway).style, .brief,
                       "ручной «Город» сильнее детектора")
    }
}
