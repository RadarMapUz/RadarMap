//
//  RouteProgressBarTests.swift
//  RadarMapTests
//
//  Полоса хода маршрута (29.B): «нет данных» никогда не зелёное, отрезки
//  покрывают маршрут без дыр и наложений, встречных камер нет, значки не
//  слипаются, отметка «я» двигается шагами, без места полосы нет.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class RouteProgressBarTests: XCTestCase {

    private func piece(_ level: Int, _ from: Double, _ to: Double) -> RouteTraffic.Piece {
        RouteTraffic.Piece(level: level, coordinates: [], from: from, to: to)
    }

    func testNoTrafficDataIsNeutralNotGreen() {
        let layout = RouteProgressBar.layout(length: 1000, pieces: [], cameras: [], minGap: 0)
        XCTAssertEqual(layout.segments, [.init(from: 0, to: 1, tone: .unknown)])
    }

    func testSegmentsCoverTheRouteWithoutGapsOrOverlaps() {
        let layout = RouteProgressBar.layout(
            length: 1000, pieces: [piece(3, 600, 700), piece(1, 100, 300), piece(2, 280, 400)],
            cameras: [], minGap: 0)
        XCTAssertEqual(layout.segments.first?.from, 0)
        XCTAssertEqual(layout.segments.last?.to, 1)
        for (a, b) in zip(layout.segments, layout.segments.dropFirst()) {
            XCTAssertEqual(a.to, b.from, accuracy: 1e-9)
            XCTAssertNotEqual(a.tone, b.tone, "соседние отрезки одного цвета склеиваются")
        }
        XCTAssertEqual(layout.segments.map(\.tone), [.unknown, .free, .slow, .unknown, .jam, .unknown])
        // Наложение (280–300) отдано первому куску, второй начинается после него.
        XCTAssertEqual(layout.segments[2].from, 0.3, accuracy: 1e-9)
    }

    func testPiecePastTheEndIsClipped() {
        let layout = RouteProgressBar.layout(length: 1000, pieces: [piece(2, 900, 1200)], cameras: [], minGap: 0)
        XCTAssertEqual(layout.segments.last, .init(from: 0.9, to: 1, tone: .slow))
    }

    func testCamerasPlacedByTheirPlaceAndThinned() {
        let cameras = [RouteProgressBar.CameraInput(id: 2, along: 505, kind: .stationaryRadar),
                       RouteProgressBar.CameraInput(id: 1, along: 500, kind: .stationaryCamera),
                       RouteProgressBar.CameraInput(id: 3, along: 900, kind: .tripod),
                       RouteProgressBar.CameraInput(id: 4, along: 1500, kind: .tripod)]
        let layout = RouteProgressBar.layout(length: 1000, pieces: [], cameras: cameras, minGap: 0.02)
        // Ближе 2 % к предыдущей — остаётся первая по ходу; за финишем — нет.
        XCTAssertEqual(layout.cameras.map(\.id), [1, 3])
        XCTAssertEqual(layout.cameras.first?.fraction ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(RouteProgressBar.thinned(RouteProgressBar.layout(length: 1000, pieces: [], cameras: cameras,
                                                                        minGap: 0).cameras, minGap: 0.5).map(\.id),
                       [1])
    }

    func testBuildIgnoresFreeFlowOnlyWhenThereIsNoSnapshot() {
        let route = [CLLocationCoordinate2D(latitude: 41.30, longitude: 69.28),
                     CLLocationCoordinate2D(latitude: 41.31, longitude: 69.28)]
        let layout = RouteProgressBar.build(route: route, cumulative: [0, 1110], snapshot: nil,
                                            cameras: [], minGap: 0)
        XCTAssertEqual(layout.length, 1110)
        XCTAssertEqual(layout.segments.map(\.tone), [.unknown])
        // Мера пройденного не совпала с линией — раскладки нет, а не кривая.
        XCTAssertEqual(RouteProgressBar.build(route: route, cumulative: [0], snapshot: nil, cameras: [], minGap: 0),
                       .empty)
    }

    func testProgressIsClampedAndStepped() {
        XCTAssertEqual(RouteProgressBar.fraction(progress: -5, length: 100), 0)
        XCTAssertEqual(RouteProgressBar.fraction(progress: 150, length: 100), 1)
        XCTAssertEqual(RouteProgressBar.fraction(progress: 50, length: 0), 0)
        // 200 pt, шаг 1 pt: сдвиг меньше половины пункта — та же доля.
        let a = RouteProgressBar.step(0.5000, height: 200, points: 1)
        let b = RouteProgressBar.step(0.5020, height: 200, points: 1)
        let c = RouteProgressBar.step(0.5060, height: 200, points: 1)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testRailNeedsRoomAndMeasuredEdges() {
        XCTAssertNil(RouteProgressBar.frame(columnBottom: 0, panelBottom: 600, gap: 14, minHeight: 120))
        XCTAssertNil(RouteProgressBar.frame(columnBottom: 400, panelBottom: 500, gap: 14, minHeight: 120))
        let frame = RouteProgressBar.frame(columnBottom: 300, panelBottom: 600, gap: 14, minHeight: 120)
        XCTAssertEqual(frame, 314...586)
    }

    func testOnlyFreeSlowAndJamLevelsHaveColour() {
        XCTAssertEqual(RouteProgressBar.Tone(level: nil), .unknown)
        XCTAssertEqual(RouteProgressBar.Tone(level: 0), .unknown)
        XCTAssertEqual(RouteProgressBar.Tone(level: 1), .free)
        XCTAssertEqual(RouteProgressBar.Tone(level: 3), .jam)
    }
}
