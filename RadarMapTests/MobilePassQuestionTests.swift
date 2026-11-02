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
        XCTAssertEqual(q.no, "Убрали")
        XCTAssertFalse(q.title.contains("Радар"))
    }

    /// Словарь (02.11): тренога — «Тренога ещё стоит?», радар — «Радар ещё
    /// стоит?», и у обоих «Стоит» / «Убрали». Настоящее время: тренога —
    /// это «сейчас», и сервер понимает ответ как «стоит сейчас».
    func testTripodAndRadarAskInThePresent() {
        let tripod = MobilePassWatch.question(for: .tripod)
        XCTAssertEqual(tripod.title, "Тренога ещё стоит?")
        XCTAssertEqual(tripod.yes, "Стоит")
        XCTAssertEqual(tripod.no, "Убрали")
        let radar = MobilePassWatch.question(for: .mobileRadar)
        XCTAssertEqual(radar.title, "Радар ещё стоит?")
        XCTAssertEqual(radar.no, "Убрали")
        for kind in [CameraType.mobileRadar, .tripod, .dpsPost, .accident] {
            XCTAssertFalse(MobilePassWatch.question(for: kind).title.contains("стоял"), "\(kind)")
        }
    }

    /// Длинные ответы — строкой ниже вопроса на SE; «Да / Нет» остаются рядом.
    func testLongAnswersGoBelowTheQuestion() {
        XCTAssertTrue(PassQuestionCard.stacksAnswers(yes: "Стоит", no: "Пост убрали", largeType: false))
        XCTAssertFalse(PassQuestionCard.stacksAnswers(yes: "Да", no: "Нет", largeType: false))
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
        XCTAssertNil(passWatch(tracks: &tracks, mobileCameras: [post], from: near, course: 0))
        XCTAssertEqual(passWatch(tracks: &tracks, mobileCameras: [post], from: away, course: 0), post.id)
        XCTAssertNil(passWatch(tracks: &tracks, mobileCameras: [post], from: away, course: 0),
                     "второй раз о том же посте не спрашиваем")
    }
}
