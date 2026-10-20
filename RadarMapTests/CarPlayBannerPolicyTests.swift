//
//  CarPlayBannerPolicyTests.swift
//  RadarMapTests
//
//  Очередь баннеров машины: камера старше всего, подтверждение уступает
//  всему, вопрос и объезд не теряются. До 18.10 объезд пробки снимал баннер
//  камеры, а подтверждения шли модальными окнами на весь экран.
//

import XCTest
@testable import RadarMap

final class CarPlayBannerPolicyTests: XCTestCase {

    private typealias P = CarPlayBannerPolicy

    func testEmptyScreenShowsAnything() {
        for kind in [P.Kind.info, .suggestion, .question, .roadWeather, .detour, .camera] {
            XCTAssertEqual(P.decide(showing: nil, incoming: kind), .present)
        }
    }

    func testCameraAlwaysWins() {
        for showing in [P.Kind.info, .suggestion, .question, .roadWeather, .detour, .camera] {
            XCTAssertEqual(P.decide(showing: showing, incoming: .camera), .replace, "поверх «\(showing)»")
        }
    }

    func testDetourNeverRemovesTheCamera() {
        // 2.2.20: syncDetourAlert снимал любой показанный баннер — и камеру тоже.
        XCTAssertEqual(P.decide(showing: .camera, incoming: .detour), .wait)
    }

    func testQuestionWaitsAndComesBack() {
        XCTAssertEqual(P.decide(showing: .camera, incoming: .question), .wait)
        XCTAssertEqual(P.decide(showing: .detour, incoming: .question), .wait)
        XCTAssertTrue(P.Kind.question.comesBack)
        XCTAssertTrue(P.Kind.detour.comesBack)
    }

    func testLateConfirmationIsDropped() {
        // «Поездка началась» после камеры — уже не новость.
        XCTAssertEqual(P.decide(showing: .camera, incoming: .info), .drop)
        XCTAssertEqual(P.decide(showing: .question, incoming: .suggestion), .drop)
        XCTAssertFalse(P.Kind.info.comesBack)
        XCTAssertFalse(P.Kind.suggestion.comesBack)
    }

    func testNewerOfTheSameKindReplaces() {
        XCTAssertEqual(P.decide(showing: .info, incoming: .info), .replace)
        XCTAssertEqual(P.decide(showing: .question, incoming: .question), .replace)
    }

    func testMoreImportantReplacesLessImportant() {
        XCTAssertEqual(P.decide(showing: .info, incoming: .question), .replace)
        XCTAssertEqual(P.decide(showing: .suggestion, incoming: .detour), .replace)
    }

    /// «Завершить поездку?» — ответ на касание водителя: вопрос и объезд его
    /// не перебивают, камера — да; поверх камеры он не встаёт (тогда окно).
    func testDriverRequestOutranksQuestionsAndDetours() {
        XCTAssertEqual(P.decide(showing: .question, incoming: .request), .replace)
        XCTAssertEqual(P.decide(showing: .detour, incoming: .request), .replace)
        XCTAssertEqual(P.decide(showing: .request, incoming: .question), .wait)
        XCTAssertEqual(P.decide(showing: .request, incoming: .detour), .wait)
        XCTAssertEqual(P.decide(showing: .request, incoming: .camera), .replace)
        XCTAssertEqual(P.decide(showing: .camera, incoming: .request), .drop)
    }

    /// Погода на перевале (19.2) — ниже камеры, объезда и запроса водителя;
    /// вытесненная — вернётся, пока не истекла.
    func testRoadWeatherYieldsToCameraDetourAndRequest() {
        XCTAssertEqual(P.decide(showing: .camera, incoming: .roadWeather), .wait)
        XCTAssertEqual(P.decide(showing: .detour, incoming: .roadWeather), .wait)
        XCTAssertEqual(P.decide(showing: .request, incoming: .roadWeather), .wait)
        XCTAssertEqual(P.decide(showing: .roadWeather, incoming: .camera), .replace)
        XCTAssertEqual(P.decide(showing: .roadWeather, incoming: .detour), .replace)
        XCTAssertEqual(P.decide(showing: .info, incoming: .roadWeather), .replace)
        XCTAssertEqual(P.decide(showing: .roadWeather, incoming: .question), .wait)
        XCTAssertTrue(P.Kind.roadWeather.comesBack)
    }
}
