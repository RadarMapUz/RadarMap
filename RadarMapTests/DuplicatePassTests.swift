//
//  DuplicatePassTests.swift
//  RadarMapTests
//
//  Одна точка — один проезд (11.1): пара камер-дублей в 1–11 м писала проезд
//  дважды — двойной «штраф» и двойной минус в рейтинге. Повтор — тот же тип
//  рядом и за минуту; разные места, типы или часы — не повтор.
//

import XCTest
@testable import RadarMap

final class DuplicatePassTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func pass(_ id: Int, type: String = "Стационар радар", lat: Double? = 41.3100, lon: Double? = 69.2800,
                      at seconds: TimeInterval = 300, speed: Double = 75) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: id, typeRaw: type, location: "Юнусабад", speedKmh: speed,
                     date: start.addingTimeInterval(seconds), lat: lat, lon: lon, limitKmh: 60)
    }

    private func isDuplicate(_ new: PassedCamera, of previous: [PassedCamera]) -> Bool {
        TripHistory.isDuplicate(cameraID: new.cameraID, typeRaw: new.typeRaw, lat: new.lat, lon: new.lon,
                                date: new.date, of: previous)
    }

    func testTwinOfTheSamePointIsARepeat() {
        let first = pass(265)
        // 266 в 1,5 м, через 2 с.
        XCTAssertTrue(isDuplicate(pass(266, lat: 41.31001, at: 302), of: [first]))
    }

    func testDifferentPlaceTypeOrTimeIsNotARepeat() {
        let first = pass(265)
        XCTAssertFalse(isDuplicate(pass(300, lat: 41.3110, at: 330), of: [first]), "110 м — другая камера")
        XCTAssertFalse(isDuplicate(pass(266, type: "Стационар камера", at: 302), of: [first]), "другой тип")
        XCTAssertFalse(isDuplicate(pass(266, at: 300 + AppConfig.passDuplicateSeconds + 5), of: [first]),
                       "через минуту — новый проезд (круг)")
        XCTAssertFalse(isDuplicate(pass(266, lat: nil, lon: nil, at: 302), of: [first]),
                       "без координат судить не по чему")
        XCTAssertFalse(isDuplicate(pass(265, at: 302), of: [first]), "та же камера — не дубль базы")
    }

    func testCleanupKeepsTheFirstAndRescores() {
        var record = TripRecord(id: 1, startedAt: start, endedAt: start.addingTimeInterval(1800),
                                distanceMeters: 12_000, maxSpeedKmh: 80,
                                passed: [pass(265, speed: 81), pass(266, lat: 41.31001, at: 302, speed: 81),
                                         pass(400, lat: 41.32, at: 600)])
        record.score = 50
        let clean = TripRecord(id: 2, startedAt: start, endedAt: start.addingTimeInterval(600),
                               distanceMeters: 3_000, maxSpeedKmh: 60, passed: [pass(500)])
        let (cleaned, removed, changed) = TripHistory.duplicatesCleaned([record, clean])
        XCTAssertTrue(changed)
        XCTAssertEqual(removed.map(\.cameraID), [266])
        XCTAssertEqual(cleaned[0].passed.map(\.cameraID), [265, 400])
        XCTAssertNotEqual(cleaned[0].score, 50, "балл пересчитан без повтора")
        XCTAssertEqual(cleaned[1].passed.map(\.cameraID), [500], "чистая поездка не тронута")
        XCTAssertFalse(TripHistory.duplicatesCleaned(cleaned).2, "второй прогон ничего не меняет")
    }
}
