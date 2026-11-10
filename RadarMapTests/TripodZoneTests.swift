//
//  TripodZoneTests.swift
//  RadarMapTests
//
//  Участок треноги на асфальте (83): какая цель, где лежит участок (своя
//  проезжая часть по ходу, не встречка), его длина, мягкие концы, знак
//  лимита только известный — и что конвейер оповещений его не читает.
//

import XCTest
import MapKit
import CoreLocation
@testable import RadarMap

final class TripodZoneTests: XCTestCase {

    private let origin = CLLocationCoordinate2D(latitude: 41.315, longitude: 69.32)

    /// Точка в метрах от начала: x — на восток, y — на север.
    private func at(_ x: Double, _ y: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: origin.latitude + y / 111_320,
                               longitude: origin.longitude + x / (111_320 * cos(origin.latitude * .pi / 180)))
    }

    private func meters(_ point: CameraOnLine.Point) -> (x: Double, y: Double) {
        ((point.longitude - origin.longitude) * 111_320 * cos(origin.latitude * .pi / 180),
         (point.latitude - origin.latitude) * 111_320)
    }

    private func tripod(_ key: Int, _ x: Double, _ y: Double, _ grade: TripodZone.Grade = .confirmed) -> TripodZone.Candidate {
        TripodZone.Candidate(key: key, coordinate: at(x, y), grade: grade)
    }

    /// Дорога с востока на запад и обратно: линия от x0 до x1 на высоте y.
    private func road(_ x0: Double, _ x1: Double, y: Double, oneWay: Bool = false) -> RoadLine {
        let step = (x1 - x0) / 10
        return RoadLine(points: (0...10).map { at(x0 + Double($0) * step, y) }, kind: .primary, isOneWay: oneWay)
    }

    private func length(_ piece: TripodZone.Piece) -> Double {
        zip(piece.points, piece.points.dropFirst()).reduce(0) { sum, pair in
            let a = meters(pair.0), b = meters(pair.1)
            return sum + hypot(b.x - a.x, b.y - a.y)
        }
    }

    // MARK: - Цель

    func testWithCourseTheNearestTripodAheadWins() {
        // Едем на восток: позади, сбоку далеко и дальше по ходу — не цель.
        let target = TripodZone.target(
            tripods: [tripod(1, -300, 0), tripod(2, 900, 0), tripod(3, 400, 5), tripod(4, 200, 400)],
            hotspots: [], me: origin, course: 90, routeAlong: nil, progress: nil)
        XCTAssertEqual(target?.key, 3)
    }

    func testTripodBeatsHotspot() {
        let target = TripodZone.target(tripods: [tripod(1, 800, 0)],
                                       hotspots: [tripod(-5, 100, 0, .hotspot)],
                                       me: origin, course: 90, routeAlong: nil, progress: nil)
        XCTAssertEqual(target?.key, 1)
        let calm = TripodZone.target(tripods: [], hotspots: [tripod(-5, 100, 0, .hotspot)],
                                     me: origin, course: 90, routeAlong: nil, progress: nil)
        XCTAssertEqual(calm?.grade, .hotspot)
    }

    func testPassedTripodStaysUntilItsZoneIsBehind() {
        let justPassed = TripodZone.target(tripods: [tripod(1, -40, 0)], hotspots: [], me: origin,
                                           course: 90, routeAlong: nil, progress: nil)
        XCTAssertEqual(justPassed?.key, 1, "50 м после отметки — ещё участок")
        let gone = TripodZone.target(tripods: [tripod(1, -150, 0)], hotspots: [], me: origin,
                                     course: 90, routeAlong: nil, progress: nil)
        XCTAssertNil(gone)
    }

    func testWithoutCourseOnlyNearbyTarget() {
        XCTAssertEqual(TripodZone.target(tripods: [tripod(1, 0, -300)], hotspots: [], me: origin,
                                         course: -1, routeAlong: nil, progress: nil)?.key, 1)
        XCTAssertNil(TripodZone.target(tripods: [tripod(1, 0, -900)], hotspots: [], me: origin,
                                       course: -1, routeAlong: nil, progress: nil))
    }

    func testOnRouteOnlyTargetsOnTheLineAhead() {
        let along = [1: 300.0, 2: 1500.0, 3: 900.0]
        let target = TripodZone.target(tripods: [tripod(1, 0, 0), tripod(2, 0, 0), tripod(3, 0, 0), tripod(9, 0, 0)],
                                       hotspots: [], me: origin, course: 90, routeAlong: along, progress: 500)
        XCTAssertEqual(target?.key, 3, "позади на 200 м — уже нет; не на линии (9) — не цель")
    }

    func testHotspotKeysAreStableAndNegative() {
        let a = TripodZone.hotspotKey(latitude: 41.3, longitude: 69.2)
        XCTAssertEqual(a, TripodZone.hotspotKey(latitude: 41.30001, longitude: 69.20001))
        XCTAssertLessThan(a, 0)
        XCTAssertNotEqual(a, TripodZone.hotspotKey(latitude: 41.31, longitude: 69.2))
    }

    // MARK: - По линии маршрута

    func testRoutePieceIsBeforeAndAfterTheMark() throws {
        let route = (0...20).map { MKMapPoint(at(Double($0) * 100, 0)) }
        let along = try XCTUnwrap(TripodZone.along(of: at(1000, 20), route: route))
        XCTAssertEqual(along, 1000, accuracy: 5, "отметка на встречной половине — место на нашей линии")
        XCTAssertNil(TripodZone.along(of: at(1000, 80), route: route), "соседняя улица — не на маршруте")
        let piece = try XCTUnwrap(TripodZone.routePiece(route: route, along: along))
        XCTAssertTrue(piece.onRoute)
        XCTAssertEqual(meters(piece.points[0]).x, 800, accuracy: 2)
        XCTAssertEqual(meters(piece.points[piece.points.count - 1]).x, 1050, accuracy: 2)
        XCTAssertEqual(length(piece), AppConfig.tripodZoneBeforeMeters + AppConfig.tripodZoneAfterMeters, accuracy: 2)
    }

    func testRoutePieceAtTheVeryStartNeedsSomeRoadBefore() {
        let route = (0...20).map { MKMapPoint(at(Double($0) * 100, 0)) }
        XCTAssertNil(TripodZone.routePiece(route: route, along: 20))
        XCTAssertNotNil(TripodZone.routePiece(route: route, along: 120), "короче 200 м, но участок есть")
    }

    // MARK: - По сети дорог

    func testDividedRoadTakesOurCarriagewayNotTheOncoming() throws {
        // Проспект: север — на запад, юг — на восток (правостороннее). Едем на восток.
        let lines = [road(-400, 400, y: 0), road(400, -400, y: 20)]
        let pieces = TripodZone.roadPieces(lines: lines, tripod: at(0, 20), course: 90)
        let piece = try XCTUnwrap(pieces.first)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertTrue(piece.points.allSatisfy { abs(meters($0).y) < 1 }, "участок — на южной (нашей) оси")
        XCTAssertEqual(piece.offsetMeters, 0, "у разделённой дороги ось — вся проезжая часть")
        XCTAssertLessThan(meters(piece.points[0]).x, meters(piece.points[piece.points.count - 1]).x, "по ходу")
        XCTAssertEqual(meters(piece.points[0]).x, -200, accuracy: 2)
        XCTAssertEqual(meters(piece.points[piece.points.count - 1]).x, 50, accuracy: 2)
    }

    func testOncomingOneWayIsNeverOurs() {
        // Одна односторонняя ось на запад — встречка; наша в данных не пришла.
        XCTAssertTrue(TripodZone.roadPieces(lines: [road(400, -400, y: 0, oneWay: true)],
                                            tripod: at(0, 0), course: 90).isEmpty)
    }

    func testSingleTwoWayRoadGetsOurHalf() throws {
        let pieces = TripodZone.roadPieces(lines: [road(-400, 400, y: 0)], tripod: at(0, 0), course: 90)
        let piece = try XCTUnwrap(pieces.first)
        XCTAssertEqual(piece.offsetMeters, piece.widthMeters / 2, accuracy: 0.01, "правая половина")
        XCTAssertGreaterThan(piece.offsetMeters, 0)
    }

    func testCrossStreetIsNotOurs() {
        XCTAssertTrue(TripodZone.roadPieces(lines: [RoadLine(points: [at(0, -300), at(0, 300)], kind: .primary)],
                                            tripod: at(0, 0), course: 90).isEmpty)
    }

    func testWithoutCourseEachCarriagewayByItsOwnFlow() throws {
        let lines = [road(-400, 400, y: 0, oneWay: true), road(400, -400, y: 20, oneWay: true)]
        let pieces = TripodZone.roadPieces(lines: lines, tripod: at(0, 10), course: -1)
        XCTAssertEqual(pieces.count, 2)
        for piece in pieces {
            let first = meters(piece.points[0]), last = meters(piece.points[piece.points.count - 1])
            if first.y < 10 {
                XCTAssertLessThan(first.x, last.x, "южная — на восток")
            } else {
                XCTAssertGreaterThan(first.x, last.x, "северная — на запад")
            }
        }
    }

    func testPieceContinuesAcrossCutRoad() throws {
        // OSM режет дорогу на перекрёстке: две оси встык, отметка у начала второй.
        let lines = [road(-400, 0, y: 0), road(0, 400, y: 0)]
        let piece = try XCTUnwrap(TripodZone.roadPieces(lines: lines, tripod: at(30, 0), course: 90).first)
        XCTAssertEqual(meters(piece.points[0]).x, -170, accuracy: 2, "участок продолжен через стык")
    }

    // MARK: - Концы, лимит, ступени

    func testRampsAreSoftAtBothEndsAndCoverThePiece() throws {
        let route = (0...20).map { MKMapPoint(at(Double($0) * 100, 0)) }
        let piece = try XCTUnwrap(TripodZone.routePiece(route: route, along: 1000))
        let ramps = TripodZone.ramps(piece)
        XCTAssertLessThan(ramps.first?.alpha ?? 1, 0.5)
        XCTAssertLessThan(ramps.last?.alpha ?? 1, 0.5)
        XCTAssertEqual(ramps.map(\.alpha).max(), 1)
        let total = ramps.reduce(0) { $0 + length(TripodZone.Piece(points: $1.points, widthMeters: 1,
                                                                    offsetMeters: 0, onRoute: true)) }
        XCTAssertEqual(total, length(piece), accuracy: 1)
    }

    func testLimitOnlyWhenKnownAndNeverOnHotspot() throws {
        let route = (0...20).map { MKMapPoint(at(Double($0) * 100, 0)) }
        let piece = try XCTUnwrap(TripodZone.routePiece(route: route, along: 1000))
        let known = TripodZone.band(candidate: tripod(1, 1000, 0), pieces: [piece]) { _, _ in 60 }
        XCTAssertEqual(known?.limits.first?.kmh, 60)
        // Справа от дороги по ходу (на восток — юг) и у начала участка.
        let sign = try XCTUnwrap(known?.limits.first)
        XCTAssertLessThan(meters(sign.point).y, -piece.widthMeters / 2)
        XCTAssertEqual(meters(sign.point).x, 800, accuracy: 2)
        XCTAssertEqual(TripodZone.band(candidate: tripod(1, 1000, 0), pieces: [piece]) { _, _ in nil }?.limits, [])
        XCTAssertEqual(TripodZone.band(candidate: tripod(-3, 1000, 0, .hotspot), pieces: [piece]) { _, _ in 60 }?
            .limits, [])
        XCTAssertNil(TripodZone.band(candidate: tripod(1, 1000, 0), pieces: []) { _, _ in 60 })
    }

    func testSameGeometrySameBand() throws {
        // Источник переписывается по неравенству участков: одинаковое — не трогаем.
        let route = (0...20).map { MKMapPoint(at(Double($0) * 100, 0)) }
        let piece = try XCTUnwrap(TripodZone.routePiece(route: route, along: 1000))
        let a = TripodZone.band(candidate: tripod(1, 1000, 0), pieces: [piece]) { _, _ in 60 }
        let b = TripodZone.band(candidate: tripod(1, 1000, 0), pieces: [piece]) { _, _ in 60 }
        XCTAssertEqual(a, b)
        let c = TripodZone.band(candidate: tripod(1, 1000, 0, .unconfirmed), pieces: [piece]) { _, _ in 60 }
        XCTAssertNotEqual(a, c, "ступень сменилась — переписать")
    }

    // MARK: - Цвет и уникальные имена

    func testColoursComeFromTokens() {
        XCTAssertEqual(EngineTripodZone.red, CameraGlyph.camera.fillRGB)
        XCTAssertEqual(EngineTripodZone.amber, WidgetPalette.warning.dark)
        for name in [EngineTripodZone.hatchImage, EngineTripodZone.sparseImage, EngineTripodZone.calmImage] {
            XCTAssertTrue(name.hasPrefix("radar-tripod-"), "своё имя — спрайт выпуска не перезапишет")
        }
    }

    func testHotPhoneHidesHatchAndCalmZone() {
        for id in EngineTripodZone.hotHidden {
            XCTAssertTrue(EngineMapView.Coordinator.hotHiddenLayers.contains(id))
        }
        XCTAssertTrue(EngineMapView.Coordinator.hotShownLayers.contains(EngineTripodZone.flatLayerID))
        XCTAssertTrue(EngineTripodZone.hotHidden.contains(EngineTripodZone.calmLayerID))
    }

    // MARK: - Только картинка

    func testAlertPipelineNeverReadsTheZone() throws {
        let services = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RadarMap/Services")
        let files = FileManager.default.enumerator(at: services, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("TripodZone") || text.contains("tripodZone"),
                           "\(file.lastPathComponent): участок треноги в конвейере")
        }
    }
}
