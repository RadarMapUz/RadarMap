//
//  CommuteLossTests.swift
//  RadarMapTests
//
//  «Где ушло время» (8.8.8): только медленные места — хуже q75 водителя, а не
//  просто медленнее медианы; своя поездка в «обычно» не входит; стоянка рвёт
//  отрезок; меньше минуты — не место; не больше трёх, большие первыми;
//  первые и последние 400 м — не дорога (выезд со стоянки), их время отдельно.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class CommuteLossTests: XCTestCase {
    private let lat = 41.30, lon0 = 69.20
    private var k: Double { 111_320 * cos(lat * .pi / 180) }
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let tripID = 999.0

    /// Понедельник, 11 января 2027.
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 11) -> Date {
        utc.date(from: DateComponents(year: 2027, month: 1, day: day, hour: hour, minute: minute))!
    }

    private func point(_ x: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon0 + x / k)
    }

    /// Прямая 4 км на восток, 20 участков по 200 м. Обычные утренние поездки —
    /// 18–25 с на участок (медиана 20, q75 22), вечерние втрое дольше; своя
    /// поездка — `mine` (секунды по участкам), выезд в 8:05.
    private func variant(mine: [UInt16], others: [Int] = [18, 20, 20, 22, 25],
                         evening: Bool = true, morning: Bool = true,
                         unmeasured: Set<Int> = []) -> CommuteProfile.Variant {
        var line: [Int32] = []
        for i in 0..<81 {
            let p = point(50 * Double(i))
            line.append(Int32((p.latitude * 1e5).rounded()))
            line.append(Int32((p.longitude * 1e5).rounded()))
        }
        var rows = [CommuteProfile.Row(tripID: tripID, departure: at(8, 5), weekend: false,
                                       arrivalMinute: 0, seconds: mine)]
        for (i, s) in others.enumerated() {
            let seconds = (0..<20).map { unmeasured.contains($0) ? CommuteProfile.Row.noData : UInt16(s) }
            if morning {
                rows.append(CommuteProfile.Row(tripID: Double(i), departure: at(8, day: 4 + i), weekend: false,
                                               arrivalMinute: 0, seconds: seconds))
            }
            if evening {
                rows.append(CommuteProfile.Row(tripID: Double(100 + i), departure: at(18, day: 4 + i),
                                               weekend: false, arrivalMinute: 0,
                                               seconds: [UInt16](repeating: UInt16(s * 3), count: 20)))
            }
        }
        return CommuteProfile.Variant(id: UUID(), line: line, ends: (1...20).map { Float($0 * 200) },
                                      limitKmh: [], rows: rows, lastUsed: at(8))
    }

    private func usual(_ overrides: [Int: UInt16] = [:]) -> [UInt16] {
        (0..<20).map { overrides[$0] ?? 20 }
    }

    /// Пробка на участках 5–9 (1–2 км): по 60 с вместо 20 — 200 с, одно место
    /// посередине пробки.
    func testAJamIsOnePlaceWithItsLoss() throws {
        let mine = usual(Dictionary(uniqueKeysWithValues: (5...9).map { ($0, UInt16(60)) }))
        let found = CommuteLoss.stretches(in: variant(mine: mine), tripID: tripID, calendar: utc)
        let jam = try XCTUnwrap(found.first)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(jam.segments, 5...9)
        XCTAssertEqual(jam.startMeters, 1000, accuracy: 0.5)
        XCTAssertEqual(jam.endMeters, 2000, accuracy: 0.5)
        XCTAssertEqual(jam.lostSeconds, 200, accuracy: 0.5)
        XCTAssertEqual(jam.lostMinutes, 3)
        let middle = point(1500)
        XCTAssertLessThan(GeoMath.fastDistance(jam.midpoint.latitude, jam.midpoint.longitude,
                                               middle.latitude, middle.longitude), 20)
    }

    /// Медленнее медианы, но в обычном разбросе — не потеря: другие ездят
    /// 18–30 с (медиана 20, q75 26), наша — 26 с на каждом участке, это 120 с
    /// «против медианы», но не хуже обычного разброса. Сравнение с медианой
    /// назвало бы всю дорогу потерей — каждый светофор.
    func testWithinTheUsualSpreadIsNotALoss() {
        let mine = [UInt16](repeating: 26, count: 20)
        let found = CommuteLoss.stretches(in: variant(mine: mine, others: [18, 20, 20, 26, 30]),
                                          tripID: tripID, calendar: utc)
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    /// Только медленные места: быстрая поездка ничего не называет.
    func testFasterTripNamesNothing() {
        let mine = [UInt16](repeating: 12, count: 20)
        XCTAssertTrue(CommuteLoss.stretches(in: variant(mine: mine), tripID: tripID, calendar: utc).isEmpty)
    }

    /// Короткий пробел посреди пробки — стояние в очереди дольше двух минут на
    /// границе участков — не рвёт отрезок: потеря пробела — как у соседей.
    /// Длинный пробел (стоянка, сошли с линии) — два отрезка.
    func testAStandstillGapIsBridgedALongGapSplits() {
        var mine = usual(Dictionary(uniqueKeysWithValues: (5...9).map { ($0, UInt16(60)) }))
        mine[7] = CommuteProfile.Row.noData
        let jam = CommuteLoss.stretches(in: variant(mine: mine), tripID: tripID, calendar: utc)
        XCTAssertEqual(jam.map(\.segments), [5...9])
        XCTAssertEqual(jam.first?.lostSeconds ?? 0, 200, accuracy: 0.5)

        var split = usual(Dictionary(uniqueKeysWithValues: (3...12).map { ($0, UInt16(50)) }))
        for j in 6...8 { split[j] = CommuteProfile.Row.noData }
        let found = CommuteLoss.stretches(in: variant(mine: split), tripID: tripID, calendar: utc)
        XCTAssertEqual(found.map(\.segments), [9...12, 3...5], "длинный пробел рвёт; большая потеря — первой")
    }

    /// Меньше минуты — не место (порог, а не потолок списка: мест всего два).
    func testLessThanAMinuteIsNotAPlace() {
        var overrides: [Int: UInt16] = [1: 70]                 // 50 с — не место
        for j in 7...9 { overrides[j] = 70 }                   // 150 с
        let found = CommuteLoss.stretches(in: variant(mine: usual(overrides)), tripID: tripID, calendar: utc)
        XCTAssertEqual(found.map(\.segments), [7...9])
    }

    /// Больше трёх мест — три самых дорогих, по убыванию.
    func testAtMostThreePlacesKept() {
        var overrides: [Int: UInt16] = [:]
        for j in 2...3 { overrides[j] = 60 }                   // 80 с
        for j in 7...9 { overrides[j] = 70 }                   // 150 с
        for j in 12...13 { overrides[j] = 75 }                 // 110 с
        for j in 16...17 { overrides[j] = 65 }                 // 90 с
        let found = CommuteLoss.stretches(in: variant(mine: usual(overrides)), tripID: tripID, calendar: utc)
        XCTAssertEqual(found.map(\.segments), [7...9, 12...13, 16...17])
        XCTAssertEqual(found.map(\.lostSeconds), [150, 110, 90])
    }

    /// Участки, которые другие поездки почти не мерили (автостарт в полукило-
    /// метре от ворот), — не потеря: «обычно» там выдумано средним темпом.
    func testSegmentsOthersDidNotMeasureAreNotLosses() {
        let mine = usual([0: 90, 1: 90, 2: 90])
        let found = CommuteLoss.stretches(in: variant(mine: mine, unmeasured: [0, 1, 2]),
                                          tripID: tripID, calendar: utc)
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    /// Только поездки этого часа (±2 ч): с одними вечерними сравнивать утреннюю
    /// — не «в это же время»; тишина.
    func testOnlyAllDayRowsMeansSilence() {
        let mine = usual(Dictionary(uniqueKeysWithValues: (5...9).map { ($0, UInt16(60)) }))
        XCTAssertTrue(CommuteLoss.stretches(in: variant(mine: mine, morning: false),
                                            tripID: tripID, calendar: utc).isEmpty)
    }

    /// Места — у последней поездки и у медленных; у не медленных строки нет.
    func testPlacesOnlyForTheLastAndSlowerTrips() {
        let mine = usual(Dictionary(uniqueKeysWithValues: (5...9).map { ($0, UInt16(60)) }))
        let v = variant(mine: mine)
        XCTAssertEqual(CommuteLoss.places(for: [(id: tripID, slower: false)], lastID: tripID, in: [v],
                                          calendar: utc).keys.sorted(), [tripID])
        XCTAssertTrue(CommuteLoss.places(for: [(id: tripID, slower: false)], lastID: 1, in: [v],
                                         calendar: utc).isEmpty, "не последняя и не медленная")
        XCTAssertEqual(CommuteLoss.places(for: [(id: tripID, slower: true)], lastID: 1, in: [v],
                                          calendar: utc)[tripID]?.count, 1, "у медленной — одно место")
    }

    /// Сравниваем с поездками этого часа: вечерние втрое дольше и в утреннее
    /// «обычно» не входят — иначе утренняя пробка спряталась бы за вечерней.
    func testComparedWithThisHourOnly() {
        let mine = usual(Dictionary(uniqueKeysWithValues: (5...9).map { ($0, UInt16(50)) }))
        let found = CommuteLoss.stretches(in: variant(mine: mine), tripID: tripID, calendar: utc)
        XCTAssertEqual(found.first?.lostSeconds ?? 0, 150, accuracy: 0.5)
    }

    /// Сравнить не с чем — тишина, а не «вся дорога — потеря».
    func testNeedsThreeOtherTrips() {
        let mine = usual(Dictionary(uniqueKeysWithValues: (5...9).map { ($0, UInt16(60)) }))
        XCTAssertTrue(CommuteLoss.stretches(in: variant(mine: mine, others: [20, 21], evening: false),
                                            tripID: tripID, calendar: utc).isEmpty)
        XCTAssertTrue(CommuteLoss.stretches(in: variant(mine: mine), tripID: 12_345, calendar: utc).isEmpty,
                      "строки этой поездки в варианте нет")
    }

    /// Своя поездка в «обычно» не входит: другие — 20, 20 и 40 с (q75 30),
    /// наша — 40 с, то есть медленная. С нашей строкой q75 стал бы 40, и
    /// поездка спрятала бы собственную потерю. Края пути (по 400 м) — не
    /// дорога: место — участки 2…17.
    func testOwnRowIsNotPartOfUsual() {
        let mine = [UInt16](repeating: 40, count: 20)
        let report = CommuteLoss.report(in: variant(mine: mine, others: [20, 20, 40], evening: false),
                                        tripID: tripID, calendar: utc)
        XCTAssertEqual(report.stretches.first?.segments, 2...17)
        XCTAssertEqual(report.stretches.first?.lostSeconds ?? 0, 320, accuracy: 0.5)
        XCTAssertEqual(report.leaving, 0, "40 с у работы — меньше минуты, не строка")
        XCTAssertEqual(report.arriving, 0)
    }

    /// Снимок владельца (10.11): «+10 мин — 100 м от работы». Это середина
    /// участка 0–200 м, куда ложится всё до начала движения: прогрев, ворота,
    /// выезд со стоянки. В места не идёт — называется отдельно.
    func testLeavingTheParkingIsNotARoadLoss() {
        let mine = usual([0: 620])
        let report = CommuteLoss.report(in: variant(mine: mine), tripID: tripID, calendar: utc)
        XCTAssertTrue(report.stretches.isEmpty, "\(report.stretches)")
        XCTAssertEqual(report.leaving, 600, accuracy: 0.5)
        XCTAssertEqual(report.arriving, 0)
    }

    /// То же у финиша: круги в поисках места у дома — не пробка; а пробка за
    /// 400 м до конца — пробка.
    func testArrivingEdgeIsSeparateRoadBeforeItIsNot() {
        let mine = usual([19: 200, 18: 200, 16: 80, 17: 80])
        let report = CommuteLoss.report(in: variant(mine: mine), tripID: tripID, calendar: utc)
        XCTAssertEqual(report.stretches.map(\.segments), [16...17])
        XCTAssertEqual(report.stretches.first?.lostSeconds ?? 0, 120, accuracy: 0.5)
        XCTAssertEqual(report.arriving, 360, accuracy: 0.5)
        XCTAssertEqual(report.leaving, 0)
    }

    /// Разбор по варианту, где лежит строка поездки; нет строки — nil.
    func testReportForTripFindsItsVariant() {
        let v = variant(mine: usual([0: 620]))
        XCTAssertEqual(CommuteLoss.report(for: tripID, in: [v], calendar: utc)?.leaving ?? 0, 600, accuracy: 0.5)
        XCTAssertNil(CommuteLoss.report(for: 12_345, in: [v], calendar: utc))
    }
}
