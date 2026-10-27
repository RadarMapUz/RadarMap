//
//  MobilePassQuestionTests.swift
//  RadarMapTests
//
//  «Пост убрали» одной кнопкой (12.7): вопрос после проезда — по типу
//  отметки, наблюдение — тем же MobilePassWatch.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class MobilePassQuestionTests: XCTestCase {

    /// Про пост ДПС — «Пост ещё стоит?» и «Пост убрали» одной кнопкой, а не
    /// «Радар ещё стоял?»: иначе честное «радара не было» уходило против
    /// поста, который стоит.
    func testPostGetsItsOwnQuestion() {
        let q = MobilePassWatch.question(for: .dpsPost)
        XCTAssertEqual(q.title, "Пост ещё стоит?")
        XCTAssertEqual(q.yes, "Стоит")
        XCTAssertEqual(q.no, "Пост убрали")
        XCTAssertFalse(q.title.contains("Радар"))
    }

    /// Радары и треноги — прежний вопрос, слово в слово.
    func testRadarsKeepTheOldQuestion() {
        for kind in [CameraType.mobileRadar, .tripod] {
            let q = MobilePassWatch.question(for: kind)
            XCTAssertEqual(q.title, "Радар ещё стоял?")
            XCTAssertEqual(q.yes, "Да")
            XCTAssertEqual(q.no, "Нет")
        }
    }

    /// «Стоит / Пост убрали» не помещаются рядом с вопросом на SE — ответы
    /// строкой ниже; «Да / Нет» остаются рядом, как были.
    func testLongAnswersGoBelowTheQuestion() {
        let post = MobilePassWatch.question(for: .dpsPost)
        XCTAssertTrue(PassQuestionCard.stacksAnswers(yes: post.yes, no: post.no, largeType: false))
        let radar = MobilePassWatch.question(for: .mobileRadar)
        XCTAssertFalse(PassQuestionCard.stacksAnswers(yes: radar.yes, no: radar.no, largeType: false))
        XCTAssertFalse(PassQuestionCard.stacksAnswers(yes: "Ha", no: "Yoʻq", largeType: false))
        XCTAssertTrue(PassQuestionCard.stacksAnswers(yes: "Да", no: "Нет", largeType: true))
    }

    /// ДТП — не радар и не пост.
    func testAccidentIsNotAskedAsRadar() {
        XCTAssertFalse(MobilePassWatch.question(for: .accident).title.contains("Радар"))
    }

    /// Пост наблюдается тем же правилом, что радар: спросить один раз после
    /// реального проезда (подошли ≤ 90 м, отъехали ≥ 180 м).
    func testPostIsAskedOnceAfterPassing() {
        let post = Camera(id: 7_000_001, region: "", city: "", location: "Пост ДПС",
                          lat: 41.3, lon: 69.3, type: CameraType.dpsPost.sourceString,
                          violations: Camera.defaultViolations(forType: CameraType.dpsPost.sourceString),
                          needsReview: nil, mobileConfirmed: true)
        var tracks: [Int: MobilePassWatch.Track] = [:]
        let near = CLLocationCoordinate2D(latitude: 41.3003, longitude: 69.3)   // ~33 м
        let away = CLLocationCoordinate2D(latitude: 41.3025, longitude: 69.3)   // ~280 м
        XCTAssertNil(MobilePassWatch.update(tracks: &tracks, mobileCameras: [post], from: near))
        XCTAssertEqual(MobilePassWatch.update(tracks: &tracks, mobileCameras: [post], from: away), post.id)
        XCTAssertNil(MobilePassWatch.update(tracks: &tracks, mobileCameras: [post], from: away),
                     "второй раз о том же посте не спрашиваем")
    }
}
