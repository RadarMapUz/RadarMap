//
//  CarPlayTripToggleTests.swift
//  RadarMapTests
//
//  ▶/■ в баре машины: второе нажатие в пределах carPlayTripToggleGuard не
//  переключает поездку, а отвечает баннером о том, что уже сделано.
//

import XCTest
@testable import RadarMap

final class CarPlayTripToggleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstTapToggles() {
        XCTAssertEqual(CarPlayTripToggle.decide(lastToggle: nil, now: t0, tripActive: false), .toggle)
    }

    /// carplay12: старт и через 0,6–0,9 с второе нажатие — не конец поездки,
    /// а баннер «поездка уже идёт».
    func testRepeatTapWithinTheGuardAnswersWithABanner() {
        for gap in [0.3, 0.6, 0.9, AppConfig.carPlayTripToggleGuard - 0.1] {
            let afterStart = CarPlayTripToggle.decide(lastToggle: t0, now: t0.addingTimeInterval(gap), tripActive: true)
            guard case .repeated(let message) = afterStart else { return XCTFail("через \(gap) с — переключил") }
            XCTAssertTrue(message.contains("идёт"), message)
            let afterEnd = CarPlayTripToggle.decide(lastToggle: t0, now: t0.addingTimeInterval(gap), tripActive: false)
            guard case .repeated(let ended) = afterEnd else { return XCTFail("через \(gap) с — переключил") }
            XCTAssertTrue(ended.contains("завершена"), ended)
        }
    }

    func testTapAfterTheGuardTogglesAgain() {
        XCTAssertEqual(CarPlayTripToggle.decide(lastToggle: t0, now: t0.addingTimeInterval(AppConfig.carPlayTripToggleGuard),
                                                tripActive: true), .toggle)
    }
}
