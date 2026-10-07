//
//  TimedTrackTests.swift
//  RadarMapTests
//
//  Подробный трек для видео регистратора: CSV туда-обратно без потерь и
//  GPX, который читают редакторы OSM и наш разбор видео.
//

import XCTest
@testable import RadarMap

final class TimedTrackTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_791_350_400)

    func testCSVRoundTrip() {
        let points = [TimedPoint(time: t0, lat: 41.311081, lon: 69.279737, speedKmh: 46),
                      TimedPoint(time: t0.addingTimeInterval(1), lat: 41.311200, lon: 69.279900, speedKmh: 47.5)]
        let back = TimedTrack.decode(TimedTrack.encode(points))
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[1].lat, 41.3112, accuracy: 1e-6)
        XCTAssertEqual(back[1].time.timeIntervalSince1970, t0.timeIntervalSince1970 + 1, accuracy: 0.1)
        XCTAssertEqual(back[1].speedKmh, 47.5, accuracy: 0.05)
    }

    func testBrokenLinesAreSkipped() {
        XCTAssertEqual(TimedTrack.decode("1,2\nмусор\n1791350400.0,41.3,69.2,10").count, 1)
    }

    func testGPXCarriesTimeAndCameraAnchors() {
        let gpx = TimedTrack.gpx(
            name: "A & B",
            points: [(41.3, 69.2, t0, 36), (41.31, 69.21, nil, 0)],
            waypoints: [.init(lat: 41.305, lon: 69.205, time: t0, name: "камера 7")])
        XCTAssertTrue(gpx.contains("<wpt lat=\"41.305000\" lon=\"69.205000\">"), "проезд камеры — опорная точка")
        XCTAssertTrue(gpx.contains("<time>2026-"), "у точки трека есть время")
        XCTAssertTrue(gpx.contains("A &amp; B"), "имя экранировано")
        XCTAssertEqual(gpx.components(separatedBy: "<trkpt").count - 1, 2)
        XCTAssertEqual(gpx.components(separatedBy: "<time>").count - 1, 2, "точка без времени — без <time>")
    }
}
