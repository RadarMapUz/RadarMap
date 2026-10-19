//
//  CarPlayCameraBannerTests.swift
//  RadarMapTests
//
//  Баннер камеры в машине: расстояние есть в каждом варианте заголовка
//  (узкий экран берёт короткий), ограничение — первым в подзаголовке,
//  обновление — только когда цифра сменилась, и не чаще раза в секунду.
//

import XCTest
@testable import RadarMap

final class CarPlayCameraBannerTests: XCTestCase {

    private typealias T = CarPlayCameraBannerText

    func testEveryTitleVariantCarriesTheDistance() {
        let text = T.text(name: "Радар", kind: "Стационарный радар", distance: "300 м", limit: 60)
        XCTAssertEqual(text.titles.count, 3)
        for title in text.titles {
            XCTAssertTrue(title.contains("300 м"), "вариант «\(title)» без расстояния")
        }
        XCTAssertEqual(text.titles.last, "300 м", "самый короткий — одно расстояние")
    }

    func testLimitLeadsTheSubtitle() {
        let text = T.text(name: "Радар", kind: "Стационарный радар", distance: "300 м", limit: 60)
        XCTAssertTrue(text.subtitles.first?.contains("60") == true)
        XCTAssertTrue(text.subtitles.first?.contains("Стационарный радар") == true)
        XCTAssertEqual(text.subtitles.last, "Стационарный радар")
    }

    func testNoLimitMeansJustTheKind() {
        let text = T.text(name: "Тренога", kind: "Тренога", distance: "1,2 км", limit: nil)
        XCTAssertEqual(text.subtitles, ["Тренога"])
    }

    func testUpdatesOnlyOnANewNumberAndNotTooOften() {
        let a = T.text(name: "Камера", kind: "Стационарная камера", distance: "300 м", limit: nil)
        let b = T.text(name: "Камера", kind: "Стационарная камера", distance: "250 м", limit: nil)
        XCTAssertFalse(T.shouldUpdate(shown: a, new: a, sinceLast: 10, interval: 1), "та же цифра")
        XCTAssertFalse(T.shouldUpdate(shown: a, new: b, sinceLast: 0.4, interval: 1), "слишком часто")
        XCTAssertTrue(T.shouldUpdate(shown: a, new: b, sinceLast: 1.2, interval: 1))
        XCTAssertTrue(T.shouldUpdate(shown: nil, new: a, sinceLast: 5, interval: 1))
    }

    /// Мигание тревоги у той же камеры не снимает баннер; другая камера или
    /// долгая пропажа — снимают (аудит CarPlay 19.10).
    func testBannerSurvivesABriefDropoutOfTheSameCamera() {
        typealias T = CarPlayCameraBannerText
        XCTAssertTrue(T.keepsThroughDropout(sameCamera: true, lostFor: 0, grace: 2))
        XCTAssertTrue(T.keepsThroughDropout(sameCamera: true, lostFor: 1.9, grace: 2))
        XCTAssertFalse(T.keepsThroughDropout(sameCamera: true, lostFor: 2, grace: 2))
        XCTAssertFalse(T.keepsThroughDropout(sameCamera: false, lostFor: 0, grace: 2))
    }
}
