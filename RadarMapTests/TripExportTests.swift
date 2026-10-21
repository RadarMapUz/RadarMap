//
//  TripExportTests.swift
//  RadarMapTests
//
//  «Экспорт всех поездок» (15.3): CSV по RFC 4180 без формул, точные строки
//  таблицы, имена файлов без двоеточий и повторов, архив с таблицей и GPX
//  только тех поездок, у которых есть трек.
//

import XCTest
@testable import RadarMap

final class TripExportTests: XCTestCase {
    private let tashkent = TimeZone(identifier: "Asia/Tashkent") ?? .current

    private func trip(start: TimeInterval, minutes: Double, meters: Double, score: Double?,
                      passes: [PassedCamera] = [], track: Bool, work: Bool? = nil,
                      stops: [TripStop]? = nil) -> TripRecord {
        let begin = Date(timeIntervalSince1970: start)
        return TripRecord(id: start, startedAt: begin, endedAt: begin.addingTimeInterval(minutes * 60),
                          distanceMeters: meters, maxSpeedKmh: 80, passed: passes,
                          endLat: 41.33, endLon: 69.3,
                          track: track ? [41.3, 69.2, 40, 41.31, 69.21, 55, 41.32, 69.22, 60] : nil,
                          score: score, stops: stops, work: work)
    }

    private func pass(speed: Double, limit: Int, at start: TimeInterval) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: 1204, typeRaw: "Стационар радар", location: "Амира Темура",
                     speedKmh: speed, date: Date(timeIntervalSince1970: start + 300),
                     lat: 41.311, lon: 69.279, limitKmh: limit)
    }

    func testEscapeFollowsRFC4180AndDefusesFormulas() {
        XCTAssertEqual(TripExport.escape("plain"), "plain")
        XCTAssertEqual(TripExport.escape(""), "")
        XCTAssertEqual(TripExport.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(TripExport.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(TripExport.escape("line\nbreak"), "\"line\nbreak\"")
        XCTAssertEqual(TripExport.escape("=SUM(A1:A2)"), "'=SUM(A1:A2)")
        XCTAssertEqual(TripExport.escape("+998 90"), "'+998 90")
        XCTAssertEqual(TripExport.escape("@cmd"), "'@cmd")
        XCTAssertEqual(TripExport.escape("-12.5"), "-12.5", "число не формула")
        XCTAssertEqual(TripExport.escape("=a,\"b\""), "\"'=a,\"\"b\"\"\"")
    }

    /// Строки таблицы — дословно: местное время, точка в числах, время в
    /// движении без стоянки, риск — только по достоверному лимиту, рейс 1/0,
    /// ссылка на GPX только у поездки с треком. Ни дома, ни работы.
    func testCSVRows() {
        let first: TimeInterval = 1_791_810_000   // 12.10.2026 13:00 UTC = 18:00 в Ташкенте
        let stop = TripStop(id: UUID(), lat: 41.3, lon: 69.2,
                            from: Date(timeIntervalSince1970: first + 600),
                            to: Date(timeIntervalSince1970: first + 900))
        let a = trip(start: first, minutes: 31, meters: 14_250, score: 91,
                     passes: [pass(speed: 75, limit: 60, at: first)], track: true, work: true, stops: [stop])
        let b = trip(start: 1_790_804_400, minutes: 25, meters: 5_200, score: nil, track: false)
        let names = TripExport.gpxNames(for: [a], timeZone: tashkent)
        let csv = TripExport.csv([a, b], gpxNames: names, timeZone: tashkent)
        XCTAssertEqual(csv, """
        trip_id,start,end,distance_km,moving_minutes,score,camera_passes,fine_risk_uzs,work,gpx\r
        1790804400,2026-10-01 02:40:00,2026-10-01 03:05:00,5.20,25.0,,0,0,0,\r
        1791810000,2026-10-12 18:00:00,2026-10-12 18:31:00,14.25,26.0,91,1,440000,1,gpx/2026-10-12_18-00-00.gpx\r

        """)
        XCTAssertFalse(csv.contains("41.3"), "координат в таблице нет")
    }

    func testFileNamesAreSafeAndUnique() {
        // Перевод часов назад: 02:30 летнего и 02:30 зимнего — одно местное время.
        let berlin = TimeZone(identifier: "Europe/Berlin") ?? .current
        let summer = trip(start: 1_792_888_200, minutes: 10, meters: 3000, score: 100, track: true)
        let winter = trip(start: 1_792_891_800, minutes: 10, meters: 3000, score: 100, track: true)
        let names = TripExport.gpxNames(for: [summer, winter], timeZone: berlin)
        XCTAssertEqual(names[summer.id], "2026-10-25_02-30-00.gpx")
        XCTAssertEqual(names[winter.id], "2026-10-25_02-30-00-2.gpx")
        XCTAssertTrue(names.values.allSatisfy { !$0.contains(":") && !$0.contains("/") })
        XCTAssertEqual(TripExport.archiveName(now: Date(timeIntervalSince1970: 1_792_497_600), timeZone: tashkent),
                       "RadarMap-trips-2026-10-20")
    }

    /// Архив — ZIP с таблицей и GPX только поездки с треком; повторная
    /// выгрузка убирает оставленную вылетом прошлую.
    func testArchiveHoldsTheTableAndTracks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TripExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent(TripExport.workPrefix + "old", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)

        let tracked = trip(start: 1_791_810_000, minutes: 31, meters: 14_250, score: 91, track: true)
        let bare = trip(start: 1_790_804_400, minutes: 25, meters: 5_200, score: nil, track: false)
        let archive = try await TripExport.makeArchive([tracked, bare], now: Date(timeIntervalSince1970: 1_792_497_600),
                                                       timeZone: tashkent, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "прошлая выгрузка убрана")
        XCTAssertEqual(archive.file.lastPathComponent, "RadarMap-trips-2026-10-20.zip")
        let data = try Data(contentsOf: archive.file)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04], "ZIP")
        let names = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(names.contains("trips.csv"))
        XCTAssertTrue(names.contains("2026-10-12_18-00-00.gpx"))
        XCTAssertFalse(names.contains("2026-10-01_02-40-00.gpx"), "без трека — без GPX")
        TripExport.remove(archive.folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.folder.path))
    }
}
