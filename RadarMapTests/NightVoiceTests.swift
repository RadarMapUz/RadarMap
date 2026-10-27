//
//  NightVoiceTests.swift
//  RadarMapTests
//
//  Ночной голос (12.6): после заката фраза о камере короче — и ничего
//  больше. Не тише, не реже, без сирены там, где она была, и с сиреной там,
//  где она нужна.
//

import XCTest
@testable import RadarMap

final class NightVoiceTests: XCTestCase {

    private func plan(_ s: VoiceDirector.Situation, night: Bool) -> VoiceDirector.Plan {
        var s = s
        s.isNight = night
        return VoiceDirector.decide(s)
    }

    /// Трасса днём — полная фраза с лимитом; ночью — короткая.
    func testHighwayPhraseIsShortAtNight() {
        let s = VoiceDirector.Situation(mode: .smart, context: .highway, limitKmh: 100)
        XCTAssertEqual(plan(s, night: false), VoiceDirector.Plan(voice: .calm, speaksLimit: true))
        let night = plan(s, night: true)
        XCTAssertEqual(night.voice, .brief)
        XCTAssertTrue(night.isBrief)
        XCTAssertFalse(night.speaksLimit)
    }

    /// Город и так короткий — ночь ничего не меняет.
    func testCityStaysBrief() {
        let s = VoiceDirector.Situation(mode: .smart, context: .city, limitKmh: 60)
        XCTAssertEqual(plan(s, night: true), plan(s, night: false))
    }

    /// Превышение у камеры ночью звучит целиком: со скоростью, лимитом,
    /// сиреной и эскалацией — это штраф, а не болтовня.
    func testUrgentIsUntouchedAtNight() {
        let over = VoiceDirector.Situation(mode: .smart, context: .highway, overKmh: 25, limitKmh: 90)
        let sudden = VoiceDirector.Situation(mode: .smart, context: .city, isSudden: true, limitKmh: 60)
        for s in [over, sudden] {
            let night = plan(s, night: true)
            XCTAssertEqual(night, plan(s, night: false))
            XCTAssertEqual(night.voice, .urgent)
            XCTAssertTrue(night.beeps)
            XCTAssertTrue(night.escalates)
        }
    }

    /// Ночь только сокращает: если днём о камере говорим, ночью тоже говорим;
    /// сирена и эскалация — те же. Перебор всех ситуаций арбитра.
    func testNightNeverSilencesNorQuietens() {
        for mode in VoiceMode.allCases {
            for context in [AlertPolicy.Context.city, .highway] {
                for sudden in [false, true] {
                    for familiar in [false, true] {
                        for over in [nil, 3.0, 25.0] as [Double?] {
                            for crawling in [false, true] {
                                let s = VoiceDirector.Situation(mode: mode, context: context, isSudden: sudden,
                                                                isFamiliar: familiar, overKmh: over,
                                                                limitKmh: 60, isCrawling: crawling)
                                let day = plan(s, night: false)
                                let night = plan(s, night: true)
                                XCTAssertEqual(day.voice == .none, night.voice == .none,
                                               "ночь не должна ни глушить, ни включать голос: \(s)")
                                XCTAssertEqual(day.beeps, night.beeps, "тон тот же: \(s)")
                                XCTAssertEqual(day.escalates, night.escalates, "эскалация та же: \(s)")
                                XCTAssertEqual(day.postpone, night.postpone)
                            }
                        }
                    }
                }
            }
        }
    }
}
