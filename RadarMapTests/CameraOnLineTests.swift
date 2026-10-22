//
//  CameraOnLineTests.swift
//  RadarMapTests
//
//  Камера на пути — на линии маршрута (27.B). Что проверяем:
//    • на линию переносится только камера на пути: встречный близнец и
//      поперечная камера остаются на своей координате и спокойными;
//    • разделённая улица (координата на оси встречной проезжей части в 20 м)
//      — камера без близнеца может снимать обе стороны, она на пути и на линии;
//    • подпись «400 м» стоит там же, где значок;
//    • перестроение — точки нового маршрута, старые не держатся;
//    • без маршрута — ось нашей дороги, только если камера на ней;
//    • ТОЛЬКО картинка: конвейер оповещений перенесённые точки не читает.
//

import XCTest
import MapKit
import CoreLocation
@testable import RadarMap

final class CameraOnLineTests: XCTestCase {

    private typealias Model = CameraOnLine

    private let origin = CLLocationCoordinate2D(latitude: 41.3330, longitude: 69.2190)

    private func camera(_ id: Int, at coordinate: CLLocationCoordinate2D, type: String = "Стационар камера",
                        axis: Int? = nil, dir: Int? = nil, cls: String? = "primary", lanes: Int? = 3,
                        split: Bool? = nil, twin: Bool? = nil, road: [Int]? = nil) -> Camera {
        Camera(id: id, region: "Toshkent shahar", city: "Olmazor tumani", location: "Тест \(id)",
               lat: coordinate.latitude, lon: coordinate.longitude, type: type, violations: [],
               needsReview: nil, axis: axis, dir: dir, lanes: lanes, cls: cls, road: road,
               split: split, twin: twin)
    }

    /// Прямая линия маршрута по азимуту, точки через 50 м.
    private func line(from start: CLLocationCoordinate2D, bearing: Double, meters: Double) -> [MKMapPoint] {
        stride(from: 0.0, through: meters, by: 50).map {
            MKMapPoint(GeoMath.destination(from: start, bearing: bearing, distanceMeters: $0))
        }
    }

    /// Точка в `along` м по линии и `side` м вбок (минус — влево).
    private func point(along: Double, side: Double, bearing: Double,
                       from start: CLLocationCoordinate2D? = nil) -> CLLocationCoordinate2D {
        let base = GeoMath.destination(from: start ?? origin, bearing: bearing, distanceMeters: along)
        return GeoMath.destination(from: base, bearing: bearing + (side < 0 ? -90 : 90),
                                   distanceMeters: abs(side))
    }

    private func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        MKMapPoint(a).distance(to: MKMapPoint(b))
    }

    /// Расстояние точки до ломаной маршрута.
    private func offset(_ c: CLLocationCoordinate2D, from points: [MKMapPoint]) -> Double {
        let p = MKMapPoint(c)
        var best = Double.greatestFiniteMagnitude
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)))
            best = min(best, p.distance(to: MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)))
        }
        return best
    }

    /// Как в RouteService.apply: сначала коридор (camerasAlong), потом точки.
    private func routeSpots(_ points: [MKMapPoint], _ cameras: [Camera]) -> [Int: CameraOnLine.Spot] {
        var bbox = MKMapRect.null
        for p in points { bbox = bbox.union(MKMapRect(origin: p, size: MKMapSize())) }
        let along = RouteService.camerasAlong(pts: points, bbox: bbox,
                                              centerLat: points[0].coordinate.latitude, cameras: cameras)
        return Model.routeSpots(points: points, cameras: along.map { ($0.camera, $0.distanceAlong) })
    }

    // MARK: - Разделённая улица: камера ложится на линию

    func testDividedStreetCameraWithoutTwinIsPulledOntoTheLine() {
        // Снимок 22.10: одиночная камера, координата на оси встречной
        // проезжей части в 20 м слева. Стороны не доказаны — может снимать и
        // нас: на пути, и рисуется на линии.
        let route = line(from: origin, bearing: 37, meters: 1_000)
        let cam = camera(1, at: point(along: 400, side: -20, bearing: 37), axis: 37, dir: 217, split: true)
        let spot = Model.spot(of: cam, on: route)
        XCTAssertEqual(spot?.verdict, .onLine)
        let drawn = spot?.point.coordinate ?? cam.coordinate
        XCTAssertLessThan(offset(drawn, from: route), 0.5, "значок на линии")
        XCTAssertEqual(distance(drawn, cam.coordinate), 20, accuracy: 1, "перенос — поперёк, не вдоль")
        XCTAssertEqual(distance(drawn, MKMapPoint(GeoMath.destination(from: origin, bearing: 37,
                                                                      distanceMeters: 400)).coordinate),
                       0, accuracy: 1)
    }

    func testOncomingTwinIsNotPulledAndNotOnThePath() {
        // Пара-близнец: стороны поделены доказанно, встречная камера снимает
        // встречных. Ей место сбоку и серой — даже если её позвали ближайшей.
        let route = line(from: origin, bearing: 58, meters: 1_000)
        let oncoming = camera(2364, at: point(along: 300, side: -12, bearing: 58),
                              axis: 58, dir: 238, split: true, twin: true)
        let ours = camera(2369, at: point(along: 321, side: 0, bearing: 58),
                          type: "Стационар радар", axis: 58, dir: 58, split: true, twin: true)
        let spots = routeSpots(route, [oncoming, ours])
        XCTAssertEqual(spots[2364]?.verdict, .notOurs)
        XCTAssertEqual(spots[2369]?.verdict, .onLine)

        let display = Model.display(route: [(id: 2364, along: 300), (id: 2369, along: 321)], spots: spots,
                                    progress: 100, passedTolerance: 60, nearest: 2364, nearestOnRoad: nil)
        XCTAssertEqual(display.pathIDs, [2369], "встречный близнец — не на пути")
        XCTAssertNil(display.points[2364], "встречная не притягивается")
        XCTAssertEqual(display.coordinate(of: oncoming).latitude, oncoming.lat)
        XCTAssertNotNil(display.points[2369])
    }

    func testSameDirectionCameraOnOurCarriagewayStaysPut() {
        let route = line(from: origin, bearing: 58, meters: 800)
        let cam = camera(5, at: point(along: 300, side: 2, bearing: 58), axis: 58, dir: 58, split: true, twin: true)
        let spot = Model.spot(of: cam, on: route)
        XCTAssertEqual(spot?.verdict, .onLine)
        XCTAssertEqual(distance(spot!.point.coordinate, cam.coordinate), 2, accuracy: 0.5)
    }

    func testCrossStreetCameraIsNotOurs() {
        // Камера на поперечной улице в 40 м от линии (в коридоре 90 м): ось
        // поперёк — мы её не проезжаем, на линию не кладём.
        let route = line(from: origin, bearing: 0, meters: 1_000)
        let cross = camera(6, at: point(along: 525, side: 40, bearing: 0), axis: 90)
        XCTAssertEqual(Model.spot(of: cross, on: route)?.verdict, .notOurs)
    }

    func testCameraOnTheStreetWeTurnIntoIsOursAtTheVertex() {
        // У поворота курс линии — с обоих отрезков: камера на улице, куда мы
        // сворачиваем, не «поперечная».
        let corner = GeoMath.destination(from: origin, bearing: 0, distanceMeters: 500)
        var route = line(from: origin, bearing: 0, meters: 500)
        route += line(from: corner, bearing: 90, meters: 500).dropFirst()
        // Камера у самого угла, чуть до него: ближе всего ей отрезок, по
        // которому мы ПОДЪЕЗЖАЕМ (курс 0°, ось камеры 90°) — без второго
        // отрезка она вышла бы «поперечной».
        let onTurn = camera(7, at: point(along: -3, side: 2, bearing: 90, from: corner), axis: 90)
        XCTAssertEqual(Model.spot(of: onTurn, on: route)?.verdict, .onLine)
    }

    func testDriverReportsAndOwnPointsAreNeverProvenNotOurs() {
        // У отметки водителя нет профиля дороги — доказать «не наша» нечем.
        let route = line(from: origin, bearing: 0, meters: 800)
        let tripod = camera(8, at: point(along: 300, side: 10, bearing: 0), type: "Тренога",
                            cls: nil, lanes: nil)
        XCTAssertEqual(Model.spot(of: tripod, on: route)?.verdict, .onLine)
    }

    func testCameraTooFarFromTheLineKeepsItsCoordinateButStaysOnThePath() {
        // Дублёр за сквером в 70 м: маршрут (коридор 90 м) считает её своей —
        // цвет «на пути» остаётся, но тащить через сквер на линию нельзя.
        let route = line(from: origin, bearing: 0, meters: 800)
        let cam = camera(9, at: point(along: 300, side: 70, bearing: 0), axis: 0)
        let spots = routeSpots(route, [cam])
        XCTAssertEqual(spots[9]?.verdict, .beside)
        let display = Model.display(route: [(id: 9, along: 300)], spots: spots, progress: 0,
                                    passedTolerance: 60, nearest: nil, nearestOnRoad: nil)
        XCTAssertEqual(display.pathIDs, [9])
        XCTAssertNil(display.points[9])
    }

    func testFastPathMatchesTheNearestPointOfTheLine() {
        // Точка по `along` из camerasAlong — та же, что перебор отрезков.
        let corner = GeoMath.destination(from: origin, bearing: 37, distanceMeters: 600)
        var route = line(from: origin, bearing: 37, meters: 600)
        route += line(from: corner, bearing: 80, meters: 600).dropFirst()
        let cams = [camera(1, at: point(along: 250, side: -20, bearing: 37), axis: 37),
                    camera(2, at: point(along: 590, side: 12, bearing: 37), axis: 37),
                    camera(3, at: point(along: 300, side: -25, bearing: 80, from: corner), axis: 80)]
        let fast = routeSpots(route, cams)
        XCTAssertEqual(fast.count, 3)
        for cam in cams {
            let slow = Model.spot(of: cam, on: route)
            XCTAssertEqual(fast[cam.id]?.verdict, slow?.verdict)
            XCTAssertEqual(distance(fast[cam.id]!.point.coordinate, slow!.point.coordinate), 0, accuracy: 0.5)
        }
    }

    // MARK: - Кадр

    func testProjectionOnlyForCamerasOnThePath() {
        let route = line(from: origin, bearing: 37, meters: 1_500)
        let ahead = camera(1, at: point(along: 900, side: -20, bearing: 37), axis: 37, dir: 217, split: true)
        let oncoming = camera(2, at: point(along: 600, side: -15, bearing: 37), axis: 37, dir: 217,
                              split: true, twin: true)
        let offRoute = camera(3, at: point(along: 700, side: -400, bearing: 37), axis: 37)
        let spots = routeSpots(route, [ahead, oncoming])
        let display = Model.display(route: [(id: 2, along: 600), (id: 1, along: 900)], spots: spots,
                                    progress: 200, passedTolerance: 60, nearest: nil, nearestOnRoad: nil)
        XCTAssertEqual(Set(display.points.keys), [1])
        XCTAssertEqual(display.pathIDs, [1])
        XCTAssertEqual(display.coordinate(of: offRoute).latitude, offRoute.lat, "не на пути — где стоит")
    }

    func testPassedRouteCameraStaysOnTheLineButIsCalm() {
        // Проехали — уже не «на пути» (цвет), но значок не прыгает вбок за
        // машиной: на линии, по которой мы его проехали.
        let route = line(from: origin, bearing: 37, meters: 1_500)
        let cam = camera(1, at: point(along: 300, side: -20, bearing: 37), axis: 37, dir: 217, split: true)
        let spots = routeSpots(route, [cam])
        let display = Model.display(route: [(id: 1, along: 300)], spots: spots, progress: 900,
                                    passedTolerance: 60, nearest: nil, nearestOnRoad: nil)
        XCTAssertTrue(display.pathIDs.isEmpty)
        XCTAssertNotNil(display.points[1])
    }

    func testDistanceLabelStandsWhereTheIconIs() {
        // Подпись «400 м» в машине берёт точку из того же Display, что и
        // значок: на линии у камеры на пути, у её координаты у остальных.
        let route = line(from: origin, bearing: 37, meters: 1_000)
        let cam = camera(1, at: point(along: 400, side: -20, bearing: 37), axis: 37, dir: 217, split: true)
        let spots = routeSpots(route, [cam])
        let display = Model.display(route: [(id: 1, along: 400)], spots: spots, progress: 0,
                                    passedTolerance: 60, nearest: 1, nearestOnRoad: nil)
        let icon = display.points[1]!.coordinate
        let label = display.coordinate(of: cam)
        XCTAssertEqual(label.latitude, icon.latitude)
        XCTAssertEqual(label.longitude, icon.longitude)
        XCTAssertLessThan(offset(label, from: route), 0.5)
    }

    func testRerouteTakesTheNewLineAndDropsTheOld() {
        let cam = camera(1, at: point(along: 400, side: -20, bearing: 37), axis: 37, dir: 217, split: true)
        let first = line(from: origin, bearing: 37, meters: 1_000)
        let old = routeSpots(first, [cam])
        XCTAssertEqual(old[1]?.verdict, .onLine)
        // Новый маршрут идёт по самой встречной проезжей части (развернулись):
        // точка — на новой линии.
        let back = point(along: 1_000, side: -20, bearing: 37)
        let second = line(from: back, bearing: 217, meters: 1_000)
        let new = routeSpots(second, [cam])
        XCTAssertEqual(new[1]?.verdict, .onLine)
        XCTAssertLessThan(offset(new[1]!.point.coordinate, from: second), 0.5)
        XCTAssertGreaterThan(distance(new[1]!.point.coordinate, old[1]!.point.coordinate), 15)
        // Маршрут, который мимо камеры не идёт: camerasAlong её не вернул —
        // точек нет, камера там, где стоит.
        let elsewhere = Model.display(route: [], spots: routeSpots(second, []),
                                      progress: 0, passedTolerance: 60, nearest: nil, nearestOnRoad: nil)
        XCTAssertNil(elsewhere.points[1])
        XCTAssertEqual(elsewhere.coordinate(of: cam).latitude, cam.lat)
    }

    // MARK: - Без маршрута: ось нашей дороги

    func testWithoutRouteTheHUDCameraLiesOnOurRoadAxis() {
        let cam = camera(1, at: point(along: 200, side: -18, bearing: 37), axis: 37, dir: 217, split: true)
        let spot = Model.roadSpot(camera: cam, origin: origin, bearing: 37)
        XCTAssertNotNil(spot)
        let onAxis = GeoMath.destination(from: origin, bearing: 37, distanceMeters: 200)
        XCTAssertEqual(distance(spot!.coordinate, onAxis), 0, accuracy: 1)
        let display = Model.display(route: [], spots: [:], progress: nil, passedTolerance: 60,
                                    nearest: 1, nearestOnRoad: spot)
        XCTAssertEqual(display.pathIDs, [1])
        XCTAssertEqual(display.points[1], spot)
    }

    func testWithoutRouteOnlyACameraOnOurAxisMoves() {
        let bearing = 37.0
        let behind = camera(1, at: point(along: -50, side: -10, bearing: bearing), axis: 37)
        XCTAssertNil(Model.roadSpot(camera: behind, origin: origin, bearing: bearing), "позади")
        let far = camera(2, at: point(along: 450, side: -10, bearing: bearing), axis: 37)
        XCTAssertNil(Model.roadSpot(camera: far, origin: origin, bearing: bearing),
                     "далеко: прямая по отрезку под машиной уходит с дороги")
        let aside = camera(3, at: point(along: 150, side: 60, bearing: bearing), axis: 37)
        XCTAssertNil(Model.roadSpot(camera: aside, origin: origin, bearing: bearing), "соседняя улица")
        let curved = camera(4, at: point(along: 150, side: -10, bearing: bearing), axis: 57)
        XCTAssertNil(Model.roadSpot(camera: curved, origin: origin, bearing: bearing), "между нами кривая")
        let oncomingTwin = camera(5, at: point(along: 150, side: -12, bearing: bearing), axis: 37, dir: 217,
                                  split: true, twin: true)
        XCTAssertNil(Model.roadSpot(camera: oncomingTwin, origin: origin, bearing: bearing),
                     "встречный близнец не притягивается")
        let noAxis = camera(6, at: point(along: 150, side: -10, bearing: bearing), cls: nil, lanes: nil)
        XCTAssertNil(Model.roadSpot(camera: noAxis, origin: origin, bearing: bearing),
                     "ось неизвестна — прямая ли дорога, не знаем")
    }

    func testRoadSpotIsStableAlongTheSameSegment() {
        // Прижатая точка едет по оси — проекция камеры на ту же прямую не
        // меняется: источник камер не переписывается каждый фикс.
        let cam = camera(1, at: point(along: 250, side: -15, bearing: 37), axis: 37)
        let first = Model.roadSpot(camera: cam, origin: origin, bearing: 37)
        let later = Model.roadSpot(camera: cam,
                                   origin: GeoMath.destination(from: origin, bearing: 37, distanceMeters: 30),
                                   bearing: 37)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, later)
    }

    // MARK: - Снимок владельца (22.10, Нурафшон обводная, ~07:08)

    func testOwnerSnapshotNurafshonCameras() {
        // 2371 «Nurafshon – Farobiy Tor ko‘chasi № 1-UY qarshisida»: стационар
        // камера, dir 217 (на юго-юго-запад), split, близнеца нет. Мы едем на
        // северо-северо-восток к Tok Bor — она на встречной проезжей части,
        // но стороны не доказаны: может снимать и нас → на линии.
        let c2371 = Camera(id: 2371, region: "Toshkent shahar", city: "Olmazor tumani",
                           location: "Nurafshon – Farobiy Tor ko‘chasi № 1-UY qarshisida",
                           lat: 41.335623, lon: 69.221078, type: "Стационар камера", violations: [],
                           needsReview: nil, axis: 37, dir: 217, lanes: 3, cls: "primary",
                           road: [6, 6, -720, -724], split: true)
        // Наша проезжая часть — параллельно, 18 м правее (на восток).
        let ourStart = point(along: -500, side: 18, bearing: 37, from: c2371.coordinate)
        let route = line(from: ourStart, bearing: 37, meters: 1_000)
        let spot = Model.spot(of: c2371, on: route)
        XCTAssertEqual(spot?.verdict, .onLine)
        XCTAssertLessThan(offset(spot!.point.coordinate, from: route), 0.5)

        // Пара 2364/2369 дальше по Нурафшон: близнецы, курс маршрута 58°.
        // 2364 (dir 238) — встречная, доказанно: не на пути и не на линии.
        let c2364 = Camera(id: 2364, region: "Toshkent shahar", city: "Olmazor tumani",
                           location: "Nurafshon Aylanma ko‘chasi, 22-UY qarshisida",
                           lat: 41.339435, lon: 69.226661, type: "Стационар камера", violations: [],
                           needsReview: nil, axis: 58, dir: 238, lanes: 3, cls: "primary",
                           road: [364, 785, -505, -992], split: true, twin: true)
        let c2369 = Camera(id: 2369, region: "Toshkent shahar", city: "Olmazor tumani",
                           location: "Nurafshon ko‘chasi 31-UY qarshisida",
                           lat: 41.339441, lon: 69.226952, type: "Стационар радар", violations: [],
                           needsReview: nil, axis: 58, dir: 58, lanes: 3, cls: "primary",
                           road: [-433, -863, -68, -145, 460, 1030], split: true, twin: true)
        // Маршрут — по оси проезжей части 2369 (её кусок дороги из базы).
        let road = RoadShape(camera: c2369)!.points.map(MKMapPoint.init)
        let spots = routeSpots(road, [c2364, c2369])
        XCTAssertEqual(spots[2364]?.verdict, .notOurs)
        XCTAssertEqual(spots[2369]?.verdict, .onLine)
    }

    // MARK: - Только картинка

    func testAlertPipelineNeverReadsDisplayPoints() throws {
        // Перенесённая точка — для карты. Ни гейты, ни проезды, ни голос, ни
        // прогресс маршрута её не читают: в сервисах она живёт только там,
        // где считается и хранится (RouteService.apply / Variant), а курс оси
        // дороги LocationService только пишет.
        let services = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RadarMap/Services")
        let files = FileManager.default.enumerator(at: services, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        let allowedRoute = ["var cameraSpots:", "var cameraSpotsOnRoute:", "cameraSpots: variantSpots",
                            "let (variantCameras, verdict, trafficDelays, variantSpots)",
                            "CameraOnLine.routeSpots(", "return (found, choice, delays, spots)"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: .newlines) {
                let code = line.components(separatedBy: "//")[0]
                let touches = code.contains("CameraOnLine") || code.contains("cameraSpots")
                    || code.contains("variantSpots") || code.contains("cameraOnLine")
                if touches {
                    XCTAssertEqual(file.lastPathComponent, "RouteService.swift",
                                   "\(file.lastPathComponent): точки показа в конвейере — \(line)")
                    XCTAssertTrue(allowedRoute.contains { code.contains($0) },
                                  "RouteService: новое чтение точек показа — \(line)")
                }
                if code.contains("displayRoadBearing") {
                    XCTAssertTrue(code.contains("displayRoadBearing =") || code.contains("var displayRoadBearing")
                                  || code.contains("displayRoadBearing !="),
                                  "\(file.lastPathComponent): курс оси дороги читают — \(line)")
                }
            }
        }
    }
}
