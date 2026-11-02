//
//  ReportTrackTests.swift
//  RadarMapTests
//
//  Место отметки по своему треку от момента касания (картограф, A4) и снап с
//  учётом одностороннего движения (A5).
//

import CoreLocation
import XCTest
@testable import RadarMap

final class ReportTrackTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let start = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.20)

    private func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    /// Едем на север 50 км/ч (≈ 13,9 м/с), фикс раз в секунду, 10 секунд.
    private func northTrack(speed: Double = 13.9, seconds: Int = 10) -> ReportTrack {
        var track = ReportTrack()
        for second in 0...seconds {
            track.append(GeoMath.destination(from: start, bearing: 0, distanceMeters: speed * Double(second)),
                         at: t0.addingTimeInterval(Double(second)))
        }
        return track
    }

    /// Точка — там, где машина была в «касание − реакция», а не на последнем фиксе.
    func testPointIsWhereTheCarWasReactionAgo() throws {
        let track = northTrack()
        let touch = t0.addingTimeInterval(10)
        let placed = try XCTUnwrap(ReportTrack.position(in: track.points, touch: touch, reaction: 3.5))
        let expected = GeoMath.destination(from: start, bearing: 0, distanceMeters: 13.9 * 6.5)
        XCTAssertLessThan(meters(placed, expected), 1)
    }

    /// Старый фикс учтён правильно: касание через 1,5 с после последнего фикса
    /// сдвигает меньше, а не больше (была ошибка знака).
    func testFixAgeShortensTheShift() throws {
        let track = northTrack()
        let newest = try XCTUnwrap(track.points.last?.coordinate)
        let late = try XCTUnwrap(ReportTrack.position(in: track.points, touch: t0.addingTimeInterval(11.5),
                                                      reaction: 3.5))
        XCTAssertEqual(meters(late, newest), 13.9 * 2, accuracy: 1)
    }

    /// Вперёд от последнего фикса не экстраполируем никогда.
    func testNeverAheadOfTheNewestFix() throws {
        let track = northTrack()
        let newest = try XCTUnwrap(track.points.last?.coordinate)
        let placed = try XCTUnwrap(ReportTrack.position(in: track.points, touch: t0.addingTimeInterval(20),
                                                        reaction: 3.5))
        XCTAssertLessThan(meters(placed, newest), 0.01)
    }

    /// Потолок 150 м по треку — и на 130 км/ч с Siri.
    func testShiftIsCappedAlongTheTrack() throws {
        let track = northTrack(speed: 36, seconds: 14)
        let newest = try XCTUnwrap(track.points.last?.coordinate)
        let placed = try XCTUnwrap(ReportTrack.position(in: track.points, touch: t0.addingTimeInterval(14),
                                                        reaction: 6.5))
        XCTAssertEqual(meters(placed, newest), AppConfig.reportMaxBackMeters, accuracy: 1)
    }

    /// Свернул сразу после треноги — точка остаётся на её улице, а не уходит
    /// по прямой на поперечную.
    func testTurnKeepsThePointOnTheStreetOfTheTripod() throws {
        var track = ReportTrack()
        // 5 с на север, потом 5 с на восток.
        var point = start
        for second in 0...10 {
            track.append(point, at: t0.addingTimeInterval(Double(second)))
            point = GeoMath.destination(from: point, bearing: second < 5 ? 0 : 90, distanceMeters: 13.9)
        }
        let placed = try XCTUnwrap(ReportTrack.position(in: track.points, touch: t0.addingTimeInterval(10),
                                                        reaction: 7))
        XCTAssertEqual(placed.longitude, start.longitude, accuracy: 1e-6, "на северной улице, до поворота")
    }

    /// Трека нет — сдвиг по прямой на то же время, с тем же потолком.
    func testWithoutTrackFallsBackToStraightLine() {
        let now = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.2)
        let placed = ReportTrack.origin(points: [], touch: t0, reaction: 3.5, coordinate: now, course: 0,
                                        speedKmh: 50)
        XCTAssertEqual(meters(placed, now), 50 / 3.6 * 3.5, accuracy: 1)
        XCTAssertLessThan(placed.latitude, now.latitude, "назад по курсу")
        let slow = ReportTrack.origin(points: [], touch: t0, reaction: 3.5, coordinate: now, course: 0, speedKmh: 5)
        XCTAssertEqual(slow.latitude, now.latitude, "в пробке «три секунды назад» — то же место")
    }

    /// Кольцо держит только последние секунды.
    func testTrackForgetsOldFixes() {
        var track = ReportTrack()
        for second in 0...40 {
            track.append(start, at: t0.addingTimeInterval(Double(second)))
        }
        XCTAssertLessThanOrEqual(track.points.count, Int(AppConfig.reportTrackSeconds) + 1)
        track.append(start, at: t0)
        XCTAssertEqual(track.points.last?.at, t0.addingTimeInterval(40), "запоздавший фикс не ломает порядок")
    }

    // MARK: - Снап с односторонним движением (A5)

    private func line(_ lon: Double, northbound: Bool, level: Int = 0) -> RoadLine {
        let south = CLLocationCoordinate2D(latitude: 41.30, longitude: lon)
        let north = CLLocationCoordinate2D(latitude: 41.32, longitude: lon)
        var road = RoadLine(points: northbound ? [south, north] : [north, south], kind: .primary)
        road.isOneWay = true
        road.level = level
        return road
    }

    /// Разделённый проспект: встречное полотно ближе, но мы едем на север —
    /// садимся на своё.
    func testOneWayAgainstCourseIsNotOurs() throws {
        let ours = line(69.2500, northbound: true)
        let oncoming = line(69.2502, northbound: false)
        let raw = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.25018)
        let placed = try XCTUnwrap(ReportPlacement.snapped(raw, course: 2, roads: [ours, oncoming], maxMeters: 40))
        XCTAssertEqual(placed.coordinate.longitude, 69.2500, accuracy: 1e-7)
        // Едем на юг — то же место садится на другое полотно.
        let south = try XCTUnwrap(ReportPlacement.snapped(raw, course: 182, roads: [ours, oncoming], maxMeters: 40))
        XCTAssertEqual(south.coordinate.longitude, 69.2502, accuracy: 1e-7)
    }

    /// Курса нет — направление не проверяем: ближайшая ось.
    func testWithoutCourseOneWayIsNotFiltered() throws {
        let raw = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.25018)
        let placed = try XCTUnwrap(ReportPlacement.snapped(raw, course: -1,
                                                           roads: [line(69.2500, northbound: true),
                                                                   line(69.2502, northbound: false)],
                                                           maxMeters: 40))
        XCTAssertEqual(placed.coordinate.longitude, 69.2502, accuracy: 1e-7)
    }

    /// При почти равном расстоянии земля бьёт эстакаду.
    func testGroundBeatsBridgeAtNearlyEqualDistance() throws {
        let bridge = line(69.25001, northbound: true, level: 1)
        let ground = line(69.25003, northbound: true, level: 0)
        let raw = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.25001)
        let placed = try XCTUnwrap(ReportPlacement.snapped(raw, course: 0, roads: [bridge, ground], maxMeters: 40))
        XCTAssertEqual(placed.coordinate.longitude, 69.25003, accuracy: 1e-7)
    }
}
