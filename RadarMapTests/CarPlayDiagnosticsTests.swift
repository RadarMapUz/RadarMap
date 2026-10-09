//
//  CarPlayDiagnosticsTests.swift
//  RadarMapTests
//
//  Прибор экрана машины: фризы и минуты сессии в суточной статистике.
//

import XCTest
@testable import RadarMap

final class CarPlayDiagnosticsTests: XCTestCase {

    func testHitchTallyCountsLongOnesAndKeepsTheWorst() {
        _ = HitchWatch.drain()
        HitchWatch.record(lagMilliseconds: 300)
        HitchWatch.record(lagMilliseconds: 1_800)
        HitchWatch.record(lagMilliseconds: 600)
        let tally = HitchWatch.drain()
        XCTAssertEqual(tally, HitchWatch.Tally(count: 3, long: 1, maxMilliseconds: 1_800))
        XCTAssertEqual(HitchWatch.drain(), HitchWatch.Tally(), "забрали — обнулилось")
    }

    func testOldStatsFileWithoutCarPlayStillReads() throws {
        // Файл прежней сборки: поля carPlay в нём нет, и терять из-за этого
        // сутки счётчиков нельзя.
        let old = #"{"current":{"day":"2026-10-09","onboarded":true,"locationAuth":"always","notificationsAllowed":true,"trips":2,"kilometres":12.5,"alerts":4,"passes":3,"reports":0,"screens":{},"limitSource":{},"maneuvers":{},"tripsDropped":{},"alertRecall":{},"voiced":{},"memoryWarnings":0},"pending":[]}"#
        let file = try JSONDecoder().decode(UsageStatsFile.self, from: Data(old.utf8))
        XCTAssertEqual(file.current.trips, 2)
        XCTAssertNil(file.current.carPlay)
    }

    func testReportHasNoTimesOrPlacesInCarPlayBlock() throws {
        var stats = UsageStats(day: "2026-10-10")
        stats.carPlay = ["sessions": 1, "minutes": 34, "hitches": 2, "longHitches": 1, "maxHitchMs": 1800]
        let json = String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)
        for leak in ["lat", "lon", "timestamp", "track"] {
            XCTAssertFalse(json.contains(leak), leak)
        }
    }
}
