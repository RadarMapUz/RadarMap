//
//  WorkShiftTests.swift
//  RadarMapTests
//
//  Смены таксиста (12б.9): рейсы с простоем до часа — одна смена, больше —
//  новая; личные поездки в смены не входят; режим не переписывает записи.
//

import XCTest
@testable import RadarMap

final class WorkShiftTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    private func trip(_ startMinute: Double, _ minutes: Double, km: Double = 5, work: Bool? = true,
                      passes: [PassedCamera] = []) -> TripRecord {
        let start = day.addingTimeInterval(startMinute * 60)
        var record = TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                                endedAt: start.addingTimeInterval(minutes * 60),
                                distanceMeters: km * 1000, maxSpeedKmh: 60, passed: passes)
        record.work = work
        return record
    }

    private func pass(_ speed: Double, limit: Int) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: 1, typeRaw: "Стационар радар", location: "",
                     speedKmh: speed, date: day, lat: 41.31, lon: 69.28, limitKmh: limit)
    }

    func testIdleUpToAnHourKeepsTheShift() {
        // 8:00–8:20, перерыв 40 мин, 9:00–9:30, перерыв 2 ч, 11:30–12:00.
        let shifts = WorkShift.shifts(from: [trip(0, 20), trip(60, 30), trip(210, 30)])
        XCTAssertEqual(shifts.count, 2)
        XCTAssertEqual(shifts.last?.trips, 2, "40 мин простоя — та же смена")
        XCTAssertEqual(shifts.last?.duration, 90 * 60, "от первого старта до последнего финиша")
        XCTAssertEqual(shifts.first?.trips, 1, "новые первыми")
        XCTAssertEqual(WorkShift.shifts(from: [trip(0, 20), trip(80, 10)]).count, 1, "ровно час — ещё смена")
        XCTAssertEqual(WorkShift.shifts(from: [trip(0, 20), trip(81, 10)]).count, 2)
    }

    func testPersonalTripsAreNotShifts() {
        let shifts = WorkShift.shifts(from: [trip(0, 20, work: nil), trip(30, 20), trip(60, 20, work: nil)])
        XCTAssertEqual(shifts.count, 1)
        XCTAssertEqual(shifts.first?.trips, 1, "личная поездка между рейсами — не рейс")
        XCTAssertTrue(WorkShift.shifts(from: [trip(0, 20, work: nil)]).isEmpty,
                      "старые записи без пометки в смены не попадают — режим их не переписывает")
    }

    func testTotalsAndFines() {
        let shifts = WorkShift.shifts(from: [trip(0, 20, km: 12, passes: [pass(88, limit: 60), pass(58, limit: 60)]),
                                             trip(30, 10, km: 3)])
        let shift = try? XCTUnwrap(shifts.first)
        XCTAssertEqual(shift?.distanceMeters, 15_000)
        XCTAssertEqual(shift?.overspeeds, 1, "58 при 60 — не превышение")
        XCTAssertEqual(shift?.fineRisk, TripHistory.fineRisk(of: [pass(88, limit: 60)]))
        XCTAssertEqual(shift?.movingSeconds, 30 * 60, "простой между рейсами — не движение")
    }

    func testOldRecordWithoutFlagDecodes() throws {
        let record = trip(0, 10, work: nil)
        let data = try JSONEncoder().encode(record)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"work\""), "личная запись — без поля")
        XCTAssertNil(try JSONDecoder().decode(TripRecord.self, from: data).work)
    }
}
