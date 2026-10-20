//
//  UpgradeFormatTests.swift
//  RadarMapTests
//
//  Сценарий E2 (12в): обновление со старой версии. Запись поездки в формате
//  июля 2026 (a032865 — без стоянок, старта, «промолчало», лимитов дороги и
//  всего, что добавлено позже) читается нынешней сборкой, а все разовые
//  миграции истории на ней безопасны и идемпотентны: второй прогон ничего не
//  меняет — флаг в Storage мог потеряться при восстановлении из копии.
//

import XCTest
@testable import RadarMap

final class UpgradeFormatTests: XCTestCase {
    /// Июльская запись: только поля a032865. Даты — как пишет JSONEncoder по
    /// умолчанию (секунды от 2001).
    private let julyRecord = """
    [{"id": 774000000, "startedAt": 774000000, "endedAt": 774001800, "distanceMeters": 12000,
      "maxSpeedKmh": 84, "endLat": 41.32, "endLon": 69.28, "track": [41.31, 69.27, 50, 41.32, 69.28, 40],
      "score": 80,
      "passed": [
        {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "cameraID": 37, "typeRaw": "Стационар радар",
         "location": "Dаhаsi", "speedKmh": 72, "date": 774000600, "lat": 41.31, "lon": 69.27, "limitKmh": 60},
        {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FE", "cameraID": 38, "typeRaw": "Стационар радар",
         "location": "Dаhаsi", "speedKmh": 72, "date": 774000602, "lat": 41.31001, "lon": 69.27, "limitKmh": 60},
        {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FD", "cameraID": 2000005, "typeRaw": "Пост ДПС",
         "location": "Отмечен водителями, исчезнет ~14:05", "speedKmh": 90, "date": 774000900}
      ]}]
    """

    func testJulyRecordStillDecodes() throws {
        let records = try JSONDecoder().decode([TripRecord].self, from: Data(julyRecord.utf8))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].passed.count, 3)
        XCTAssertNil(records[0].stops)
        XCTAssertEqual(records[0].score, 80)
    }

    /// Все разовые чистки — по очереди, как при первом запуске новой сборки,
    /// и ещё раз: второй прогон ничего не меняет.
    func testOneTimeMigrationsAreIdempotent() throws {
        var history = try JSONDecoder().decode([TripRecord].self, from: Data(julyRecord.utf8))
        func runAll() -> Bool {
            var changed = false
            let crowd = TripHistory.crowdCleaned(history)
            history = crowd.0; changed = changed || crowd.2
            let duplicates = TripHistory.duplicatesCleaned(history)
            history = duplicates.0; changed = changed || duplicates.2
            let labels = TripHistory.labelsNormalized(history)
            history = labels.0; changed = changed || labels.1
            return changed
        }
        XCTAssertTrue(runAll(), "первая сборка с миграциями чистит июльскую запись")
        XCTAssertEqual(history[0].passed.map(\.cameraID), [37], "пост снят, дубль снят, своя камера осталась")
        XCTAssertEqual(history[0].passed[0].location, "Dahasi", "подпись — одним алфавитом")
        XCTAssertFalse(runAll(), "второй прогон ничего не меняет")
        // И после всех миграций запись снова кодируется и читается.
        let data = try JSONEncoder().encode(history)
        XCTAssertEqual(try JSONDecoder().decode([TripRecord].self, from: data).count, 1)
    }
}
