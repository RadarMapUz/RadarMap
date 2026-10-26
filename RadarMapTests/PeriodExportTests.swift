//
//  PeriodExportTests.swift
//  RadarMapTests
//
//  Выгрузка периода (31E): в файле нет координат и адресов, только районы,
//  время местное, числа с точкой, смены — по рабочим рейсам окна.
//

import XCTest
@testable import RadarMap

final class PeriodExportTests: XCTestCase {
    private let tashkent = TimeZone(identifier: "Asia/Tashkent")!
    /// 15.01.2027 13:00 по Ташкенту.
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ offset: TimeInterval, km: Double, work: Bool = false) -> TripRecord {
        TripRecord(id: start.timeIntervalSince1970 + offset, startedAt: start + offset,
                   endedAt: start + offset + 1800, distanceMeters: km * 1000, maxSpeedKmh: 70,
                   passed: [], endLat: 41.311111, endLon: 69.279999, startLat: 41.3, startLon: 69.2,
                   work: work ? true : nil)
    }

    func testTripsCSVHasDistrictsButNoCoordinates() {
        let records = [record(3600, km: 12.345), record(0, km: 5)]
        let ends = [records[0].id: PeriodExport.Ends(from: "Yunusobod tumani", to: "Chilonzor tumani")]
        let rows = PeriodExport.rows(records, ends: ends)
        XCTAssertEqual(rows.map(\.start), [start, start + 3600], "строки не по времени")
        let csv = PeriodExport.tripsCSV(rows, timeZone: tashkent)
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "date,start,end,distance_km,duration_min,moving_min,from_district,to_district,work")
        XCTAssertEqual(lines[1], "2027-01-15,13:00,13:30,5.00,30,30,,,0")
        XCTAssertEqual(lines[2], "2027-01-15,14:00,14:30,12.35,30,30,Yunusobod tumani,Chilonzor tumani,0")
        for leak in ["41.3", "69.2", "41,3"] {
            XCTAssertFalse(csv.contains(leak), "в выгрузке координата \(leak)")
        }
    }

    func testDistrictComesOnlyFromANearbyCamera() {
        XCTAssertEqual(PeriodExport.district(city: " Yunusobod tumani ", distance: 800), "Yunusobod tumani")
        XCTAssertNil(PeriodExport.district(city: "Yunusobod tumani", distance: 4000),
                     "район камеры в 4 км — чужой район")
        XCTAssertNil(PeriodExport.district(city: "", distance: 10))
        XCTAssertNil(PeriodExport.district(city: nil, distance: 10))
    }

    func testShiftsComeFromWorkTripsOfTheWindow() {
        let records = [record(0, km: 10, work: true), record(2400, km: 8, work: true), record(9000, km: 3)]
        let window = DateInterval(start: start - 3600, duration: 86_400)
        let shifts = PeriodExport.shifts(records, in: window)
        XCTAssertEqual(shifts.count, 1)
        XCTAssertEqual(shifts[0].trips, 2)
        let csv = PeriodExport.shiftsCSV(shifts, timeZone: tashkent)
        XCTAssertTrue(csv.hasPrefix("date,start,end,trips,distance_km,moving_min,overspeeds\r\n"))
        XCTAssertTrue(csv.contains("2027-01-15,13:00,14:10,2,18.00,60,0"), csv)
        XCTAssertEqual(PeriodExport.shifts(records, in: DateInterval(start: start + 86_400, duration: 86_400)), [])
    }

    func testTotalsAddUp() {
        let rows = PeriodExport.rows([record(0, km: 10, work: true), record(3600, km: 5)], ends: [:])
        let totals = PeriodExport.totals(rows)
        XCTAssertEqual(totals.trips, 2)
        XCTAssertEqual(totals.distanceMeters, 15_000, accuracy: 0.1)
        XCTAssertEqual(totals.workTrips, 1)
        XCTAssertEqual(totals.workMeters, 10_000, accuracy: 0.1)
    }

    func testFileNameIsLatinAndNamesTheWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tashkent
        calendar.firstWeekday = 2
        let week = calendar.dateInterval(of: .weekOfYear, for: start)!
        XCTAssertEqual(PeriodExport.fileName(week, ext: "csv", timeZone: tashkent), "RadarMap-2027-01-11_2027-01-17.csv")
        let day = calendar.dateInterval(of: .day, for: start)!
        XCTAssertEqual(PeriodExport.fileName(day, suffix: "-shifts", ext: "csv", timeZone: tashkent),
                       "RadarMap-2027-01-15-shifts.csv")
    }

    func testFormulaInDistrictIsDefused() {
        let rows = [PeriodExport.Row(start: start, end: start + 60, distanceMeters: 1000, movingSeconds: 60,
                                     from: "=HYPERLINK(\"x\")", to: nil, work: false)]
        let csv = PeriodExport.tripsCSV(rows, timeZone: tashkent)
        XCTAssertTrue(csv.contains("\"'=HYPERLINK(\"\"x\"\")\""), csv)
    }
}
