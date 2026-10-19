//
//  TripDetailPassesTests.swift
//  RadarMapTests
//
//  Деталка поездки (6.5): раскрыты только штрафуемые проезды, остальные —
//  свёрнутой строкой «Без штрафа: N». Неизвестный лимит — не превышение.
//

import XCTest
@testable import RadarMap

final class TripDetailPassesTests: XCTestCase {
    private func pass(_ speed: Double, limit: Int?) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: 1, typeRaw: "Стационар радар", location: "Юнусабад",
                     speedKmh: speed, date: Date(timeIntervalSince1970: 1_800_000_000),
                     lat: 41.31, lon: 69.28, limitKmh: limit)
    }

    func testOnlyFinedPassesAreExpanded() {
        XCTAssertTrue(TripDetailContent.isFined(pass(95, limit: 60)))
        XCTAssertFalse(TripDetailContent.isFined(pass(62, limit: 60)), "в пределах допуска — без штрафа")
        XCTAssertFalse(TripDetailContent.isFined(pass(120, limit: nil)), "лимит неизвестен — превышения нет")
    }
}
