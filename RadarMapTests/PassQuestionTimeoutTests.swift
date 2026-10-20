//
//  PassQuestionTimeoutTests.swift
//  RadarMapTests
//
//  Срок вопроса после проезда на экране (14.9): с VoiceOver — дольше, но
//  никогда не дольше жизни самого вопроса; смена VoiceOver посреди вопроса
//  считает от появления плашки, а не начинает срок заново.
//

import XCTest
@testable import RadarMap

final class PassQuestionTimeoutTests: XCTestCase {

    func testSightedKeepsTwentySeconds() {
        XCTAssertEqual(PassQuestionTimeout.seconds(voiceOver: false), AppConfig.mobileQuestionSeconds)
        XCTAssertEqual(PassQuestionTimeout.seconds(voiceOver: false), 20, "без VoiceOver срок прежний")
    }

    func testVoiceOverWaitsLonger() {
        XCTAssertEqual(PassQuestionTimeout.seconds(voiceOver: true), AppConfig.mobileQuestionVoiceOverSeconds)
        XCTAssertGreaterThan(PassQuestionTimeout.seconds(voiceOver: true),
                             PassQuestionTimeout.seconds(voiceOver: false))
    }

    func testNeverOutlivesTheQuestion() {
        for voiceOver in [false, true] {
            XCTAssertLessThanOrEqual(PassQuestionTimeout.seconds(voiceOver: voiceOver),
                                     AppConfig.mobileConfirmMaxAgeSeconds)
            XCTAssertGreaterThan(PassQuestionTimeout.seconds(voiceOver: voiceOver), 0,
                                 "плашка, которая уходит не появившись, — тот же пропавший вопрос")
        }
    }

    func testRemainingCountsFromAppearance() {
        let long = PassQuestionTimeout.seconds(voiceOver: true)
        // Только что появилась — весь срок.
        XCTAssertEqual(PassQuestionTimeout.remaining(elapsed: 0, voiceOver: true), long)
        // VoiceOver включили на 15-й секунде — остаток длинного срока, не новый.
        XCTAssertEqual(PassQuestionTimeout.remaining(elapsed: 15, voiceOver: true), long - 15)
        // Выключили на 30-й — короткий срок уже вышел: уйти сразу.
        XCTAssertEqual(PassQuestionTimeout.remaining(elapsed: 30, voiceOver: false), 0)
        // Часы назад (шаг системного времени) не продлевают срок.
        XCTAssertEqual(PassQuestionTimeout.remaining(elapsed: -100, voiceOver: false),
                       PassQuestionTimeout.seconds(voiceOver: false))
    }
}
