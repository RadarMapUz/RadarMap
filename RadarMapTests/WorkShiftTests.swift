//
//  WorkShiftTests.swift
//  RadarMapTests
//
//  Смены таксиста (12б.9): рейсы с простоем до часа — одна смена, больше —
//  новая; личные поездки в смены не входят; режим не переписывает записи.
//

import XCTest
import CoreLocation
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

    /// Закрытая смена переживает чистку истории (50 записей / 30 дней) и не
    /// двоится, когда её первые рейсы уже вырезаны.
    func testClosedShiftOutlivesHistoryPruning() {
        let morning = [trip(0, 20), trip(30, 20), trip(60, 20)]
        let afterShift = day.addingTimeInterval(5 * 3600)
        let log = WorkShift.logged([], history: morning, now: afterShift)
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.first?.trips, 3)
        // Чистка вырезала первый рейс: остаток — не новая смена.
        let pruned = Array(morning.dropFirst())
        XCTAssertEqual(WorkShift.logged(log, history: pruned, now: afterShift), log)
        XCTAssertEqual(WorkShift.display(log: log, history: pruned).count, 1, "без урезанной копии")
        XCTAssertEqual(WorkShift.display(log: log, history: []).first?.trips, 3, "история пуста — журнал помнит")
    }

    func testOngoingShiftIsShownButNotLogged() {
        let now = day.addingTimeInterval(50 * 60)   // последний рейс кончился 10 мин назад
        let history = [trip(0, 20), trip(30, 10)]
        XCTAssertTrue(WorkShift.logged([], history: history, now: now).isEmpty, "смена ещё идёт")
        XCTAssertEqual(WorkShift.display(log: [], history: history).first?.trips, 2)
    }

    /// Рейс идёт, а с конца прошлого прошло больше часа: смена не закрыта —
    /// рейс попадёт в историю только на финише. Раньше пересчёт посреди
    /// такого рейса писал смену в журнал урезанной, и остаток дня совпадал с
    /// ней по времени и пропадал из «Смен» (ревью 14.1).
    func testShiftStaysOpenWhileWorkTripRuns() {
        let first = [trip(0, 20)]                        // 8:00–8:20
        let now = day.addingTimeInterval(100 * 60)       // 9:40 — 80 мин после 8:20
        XCTAssertTrue(WorkShift.logged([], history: first, now: now,
                                       ongoingSince: day.addingTimeInterval(50 * 60)).isEmpty,
                      "рейс с 8:50 ещё идёт — смена открыта")
        XCTAssertTrue(WorkShift.logged([], history: first, now: now,
                                       ongoingSince: day.addingTimeInterval(30 * 60)).isEmpty,
                      "продолженная склейкой запись вне истории — смена тоже открыта")
        XCTAssertEqual(WorkShift.logged([], history: first, now: now,
                                        ongoingSince: day.addingTimeInterval(85 * 60)).first?.trips, 1,
                       "рейс после часа простоя — уже новая смена, прошлая закрыта")
        // Рейс закончился в 9:50: смена целиком — оба рейса.
        let after = first + [trip(50, 60)]
        XCTAssertEqual(WorkShift.logged([], history: after, now: day.addingTimeInterval(4 * 3600)).first?.trips, 2)
        // Почему ошибку журнала не поправить потом: урезанная запись прячет остаток.
        let truncated = WorkShift.logged([], history: first, now: now)
        XCTAssertEqual(WorkShift.display(log: truncated, history: after).first?.trips, 1)
    }

    /// Разделить или склеить рейс руками — рейс и останется: без пометки он
    /// выпадал из «Смен» и учился как своя поездка, с адресом пассажира в
    /// выученных Дом/Работа (ревью 14.1).
    func testSplitAndMergeKeepWorkFlag() {
        XCTAssertEqual(TripMerge.merged(previous: trip(0, 20), next: trip(30, 20)).work, true)
        XCTAssertEqual(TripMerge.merged(previous: trip(0, 20, work: nil), next: trip(30, 20)).work, true,
                       "смешанная склейка — рейс: адрес пассажира учить нельзя")
        XCTAssertNil(TripMerge.merged(previous: trip(0, 20, work: nil), next: trip(30, 20, work: nil)).work)

        let base = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
        let points = (0..<11).flatMap { i -> [Double] in
            let p = GeoMath.destination(from: base, bearing: 0, distanceMeters: Double(i) * 100)
            return [p.latitude, p.longitude, 50]
        }
        let middle = GeoMath.destination(from: base, bearing: 0, distanceMeters: 500)
        let stop = TripStop(id: UUID(), lat: middle.latitude, lon: middle.longitude,
                            from: day.addingTimeInterval(600), to: day.addingTimeInterval(1200))
        var record = trip(0, 40)
        record.track = points
        record.stops = [stop]
        let legs = TripHistory.split(record, at: stop)
        XCTAssertEqual(legs.count, 2)
        XCTAssertEqual(legs.map(\.work), [true, true])
        XCTAssertEqual(WorkShift.shifts(from: legs).first?.trips, 2, "обе половины — в смене")
    }

    func testLogForgetsAfterNinetyDays() {
        let log = WorkShift.logged([], history: [trip(0, 20)], now: day.addingTimeInterval(7200))
        XCTAssertTrue(WorkShift.logged(log, history: [], now: day.addingTimeInterval(91 * 86_400)).isEmpty)
    }
}
