//
//  CrowdCleanupTests.swift
//  RadarMapTests
//
//  Разовая чистка после S6 (S30): проезды мимо «Поста»/«ДТП» сняты, у
//  отметок водителей — без «исчезнет ~14:05»; остальное в записи цело.
//

import XCTest
@testable import RadarMap

final class CrowdCleanupTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func pass(_ id: Int, type: String, location: String = "Юнусабад", speed: Double = 70) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: id, typeRaw: type, location: location, speedKmh: speed,
                     date: start.addingTimeInterval(300), lat: 41.31, lon: 69.28, limitKmh: 60)
    }

    func testPostAndAccidentPassesLeaveCaptionsAreCleared() {
        var record = TripRecord(id: 1, startedAt: start, endedAt: start.addingTimeInterval(1800),
                                distanceMeters: 12_000, maxSpeedKmh: 80,
                                passed: [pass(10, type: "Стационар радар"),
                                         pass(2_000_001, type: "Пост ДПС", speed: 95),
                                         pass(2_000_002, type: "ДТП"),
                                         pass(2_000_003, type: "Тренога",
                                              location: "Отмечен водителями, исчезнет ~14:05")])
        record.score = 60
        record.startLat = 41.29
        let untouched = TripRecord(id: 2, startedAt: start, endedAt: start.addingTimeInterval(600),
                                   distanceMeters: 3000, maxSpeedKmh: 50, passed: [pass(11, type: "Стационар радар")])
        let (cleaned, removed, changed) = TripHistory.crowdCleaned([record, untouched])
        XCTAssertTrue(changed)
        XCTAssertEqual(removed.map(\.typeRaw).sorted(), ["ДТП", "Пост ДПС"])
        XCTAssertEqual(cleaned[0].passed.map(\.cameraID), [10, 2_000_003])
        XCTAssertEqual(cleaned[0].passed.last?.location, "", "подпись отметки после проезда бессмысленна")
        XCTAssertEqual(cleaned[0].startLat, 41.29, "копия записи, а не пересборка: старт цел")
        XCTAssertNotEqual(cleaned[0].score, 60, "проезд с превышением у поста больше не стоит баллов")
        XCTAssertEqual(cleaned[1].passed.count, 1)
        XCTAssertFalse(TripHistory.crowdCleaned(cleaned).2, "второй прогон ничего не меняет")
    }

    @MainActor
    func testCrowdIDsMatchTheService() {
        XCTAssertEqual(TripHistory.firstCrowdCameraID, MobileCameraService.idOffset)
    }
}
