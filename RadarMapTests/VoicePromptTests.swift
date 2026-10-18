//
//  VoicePromptTests.swift
//  RadarMapTests
//
//  Как звучать подсказке: Siri слушает — тишина, звонок — короткий тон,
//  иначе — фраза. До 18.10 фраза о камере звучала поверх разговора в машине.
//

import AVFoundation
import XCTest
@testable import RadarMap

final class VoicePromptTests: XCTestCase {

    func testPhoneCallGetsAToneNotAPhrase() {
        XCTAssertEqual(VoicePrompt.mode(for: .short), .tone)
    }

    func testSiriListeningGetsSilence() {
        XCTAssertEqual(VoicePrompt.mode(for: .none), .silent)
    }

    func testNormallyTheFullPhrase() {
        XCTAssertEqual(VoicePrompt.mode(for: .normal), .speech)
    }
}
