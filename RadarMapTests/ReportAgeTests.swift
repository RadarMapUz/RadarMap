//
//  ReportAgeTests.swift
//  RadarMapTests
//
//  Тренога — это «сейчас» (владелец, 02.11): возраст отметки в карточке и в
//  баннере машины, истёкшая исчезает по своему сроку, «часто ставят» не
//  звучит как присутствие, своя свежая точка — без «?», выбор в машине.
//

import XCTest
@testable import RadarMap

final class ReportAgeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCardSaysMinutesAgo() {
        XCTAssertEqual(ReportAge.card(created: now.addingTimeInterval(-12 * 60 - 20), confirmed: false, now: now),
                       "Отмечена 12 мин назад")
        XCTAssertEqual(ReportAge.card(created: now.addingTimeInterval(-20), confirmed: false, now: now),
                       "Отмечена только что")
    }

    func testConfirmedSaysSinceWhen() {
        let created = now.addingTimeInterval(-40 * 60)
        XCTAssertEqual(ReportAge.card(created: created, confirmed: true, now: now),
                       "Подтверждена · с \(NumberFormat.clock(created))")
    }

    func testOldUnconfirmedSaysClock() {
        let created = now.addingTimeInterval(-70 * 60)
        XCTAssertEqual(ReportAge.card(created: created, confirmed: false, now: now),
                       "Отмечена в \(NumberFormat.clock(created))")
    }

    /// Старый сервер шлёт эпоху — не «55 лет назад», а молчание.
    func testUnknownTimeSaysNothing() {
        XCTAssertNil(ReportAge.card(created: Date(timeIntervalSince1970: 0), confirmed: false, now: now))
        XCTAssertNil(ReportAge.banner(created: nil, confirmed: true, now: now))
    }

    /// Часы чуть спешат — возраст не уходит в минус.
    func testFutureCreatedIsZero() {
        XCTAssertEqual(ReportAge.minutes(since: now.addingTimeInterval(30), now: now), 0)
    }

    /// Баннер машины: подзаголовок с возрастом для отметки водителей,
    /// заголовок с расстоянием тот же; у камеры базы — прежний подзаголовок.
    func testCarBannerCarriesAgeOnlyForDriverReports() {
        let age = ReportAge.banner(created: now.addingTimeInterval(-12 * 60), confirmed: false, now: now)
        XCTAssertEqual(age, ["Отметка водителей · 12 мин", "12 мин назад"])
        let driver = CarPlayCameraBannerText.text(name: "Тренога", kind: "Тренога", distance: "300 м",
                                                  limit: 60, age: age)
        let base = CarPlayCameraBannerText.text(name: "Тренога", kind: "Тренога", distance: "300 м", limit: 60)
        XCTAssertEqual(driver.titles, base.titles)
        XCTAssertEqual(driver.subtitles, age)
        XCTAssertFalse(base.subtitles.contains { $0.contains("мин") })
    }

    // MARK: - Срок и «часто ставят»

    func testNextExpiryIsTheNearestAndNeverInThePast() {
        let soon = now.addingTimeInterval(90)
        XCTAssertEqual(MobileCameraService.nextExpiry([now.addingTimeInterval(600), soon], now: now), soon)
        XCTAssertEqual(MobileCameraService.nextExpiry([now.addingTimeInterval(-5)], now: now), now,
                       "уже истекшая — снять сразу")
        XCTAssertNil(MobileCameraService.nextExpiry([], now: now))
    }

    func testHotspotVoiceHasNoTimeOfDay() {
        for peak in [-1, 0, 1, 2, 3] {
            let spot = TripodHotspots.Spot(lat: 41.3, lon: 69.2, n: 5, days: 3, peak: peak)
            XCTAssertEqual(HotspotAlert.phrase(for: spot), "Здесь часто ставят треногу")
        }
    }

    // MARK: - Своя точка и машина

    func testOwnFreshReportIsNotAGhost() {
        XCTAssertTrue(CameraMarkerLook.isGhost(unconfirmed: true, own: false))
        XCTAssertFalse(CameraMarkerLook.isGhost(unconfirmed: true, own: true))
        XCTAssertFalse(CameraMarkerLook.isGhost(unconfirmed: false, own: false))
    }

    func testCarChoiceLayout() {
        XCTAssertEqual(CarPlayReportChoice.layout(maximumActions: 3), .inBanner([.tripod, .post, .accident]))
        XCTAssertEqual(CarPlayReportChoice.layout(maximumActions: 2), .viaGrid, "типов больше, чем кнопок")
        XCTAssertEqual(CarPlayReportChoice.layout(maximumActions: nil), .viaGrid, "до iOS 27")
        XCTAssertTrue(CarPlayReportChoice.showsUndoBanner(remaining: 6))
        XCTAssertFalse(CarPlayReportChoice.showsUndoBanner(remaining: 4), "системный минимум баннера — 5 с")
    }

    /// Слово на диске 40 pt: мельче 9 pt — диск со значком без слова.
    func testCarDiscDropsAnUnreadableWord() {
        for title in ["Отметить", "Belgilash"] {
            let size = CarPlayReportImage.fittedPoints(
                CarPlayReportImage.titleAttributes(title, diameter: AppConfig.carPlayReportButtonPoints))
            XCTAssertFalse(CarPlayReportChoice.discShowsTitle(fittedPoints: size), "\(title): \(size) pt")
        }
        XCTAssertTrue(CarPlayReportChoice.discShowsTitle(fittedPoints: 9))
    }

    /// Названия в баннере машины влезают в CPAlertAction (≤ 10 знаков).
    func testCarActionTitlesFit() {
        for kind in ReportKind.chosenOnTheGo {
            XCTAssertLessThanOrEqual(ReportWords.title(kind).count, 10, ReportWords.title(kind))
        }
        XCTAssertLessThanOrEqual(ReportWords.choosePrompt.count, 28)
        XCTAssertLessThanOrEqual(ReportWords.choosePromptShort.count, 16)
    }
}
