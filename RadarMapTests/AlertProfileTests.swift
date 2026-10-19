//
//  AlertProfileTests.swift
//  RadarMapTests
//
//  Профиль оповещений — фасад над старыми настройками. Главное, что здесь
//  проверяется: переезд со старой версии не меняет поведение молча. Человек,
//  который однажды настроил приложение под себя, не должен обнаружить, что
//  обновление решило за него.
//

import XCTest
@testable import RadarMap

final class AlertProfileTests: XCTestCase {

    func testProfilesApplyExpectedSettings() {
        XCTAssertEqual(AlertProfile.auto.applied?.voice, .smart)
        XCTAssertEqual(AlertProfile.auto.applied?.mode, .auto)
        XCTAssertEqual(AlertProfile.city.applied?.mode, .city)
        XCTAssertEqual(AlertProfile.highway.applied?.mode, .highway)
        XCTAssertEqual(AlertProfile.quiet.applied?.voice, .off)
        XCTAssertNotNil(AlertProfile.quiet.applied)
        XCTAssertNil(AlertProfile.quiet.applied?.mode, "«Тихий» режим контекста не трогает")
        XCTAssertNil(AlertProfile.custom.applied, "«Свой» ничего не переписывает")
    }

    func testMigrationKeepsWhatUserChose() {
        // Готовые сочетания узнаются как профили.
        XCTAssertEqual(AlertProfile.matching(voice: .smart, mode: .auto), .auto)
        XCTAssertEqual(AlertProfile.matching(voice: .smart, mode: .city), .city)
        XCTAssertEqual(AlertProfile.matching(voice: .smart, mode: .highway), .highway)
        // «Молча» — это «Тихий» при любом режиме контекста.
        XCTAssertEqual(AlertProfile.matching(voice: .off, mode: .highway), .quiet)
    }

    func testUnusualCombinationBecomesCustomRatherThanBeingReset() {
        // «Обо всех» + город — осознанный выбор, и он обязан пережить обновление.
        XCTAssertEqual(AlertProfile.matching(voice: .always, mode: .city), .custom)
        XCTAssertEqual(AlertProfile.matching(voice: .always, mode: .auto), .custom)
    }

    func testEveryProfileRoundTripsThroughItsSettings() {
        // Профиль → настройки → профиль: цикл не должен уводить в сторону,
        // иначе экран настроек начнёт «прыгать» при каждом открытии.
        for profile in AlertProfile.allCases where profile != .custom {
            guard let applied = profile.applied else { continue }
            XCTAssertEqual(AlertProfile.matching(voice: applied.voice, mode: applied.mode ?? .city),
                           profile, "\(profile.rawValue) не воспроизводится из своих же настроек")
        }
    }

    func testEveryProfileHasTitleAndDetail() {
        for profile in AlertProfile.allCases {
            XCTAssertFalse(profile.title.isEmpty)
            XCTAssertFalse(profile.detail.isEmpty, "профиль без объяснения выбирают наугад")
        }
    }

    /// Голос поменяли мимо профиля (глушилка, чипы на карте, кнопка в машине):
    /// профиль следует за настройками, а не врёт «Авто» над молчащим
    /// приложением (аудит 19.10).
    func testProfileFollowsVoiceChangedElsewhere() {
        typealias P = AlertProfile
        XCTAssertEqual(P.following(.auto, voice: .off, mode: .auto), .quiet, "глушилка")
        XCTAssertEqual(P.following(.quiet, voice: .smart, mode: .auto), .auto, "звук вернули")
        XCTAssertEqual(P.following(.city, voice: .off, mode: .city), .quiet)
        XCTAssertEqual(P.following(.quiet, voice: .smart, mode: .city), .city, "глушилка туда-обратно")
        XCTAssertEqual(P.following(.auto, voice: .always, mode: .auto), .custom)
        // Совпадает с профилем — остаётся им.
        XCTAssertEqual(P.following(.highway, voice: .smart, mode: .highway), .highway)
        XCTAssertEqual(P.following(.quiet, voice: .off, mode: .highway), .quiet)
        // «Свой» не прыгает на готовый профиль посреди правки.
        XCTAssertEqual(P.following(.custom, voice: .smart, mode: .auto), .custom)
    }
}
