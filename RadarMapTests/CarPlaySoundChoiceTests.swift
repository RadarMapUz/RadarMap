//
//  CarPlaySoundChoiceTests.swift
//  RadarMapTests
//
//  Звук в машине (10.1): четыре строки — те же настройки, что на телефоне,
//  без своего состояния. Что выбрано — читается из настроек, выбор ставит
//  настройки так, что читается обратно тем же.
//

import XCTest
@testable import RadarMap

final class CarPlaySoundChoiceTests: XCTestCase {
    func testCurrentIsReadFromSettings() {
        XCTAssertEqual(CarPlaySoundChoice.current(soundEnabled: true, voiceMode: .always), .all)
        XCTAssertEqual(CarPlaySoundChoice.current(soundEnabled: true, voiceMode: .smart), .smart)
        XCTAssertEqual(CarPlaySoundChoice.current(soundEnabled: true, voiceMode: .off), .beepOnly)
        XCTAssertEqual(CarPlaySoundChoice.current(soundEnabled: false, voiceMode: .off), .silent)
        // Сигналы выключены руками, голос есть — это голосовой режим, не тишина.
        XCTAssertEqual(CarPlaySoundChoice.current(soundEnabled: false, voiceMode: .smart), .smart)
    }

    func testChoiceRoundTrips() {
        for choice in CarPlaySoundChoice.allCases {
            XCTAssertEqual(CarPlaySoundChoice.current(soundEnabled: choice.soundEnabled,
                                                      voiceMode: choice.voiceMode), choice)
        }
    }

    /// Каждый выбор виден по значку: промах слепого тапа заметен.
    func testEveryChoiceHasItsOwnGlyph() {
        let symbols = Set(CarPlaySoundChoice.allCases.map(\.symbol))
        XCTAssertEqual(symbols.count, CarPlaySoundChoice.allCases.count)
    }
}
