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

/// Звук, выбранный в машине, — атрибут поездки (ревью 20.10): выбор голоса
/// не включает молча сигналы, выход из машины возвращает «до машины» только
/// там, где с тех пор никто не трогал.
final class CarPlaySoundRestoreTests: XCTestCase {
    typealias Sound = CarPlaySoundChoice.Sound

    func testVoiceChoiceKeepsBeepsUnlessLeavingSilence() {
        let beepsOff = Sound(enabled: false, voice: .smart)
        XCTAssertEqual(CarPlaySoundChoice.applying(.all, to: beepsOff), Sound(enabled: false, voice: .always),
                       "сигналы выключены руками — голос их не включает")
        let silent = Sound(enabled: false, voice: .off)
        XCTAssertEqual(CarPlaySoundChoice.applying(.smart, to: silent), Sound(enabled: true, voice: .smart),
                       "из тишины — со звуком")
        XCTAssertEqual(CarPlaySoundChoice.applying(.beepOnly, to: beepsOff), Sound(enabled: true, voice: .off))
        XCTAssertEqual(CarPlaySoundChoice.applying(.silent, to: beepsOff), Sound(enabled: false, voice: .off))
    }

    func testLeavingTheCarRestoresOnlyUntouched() {
        let before = Sound(enabled: true, voice: .always)
        let carSet = Sound(enabled: true, voice: .off)   // «Только сигнал» для спящего пассажира
        XCTAssertEqual(CarPlaySoundChoice.restoring(before: before, carSet: carSet, current: carSet), before)
        // На светофоре выбрали «Умно» на телефоне — это осознанный выбор.
        let touched = Sound(enabled: true, voice: .smart)
        XCTAssertEqual(CarPlaySoundChoice.restoring(before: before, carSet: carSet, current: touched), touched)
        // Тишина прежней кнопки (до 20.10): «поставленное» — тишина.
        let legacySet = Sound(enabled: false, voice: .off)
        XCTAssertEqual(CarPlaySoundChoice.restoring(before: before, carSet: legacySet, current: legacySet), before)
    }

    /// Падение или выгрузка в машине не присылают didDisconnect: метка «машина
    /// меняла звук» переживает процесс, и старт обязан её отработать.
    @MainActor
    func testProcessDeathInTheCarDoesNotLeaveThePhoneSilent() {
        let settings = AppSettings()
        let keep = (settings.soundEnabled, settings.voiceMode)
        defer {
            settings.soundEnabled = keep.0
            settings.voiceMode = keep.1
            Storage.set(false, for: .carPlayMuted)
        }
        Storage.set(true, for: .carPlaySoundBeforeMute)
        Storage.set(VoiceMode.always.rawValue, for: .carPlayVoiceBeforeMute)
        Storage.set(false, for: .carPlaySoundSet)
        Storage.set(VoiceMode.off.rawValue, for: .carPlayVoiceSet)
        Storage.set(true, for: .carPlayMuted)
        settings.soundEnabled = false
        settings.voiceMode = .off

        CarPlaySoundChoice.restoreAfterCar(settings: settings)

        XCTAssertTrue(settings.soundEnabled)
        XCTAssertEqual(settings.voiceMode, .always)
        XCTAssertFalse(Storage.bool(.carPlayMuted))
    }

    /// Без метки старт ничего не трогает: тишина, выбранная на телефоне, остаётся.
    @MainActor
    func testStartWithoutTheCarMarkKeepsAPhoneChoice() {
        let settings = AppSettings()
        let keep = (settings.soundEnabled, settings.voiceMode)
        defer {
            settings.soundEnabled = keep.0
            settings.voiceMode = keep.1
        }
        Storage.set(false, for: .carPlayMuted)
        settings.soundEnabled = false
        settings.voiceMode = .off

        CarPlaySoundChoice.restoreAfterCar(settings: settings)

        XCTAssertFalse(settings.soundEnabled)
        XCTAssertEqual(settings.voiceMode, .off)
    }
}
