//
//  TypicalTrafficTests.swift
//  RadarMapTests
//
//  «Обычно ~35 мин (по водителям)» (8.8.16): файл часа по Ташкенту и классу
//  дня, сумма времени по своей линии, встречная полоса и соседняя улица не
//  наши, мало покрытия — нет оценки вовсе, а не выдуманное число.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class TypicalTrafficTests: XCTestCase {
    private let lat = 41.30, lon0 = 69.20
    private var k: Double { 111_320 * cos(lat * .pi / 180) }
    private let tashkent = TypicalTraffic.tashkent

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        tashkent.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: 10))!
    }

    private func point(_ x: Double, north: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat + north / 111_320, longitude: lon0 + x / k)
    }

    /// Своя линия: прямая на восток длиной `meters`, точка каждые 50 м.
    private func line(_ meters: Double = 4000) -> [CLLocationCoordinate2D] {
        stride(from: 0.0, through: meters, by: 50).map { point($0) }
    }

    /// Рёбра по 100 м на [from, to); `westbound` — встречное направление,
    /// `north` — сдвиг вбок (соседняя улица).
    private func typical(from: Double = 0, to: Double = 4000, kmh: Double = 40,
                         westbound: Bool = false, north: Double = 0,
                         bucket: TypicalTraffic.Bucket = .init(dayOff: false, hour: 8)) -> TypicalTraffic {
        var edges: [TrafficEdge] = []
        var x = from
        while x < to {
            let (a, b) = westbound ? (point(x + 100, north: north), point(x, north: north))
                                   : (point(x, north: north), point(x + 100, north: north))
            edges.append(TrafficEdge(a: a, b: b, level: 1, kmh: kmh, modelKmh: kmh))
            x += 100
        }
        return TypicalTraffic(bucket: bucket, snapshot: TrafficSnapshot(generated: Date(), edges: edges))
    }

    // MARK: - Час

    func testBucketIsTashkentHourAndDayClass() {
        // Понедельник 12.10.2026, 8:10 по Ташкенту.
        XCTAssertEqual(TypicalTraffic.bucket(for: date(2026, 10, 12, 8)).name, "wd-08")
        // Суббота — выходные.
        XCTAssertEqual(TypicalTraffic.bucket(for: date(2026, 10, 17, 8)).name, "off-08")
        XCTAssertEqual(TypicalTraffic.bucket(for: date(2026, 10, 18, 18)).name, "off-18")
        // День знаний, 1 сентября 2026 — вторник, но праздник: дороги как в выходной.
        XCTAssertEqual(TypicalTraffic.bucket(for: date(2026, 9, 1, 9)).name, "off-09")
        XCTAssertEqual(TypicalTraffic.Bucket(dayOff: false, hour: 7).path, "traffic/typical/wd-07.json")
    }

    /// Час — ташкентский, как у сервера, в каком бы поясе ни был телефон.
    func testBucketIgnoresDeviceTimeZone() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let morning = utc.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 3, minute: 10))!
        XCTAssertEqual(TypicalTraffic.bucket(for: morning).name, "wd-08")
    }

    // MARK: - Разбор

    func testDecodeKeepsOnlyItsOwnHourAndFormat() throws {
        let wd8 = TypicalTraffic.Bucket(dayOff: false, hour: 8)
        let body = #"{"v":1,"bucket":"wd-08","generated":1760000000,"edges":[[41.3,69.2,41.3,69.201,37],[41.3,69.2,41.3,69.201,0]]}"#
        let decoded = try XCTUnwrap(TypicalTraffic.decode(Data(body.utf8), expected: wd8))
        XCTAssertEqual(decoded.snapshot.edges.count, 1, "скорость 0 — битое ребро, не «стоим всегда»")
        XCTAssertEqual(decoded.snapshot.edges.first?.kmh, 37)
        XCTAssertNil(TypicalTraffic.decode(Data(body.utf8), expected: .init(dayOff: true, hour: 8)),
                     "чужой час — не наш файл")
        XCTAssertNil(TypicalTraffic.decode(Data(body.replacingOccurrences(of: "\"v\":1", with: "\"v\":2").utf8),
                                           expected: wd8), "другой формат — нет данных")
        XCTAssertNil(TypicalTraffic.decode(Data("<html>404</html>".utf8), expected: wd8))
        let empty = #"{"v":1,"bucket":"wd-08","generated":1760000000,"edges":[]}"#
        let none = try XCTUnwrap(TypicalTraffic.decode(Data(empty.utf8), expected: wd8))
        XCTAssertNil(TypicalTraffic.travelTime(along: line(), typical: none), "пустой час — оценки нет")
    }

    // MARK: - Время по линии

    func testFullyCoveredLineSumsTime() throws {
        // 4 км на 40 км/ч — 360 с, ровно 6 минут.
        let estimate = try XCTUnwrap(TypicalTraffic.travelTime(along: line(), typical: typical()))
        XCTAssertEqual(estimate.seconds, 360)
        XCTAssertGreaterThan(estimate.coverage, 0.95)
        // Пробка на половине пути: 2 км на 10 км/ч + 2 км на 40 — 720 + 180 = 900 с.
        var edges = typical(from: 0, to: 2000, kmh: 10).snapshot.edges
        edges += typical(from: 2000, to: 4000, kmh: 40).snapshot.edges
        let mixed = TypicalTraffic(bucket: .init(dayOff: false, hour: 8),
                                   snapshot: TrafficSnapshot(generated: Date(), edges: edges))
        XCTAssertEqual(try XCTUnwrap(TypicalTraffic.travelTime(along: line(), typical: mixed)).seconds, 900)
    }

    /// Покрыто 70 % — хвост едет в темпе покрытого; 40 % — оценки нет.
    func testPartialCoverageScalesOrRefuses() throws {
        let most = try XCTUnwrap(TypicalTraffic.travelTime(along: line(), typical: typical(from: 0, to: 2800)))
        XCTAssertEqual(most.seconds, 360, "тот же темп на непокрытом хвосте")
        XCTAssertEqual(most.coverage, 0.7, accuracy: 0.02)
        XCTAssertNil(TypicalTraffic.travelTime(along: line(), typical: typical(from: 0, to: 1600)),
                     "по 40 % пути «обычно» — выдумка")
    }

    /// Встречная полоса проспекта и параллельная улица в 40 м — не наша дорога.
    func testOtherDirectionAndNeighbourStreetAreNotOurs() {
        XCTAssertNil(TypicalTraffic.travelTime(along: line(), typical: typical(westbound: true)))
        XCTAssertNil(TypicalTraffic.travelTime(along: line(), typical: typical(north: 40)))
    }

    func testTooShortLineHasNoEstimate() {
        XCTAssertNil(TypicalTraffic.travelTime(along: line(600), typical: typical()))
        XCTAssertNil(TypicalTraffic.travelTime(along: [point(0)], typical: typical()))
    }

    // MARK: - Линия

    func testLineIsTheMostDrivenVariant() throws {
        func variant(_ meters: Double, rows: [Date], lastUsed: Date) -> CommuteProfile.Variant {
            var packed: [Int32] = []
            for p in line(meters) {
                packed.append(Int32((p.latitude * 1e5).rounded()))
                packed.append(Int32((p.longitude * 1e5).rounded()))
            }
            let rowList = rows.enumerated().map { index, departure in
                CommuteProfile.Row(tripID: Double(index), departure: departure, weekend: false,
                                   arrivalMinute: 0, seconds: [20])
            }
            return CommuteProfile.Variant(id: UUID(), line: packed, ends: [Float(meters)], limitKmh: [0],
                                          rows: rowList, lastUsed: lastUsed)
        }
        let often = variant(4000, rows: [date(2026, 10, 12, 8), date(2026, 10, 13, 8)],
                            lastUsed: date(2026, 10, 13, 8))
        let once = variant(3000, rows: [date(2026, 10, 14, 7)], lastUsed: date(2026, 10, 14, 7))
        let picked = try XCTUnwrap(TypicalTraffic.line(of: [once, often]))
        XCTAssertEqual(picked.coordinates.count, often.coordinates.count)
        XCTAssertEqual(picked.lastDeparture, date(2026, 10, 13, 8))
        XCTAssertNil(TypicalTraffic.line(of: []), "нет пути — нет и оценки, маршрут ради неё не строится")
    }
}
