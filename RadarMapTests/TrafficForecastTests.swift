//
//  TrafficForecastTests.swift
//  RadarMapTests
//
//  Пробки в ETA любого маршрута (27.E): свежие живые — на ближние полчаса
//  пути, дальше и при старом now.json — обычная скорость часа того момента,
//  когда до участка доедем; «выехать в 8:30» — только «обычно»; ничего нет —
//  nil, а не «пробок нет». Свободный поток время не трогает.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class TrafficForecastTests: XCTestCase {

    private let base = CLLocationCoordinate2D(latitude: 41.3000, longitude: 69.2800)
    private let tashkent = TypicalTraffic.tashkent
    private let wd8 = TypicalTraffic.Bucket(dayOff: false, hour: 8)
    private let wd9 = TypicalTraffic.Bucket(dayOff: false, hour: 9)

    private func north(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: base.latitude + meters / 111_320, longitude: base.longitude)
    }

    /// Маршрут на север: 4 км, точка каждые 100 м.
    private var route: [CLLocationCoordinate2D] { stride(from: 0.0, through: 4000, by: 100).map { north($0) } }

    /// Рёбра по 100 м на [from, to) на север.
    private func edges(from: Double = 0, to: Double = 4000, level: Int, kmh: Double,
                       model: Double = 60) -> [TrafficEdge] {
        stride(from: from, to: to, by: 100).map {
            TrafficEdge(a: north($0), b: north($0 + 100), level: level, kmh: kmh, modelKmh: model)
        }
    }

    /// Среда 14.10.2026 (13-е — вторник, 16-е — пятница, 17-е — суббота), 8:10 по Ташкенту.
    private func at(hour: Int, minute: Int = 10, day: Int = 14) -> Date {
        tashkent.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func snapshot(_ edges: [TrafficEdge], generated: Date) -> TrafficSnapshot {
        TrafficSnapshot(generated: generated, edges: edges)
    }

    /// Файл «обычно» по правилам разбора: уровень — из отношения к графу.
    private func typicalFile(kmh: Double, model: Double = 60, from: Double = 0, to: Double = 4000) -> TrafficSnapshot {
        let raw = stride(from: from, to: to, by: 100).map { y -> TrafficEdge in
            TrafficEdge(a: north(y), b: north(y + 100),
                        level: TrafficSnapshot.level(kmh: kmh, modelKmh: model), kmh: kmh, modelKmh: model)
        }
        return TrafficSnapshot(generated: at(hour: 3), edges: raw)
    }

    private func forecast(baseTime: TimeInterval = 240, departure: Date? = nil, now: Date? = nil,
                          live: TrafficSnapshot? = nil,
                          typical: [TypicalTraffic.Bucket: TrafficSnapshot] = [:],
                          asked: ((TypicalTraffic.Bucket) -> Void)? = nil) -> TrafficForecast.Delay? {
        let now = now ?? at(hour: 8)
        return TrafficForecast.delay(along: route, baseTime: baseTime, departure: departure ?? now, now: now,
                                     live: live, typical: { bucket in
                                         asked?(bucket)
                                         return typical[bucket]
                                     })
    }

    // MARK: - Нет данных

    func testNothingKnownIsNilNotZero() {
        XCTAssertNil(forecast(), "нет ни живых, ни «обычно» — нет данных, а не «пробок нет»")
        XCTAssertNil(TrafficForecast.delay(along: [north(0)], baseTime: 60, departure: at(hour: 8),
                                           now: at(hour: 8), live: nil, typical: { _ in nil }))
    }

    // MARK: - Живые

    func testFreshLiveMatchesTheOldDelay() throws {
        let live = snapshot(edges(from: 1000, to: 2000, level: 3, kmh: 10), generated: at(hour: 8, minute: 5))
        let delay = try XCTUnwrap(forecast(live: live))
        XCTAssertEqual(delay.source, .live)
        XCTAssertEqual(delay.seconds, live.delay(along: route), accuracy: 0.5,
                       "короткий маршрут целиком в горизонте — то же, что до 27.E")
        XCTAssertEqual(delay.seconds, 1000 / (10 / 3.6) - 1000 / (60 / 3.6), accuracy: 2)
    }

    func testFreshFreeLiveBeatsATypicalJam() throws {
        // Свежие живые на нашем пути пробки не нашли — обычную поверх не кладём.
        let live = snapshot([], generated: at(hour: 8, minute: 5))
        let delay = try XCTUnwrap(forecast(live: live, typical: [wd8: typicalFile(kmh: 10)]))
        XCTAssertEqual(delay.source, .live)
        XCTAssertEqual(delay.seconds, 0)
    }

    // MARK: - Обычно

    func testStaleLiveFallsBackToTheHour() throws {
        let stale = snapshot(edges(level: 3, kmh: 5), generated: at(hour: 7, minute: 40))
        var asked: Set<TypicalTraffic.Bucket> = []
        let delay = try XCTUnwrap(forecast(live: stale, typical: [wd8: typicalFile(kmh: 20)],
                                           asked: { asked.insert($0) }))
        XCTAssertEqual(delay.source, .typical, "now.json старше 10 минут — «обычно» часа")
        XCTAssertEqual(asked, [wd8])
        XCTAssertEqual(delay.seconds, 4000 / (20 / 3.6) - 4000 / (60 / 3.6), accuracy: 3)
    }

    func testFreeHourAddsNothing() throws {
        let delay = try XCTUnwrap(forecast(typical: [wd8: typicalFile(kmh: 50)]))
        XCTAssertEqual(delay.source, .typical)
        XCTAssertEqual(delay.seconds, 0, "обычно едут почти как граф — время не трогаем")
    }

    func testOldFileWithoutGraphSpeedAddsNothing() throws {
        // Файл до 27.E: modelKmh = kmh, уровень 1 — сравнивать не с чем.
        let old = TrafficSnapshot(generated: at(hour: 3), edges: edges(level: 1, kmh: 12, model: 12))
        XCTAssertEqual(try XCTUnwrap(forecast(typical: [wd8: old])).seconds, 0)
    }

    func testLaterDepartureIgnoresLiveTraffic() throws {
        // Сейчас вечер с пробкой, а выезд — завтра в 8:30.
        let now = at(hour: 19, day: 13)
        let live = snapshot(edges(level: 3, kmh: 5), generated: now)
        let departure = at(hour: 8, minute: 30)
        let delay = try XCTUnwrap(forecast(departure: departure, now: now, live: live,
                                           typical: [wd8: typicalFile(kmh: 30)]))
        XCTAssertEqual(delay.source, .typical)
        XCTAssertEqual(delay.seconds, 4000 / (30 / 3.6) - 4000 / (60 / 3.6), accuracy: 3)
        XCTAssertNil(forecast(departure: departure, now: now, live: live),
                     "без файла часа выезда — данных нет: вечерняя пробка к утру не относится")
    }

    func testRouteThroughTheHourTakesTheNextFile() throws {
        // Выезд 8:50, по графу 20 минут: первая половина пути — до 9:00.
        var asked: Set<TypicalTraffic.Bucket> = []
        let files = [wd8: typicalFile(kmh: 50), wd9: typicalFile(kmh: 15)]
        let delay = try XCTUnwrap(forecast(baseTime: 1200, departure: at(hour: 8, minute: 50),
                                           typical: files,
                                           asked: { asked.insert($0) }))
        XCTAssertEqual(asked, [wd8, wd9])
        XCTAssertEqual(delay.source, .typical)
        XCTAssertGreaterThan(delay.seconds, 0, "в 9:00 обычно стоят")
        XCTAssertLessThan(delay.seconds, 4000 / (15 / 3.6) - 4000 / (60 / 3.6), "но только на второй половине")
    }

    func testDayOffUsesTheWeekendFile() throws {
        let saturday = at(hour: 8, day: 17)
        let off8 = TypicalTraffic.Bucket(dayOff: true, hour: 8)
        var asked: Set<TypicalTraffic.Bucket> = []
        _ = forecast(departure: saturday, now: saturday, asked: { asked.insert($0) })
        XCTAssertEqual(asked, [off8])
    }

    // MARK: - Вместе

    func testLongRouteIsLiveNearAndTypicalFar() throws {
        // По графу час: первые полчаса — живые, дальше — обычно.
        let now = at(hour: 8, minute: 0)
        let live = snapshot(edges(level: 3, kmh: 10), generated: now)
        let delay = try XCTUnwrap(forecast(baseTime: 3600, now: now, live: live,
                                           typical: [wd8: typicalFile(kmh: 40), wd9: typicalFile(kmh: 40)]))
        XCTAssertEqual(delay.source, .mixed)
        XCTAssertLessThan(delay.seconds, live.delay(along: route), "дальняя часть — по обычной скорости")
    }

    func testWithoutTheHourFileFarPartStaysLive() throws {
        let now = at(hour: 8, minute: 0)
        let live = snapshot(edges(level: 3, kmh: 10), generated: now)
        let delay = try XCTUnwrap(forecast(baseTime: 3600, now: now, live: live))
        XCTAssertEqual(delay.source, .live, "файла нет — как до 27.E, живые на всём пути")
        XCTAssertEqual(delay.seconds, live.delay(along: route), accuracy: 0.5)
    }

    func testOncomingTypicalJamIsNotOurs() throws {
        let raw = stride(from: 0.0, to: 4000, by: 100).map {
            TrafficEdge(a: north($0 + 100), b: north($0), level: 3, kmh: 5, modelKmh: 60)
        }
        let oncoming = TrafficSnapshot(generated: at(hour: 3), edges: raw)
        XCTAssertEqual(try XCTUnwrap(forecast(typical: [wd8: oncoming])).seconds, 0)
    }

    // MARK: - Какие файлы спросить

    func testBucketsCoverTheTripWithMargin() {
        let names = { (set: Set<TypicalTraffic.Bucket>) in set.map(\.name).sorted() }
        XCTAssertEqual(names(TrafficForecast.buckets(departure: at(hour: 8, minute: 40), travelTime: 1000)),
                       ["wd-08", "wd-09"], "17 мин с запасом в полтора раза — через 9:00")
        XCTAssertEqual(names(TrafficForecast.buckets(departure: at(hour: 8, minute: 10), travelTime: 600)),
                       ["wd-08"])
        XCTAssertEqual(names(TrafficForecast.buckets(departure: at(hour: 8, minute: 40), travelTime: 9 * 3600)),
                       ["wd-08", "wd-09", "wd-10", "wd-11"], "не дальше трёх часов пути")
        // Пятница 23:30 → суббота 0:00 — выходной файл.
        XCTAssertEqual(names(TrafficForecast.buckets(departure: at(hour: 23, minute: 30, day: 16), travelTime: 1800)),
                       ["off-00", "wd-23"])
    }

    // MARK: - Разбор «обычно» с графом

    func testTypicalFileCarriesGraphSpeedAndLevel() throws {
        let body = #"{"v":1,"bucket":"wd-08","generated":1760000000,"edges":[[41.3,69.2,41.301,69.2,12,60],[41.3,69.2,41.301,69.2,50,60],[41.3,69.2,41.301,69.2,30],[41.3,69.2,41.301,69.2,30,0]]}"#
        let file = try XCTUnwrap(TypicalTraffic.decode(Data(body.utf8), expected: wd8))
        let edges = file.snapshot.edges
        XCTAssertEqual(edges.map(\.level), [3, 1, 1, 1])
        XCTAssertEqual(edges.map(\.modelKmh), [60, 60, 30, 30], "нет или 0 — граф неизвестен, задержки нет")
    }
}
