//
//  OverspeedVoiceTests.swift
//  RadarMapTests
//
//  Голос о превышении: «У камер» говорит только при камере впереди по нашей
//  дороге. Настройка родилась из реальной поездки — честная фраза по лимиту
//  без камеры воспринимается как ворчание.
//

import XCTest
@testable import RadarMap

final class OverspeedVoiceTests: XCTestCase {

    func testAlwaysSpeaksRegardlessOfCameras() {
        XCTAssertTrue(OverspeedVoice.always.allows(cameraAhead: true))
        XCTAssertTrue(OverspeedVoice.always.allows(cameraAhead: false))
    }

    func testNearCamerasSpeaksOnlyWithCameraAhead() {
        XCTAssertTrue(OverspeedVoice.nearCameras.allows(cameraAhead: true))
        XCTAssertFalse(OverspeedVoice.nearCameras.allows(cameraAhead: false))
    }

    func testOffNeverSpeaks() {
        XCTAssertFalse(OverspeedVoice.off.allows(cameraAhead: true))
        XCTAssertFalse(OverspeedVoice.off.allows(cameraAhead: false))
    }

    /// rawValue — формат хранения в UserDefaults: переименование кейса молча
    /// сбросило бы выбор пользователя на дефолт.
    func testRawValuesAreStable() {
        XCTAssertEqual(OverspeedVoice.always.rawValue, "always")
        XCTAssertEqual(OverspeedVoice.nearCameras.rawValue, "nearCameras")
        XCTAssertEqual(OverspeedVoice.off.rawValue, "off")
        // Незнакомое значение на диске → дефолт «всегда» (текущее поведение).
        XCTAssertNil(OverspeedVoice(rawValue: "мусор"))
    }
}
