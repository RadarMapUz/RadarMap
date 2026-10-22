//
//  RouteCameraDirectionTests.swift
//  RadarMapTests
//
//  27.J: на маршруте доказанно встречная камера — не наша. Проверяем весь
//  путь выбора, как в LocationService: camerasAlong → остаток по маршруту →
//  кандидаты → первая наша (LocationGates.nearestOursIndex). Недоказанное —
//  как раньше: «неизвестно — предупреждать».
//

import XCTest
import MapKit
import CoreLocation
@testable import RadarMap

final class RouteCameraDirectionTests: XCTestCase {

    // MARK: - Данные снимка 22.10 (Нурафшон)

    private let c2364 = Camera(id: 2364, region: "Toshkent shahar", city: "Olmazor tumani",
                               location: "Nurafshon Aylanma ko‘chasi, 22-UY qarshisida",
                               lat: 41.339435, lon: 69.226661, type: "Стационар камера", violations: [],
                               needsReview: nil, axis: 58, dir: 238, lanes: 3, cls: "primary",
                               road: [364, 785, -505, -992], split: true, twin: true)
    private let c2369 = Camera(id: 2369, region: "Toshkent shahar", city: "Olmazor tumani",
                               location: "Nurafshon ko‘chasi 31-UY qarshisida",
                               lat: 41.339441, lon: 69.226952, type: "Стационар радар", violations: [],
                               needsReview: nil, axis: 58, dir: 58, lanes: 3, cls: "primary",
                               road: [-433, -863, -68, -145, 460, 1030], split: true, twin: true)
    private let c2370 = Camera(id: 2370, region: "Toshkent shahar", city: "Olmazor tumani",
                               location: "Nurafshon ko‘chasi 31-UY qarshisida",
                               lat: 41.339617, lon: 69.227333, type: "Стационар радар", violations: [],
                               needsReview: nil, axis: 59, dir: 59, lanes: 3, cls: "primary",
                               road: [-486, -1009, -71, -159, 365, 844], split: true, twin: true)
    private let c2371 = Camera(id: 2371, region: "Toshkent shahar", city: "Olmazor tumani",
                               location: "Nurafshon – Farobiy Tor ko‘chasi № 1-UY qarshisida",
                               lat: 41.335623, lon: 69.221078, type: "Стационар камера", violations: [],
                               needsReview: nil, axis: 37, dir: 217, lanes: 3, cls: "primary",
                               road: [6, 6, -720, -724], split: true)

    // MARK: - Помощники

    private func line(from start: CLLocationCoordinate2D, bearing: Double, meters: Double,
                      step: Double = 50) -> [MKMapPoint] {
        stride(from: 0.0, through: meters, by: step).map {
            MKMapPoint(GeoMath.destination(from: start, bearing: bearing, distanceMeters: $0))
        }
    }

    private func offset(_ c: CLLocationCoordinate2D, along: Double, side: Double,
                        bearing: Double) -> CLLocationCoordinate2D {
        let base = GeoMath.destination(from: c, bearing: bearing, distanceMeters: along)
        return GeoMath.destination(from: base, bearing: bearing + (side < 0 ? -90 : 90),
                                   distanceMeters: abs(side))
    }

    private func along(_ points: [MKMapPoint], _ cameras: [Camera]) -> [RouteService.RouteCamera] {
        var bbox = MKMapRect.null
        for p in points { bbox = bbox.union(MKMapRect(origin: p, size: MKMapSize())) }
        return RouteService.camerasAlong(pts: points, bbox: bbox,
                                         centerLat: points[0].coordinate.latitude, cameras: cameras)
    }

    /// Выбор камеры оповещения — как LocationService.recomputeNearest:
    /// остаток по маршруту, кандидат, первая наша по гейтам.
    private func alertCamera(route: [RouteService.RouteCamera], progress: Double,
                             at coordinate: CLLocationCoordinate2D, course: Double,
                             speed: Double = 50, ignoreOncoming: Bool = false) -> Int? {
        let situation = LocationGates.Situation(coordinate: coordinate, course: course, speedKmh: speed,
                                                horizontalAccuracy: 5, context: .city)
        var candidates: [LocationGates.Candidate] = []
        for item in route {
            let remaining = LocationGates.routeRemaining(
                cameraAlong: item.distanceAlong,
                provenOncoming: ignoreOncoming ? false : item.provenOncoming,
                progressAlong: progress, isOffRoute: false, isProgressFrozen: false)
            let straight = MKMapPoint(coordinate).distance(to: MKMapPoint(item.camera.coordinate))
            if let found = LocationGates.candidateDistance(straight: straight, routeRemaining: remaining,
                                                           announced: false, in: situation) {
                candidates.append((item.camera, found.distance, found.onRoute))
            }
        }
        candidates.sort { $0.distance < $1.distance }
        return LocationGates.nearestOursIndex(candidates, in: situation).map { candidates[$0].camera.id }
    }

    // MARK: - Пара-близнец 2364/2369

    func testTwinOncomingIsNoLongerTheAlertCamera() {
        // Маршрут по проезжей части 2369 (курс ~58°), машина за 120 м до пары.
        let carriageway = RoadShape(camera: c2369)!.points
        let a = carriageway.first!, b = carriageway.last!
        let bearing = GeoMath.bearing(from: a, to: b)
        let start = GeoMath.destination(from: a, bearing: bearing + 180, distanceMeters: 400)
        let points = line(from: start, bearing: bearing, meters: 1_000)
        let route = along(points, [c2364, c2369, c2370])
        XCTAssertEqual(Set(route.map(\.camera.id)), [2364, 2369, 2370], "все три — в коридоре 90 м")
        XCTAssertEqual(route.first { $0.camera.id == 2364 }?.provenOncoming, true)
        XCTAssertEqual(route.first { $0.camera.id == 2369 }?.provenOncoming, false)
        XCTAssertEqual(route.first { $0.camera.id == 2370 }?.provenOncoming, false)

        let progress = (route.first { $0.camera.id == 2364 }!.distanceAlong) - 120
        let car = GeoMath.destination(from: start, bearing: bearing, distanceMeters: progress)
        XCTAssertEqual(alertCamera(route: route, progress: progress, at: car, course: bearing), 2369,
                       "тревога — о радаре, который нас снимает")
        // Сверка с прежним правилом: без флага встречная была ближе и «нашей».
        XCTAssertEqual(alertCamera(route: route, progress: progress, at: car, course: bearing,
                                   ignoreOncoming: true), 2364)
        // Встречную гейты по живому фиксу и сами глушат — доказательством.
        XCTAssertEqual(LocationGates.verdict(c2364, in: LocationGates.Situation(
            coordinate: car, course: bearing, speedKmh: 50, horizontalAccuracy: 5, context: .city),
            isOnRoute: false), .provenDirection)
    }

    func testSingleCameraWithoutTwinStaysOurs() {
        // 2371: встречная проезжая часть, но близнеца нет — стороны не
        // доказаны, может снимать и нас. Тревога — как раньше.
        let ours = offset(c2371.coordinate, along: -500, side: 13, bearing: 37)
        let points = line(from: ours, bearing: 37, meters: 1_000)
        let route = along(points, [c2371])
        XCTAssertEqual(route.first?.provenOncoming, false)
        let progress = route[0].distanceAlong - 100
        let car = GeoMath.destination(from: ours, bearing: 37, distanceMeters: progress)
        XCTAssertEqual(alertCamera(route: route, progress: progress, at: car, course: 37), 2371)
    }

    // MARK: - Разворот и поворот

    func testUTurnLegOnTheCameraCarriagewayKeepsItOurs() {
        // Маршрут идёт на северо-восток по проезжей части 2369, разворачивается
        // и возвращается по проезжей части 2364: ближайший к 2364 отрезок —
        // обратный, по её направлению. Она наша — на втором проходе.
        let carriageway = RoadShape(camera: c2369)!.points
        let bearing = GeoMath.bearing(from: carriageway.first!, to: carriageway.last!)
        let start = GeoMath.destination(from: carriageway.first!, bearing: bearing + 180, distanceMeters: 300)
        var points = line(from: start, bearing: bearing, meters: 700)
        let turn = points.last!.coordinate
        let back = offset(turn, along: 0, side: -12, bearing: bearing)
        points += line(from: back, bearing: bearing + 180, meters: 700)
        let route = along(points, [c2364, c2369])
        let r2364 = route.first { $0.camera.id == 2364 }!
        XCTAssertFalse(r2364.provenOncoming)
        XCTAssertGreaterThan(r2364.distanceAlong, 700, "её проход — обратный")
        XCTAssertEqual(route.first { $0.camera.id == 2369 }?.provenOncoming, false)
    }

    func testTurnAtTheCameraNeedsBothHeadingsAgainst() {
        // Подъезжаем на север и у вершины сворачиваем на восток. Близнец на
        // юго-юго-восток (150°) у самого угла: против подъездного курса (150°
        // разницы), но с выездным сходится (60°) — не доказано.
        let origin = CLLocationCoordinate2D(latitude: 41.3200, longitude: 69.2500)
        let corner = GeoMath.destination(from: origin, bearing: 0, distanceMeters: 500)
        var points = line(from: origin, bearing: 0, meters: 500)
        points += line(from: corner, bearing: 90, meters: 500).dropFirst()
        let nearCorner = offset(corner, along: -3, side: 2, bearing: 90)
        let east = Camera(id: 1, region: "", city: "", location: "угол", lat: nearCorner.latitude,
                          lon: nearCorner.longitude, type: "Стационар радар", violations: [],
                          needsReview: nil, axis: 150, dir: 150, lanes: 3, cls: "primary",
                          split: true, twin: true)
        XCTAssertEqual(along(points, [east]).first?.provenOncoming, false)
        XCTAssertTrue(RouteCameraDirection.isProvenOncoming(east, headings: [0]), "без вершины — доказано бы")
        // Направление против обоих курсов (на юго-запад) — доказано.
        let southWest = Camera(id: 2, region: "", city: "", location: "угол", lat: nearCorner.latitude,
                               lon: nearCorner.longitude, type: "Стационар радар", violations: [],
                               needsReview: nil, axis: 45, dir: 225, lanes: 3, cls: "primary",
                               split: true, twin: true)
        XCTAssertEqual(along(points, [southWest]).first?.provenOncoming, true)
    }

    func testUnreliableRouteHeadingProvesNothing() {
        // Огрызок OSRM короче `routeHeadingReliableMeters` под камерой — курс
        // линии случайный, доказательства нет.
        let origin = CLLocationCoordinate2D(latitude: 41.3200, longitude: 69.2500)
        let a = MKMapPoint(origin)
        let b = MKMapPoint(GeoMath.destination(from: origin, bearing: 0, distanceMeters: 3))
        let cam = Camera(id: 1, region: "", city: "", location: "", lat: origin.latitude,
                         lon: origin.longitude, type: "Стационар радар", violations: [],
                         needsReview: nil, axis: 0, dir: 180, lanes: 3, cls: "primary",
                         split: true, twin: true)
        XCTAssertFalse(RouteCameraDirection.isProvenOncoming(cam, on: [a, b], segment: 0, t: 0.5))
        let c = MKMapPoint(GeoMath.destination(from: origin, bearing: 0, distanceMeters: 300))
        XCTAssertTrue(RouteCameraDirection.isProvenOncoming(cam, on: [a, c], segment: 0, t: 0.5))
    }

    // MARK: - Сверка: недоказанное не изменилось

    func testUnprovenCamerasNeverBecomeOncoming() {
        // Перебор профилей: без доказанно поделённых сторон (нет близнеца при
        // разделённой дороге, нет направления, профиль не годится для тишины,
        // непроверенная позиция, отметка водителей) флаг не ставится ни при
        // каком курсе линии — остаток по маршруту тот же, что до 27.J.
        let profiles: [(dir: Int?, split: Bool?, twin: Bool?, cls: String?, review: Bool?, type: String)] = [
            (217, true, nil, "primary", nil, "Стационар камера"),
            (217, nil, nil, "primary", nil, "Стационар камера"),
            (nil, false, nil, "primary", nil, "Стационар радар"),
            (90, true, true, "service", nil, "Стационар радар"),
            (90, true, true, "footway", nil, "Стационар радар"),
            (90, true, true, "primary", true, "Стационар радар"),
            (nil, nil, nil, nil, nil, "Тренога"),
        ]
        for (index, p) in profiles.enumerated() {
            let cam = Camera(id: index, region: "", city: "", location: "", lat: 41.3, lon: 69.2,
                             type: p.type, violations: [], needsReview: p.review, axis: p.dir.map { $0 % 180 },
                             dir: p.dir, lanes: 3, cls: p.cls, split: p.split, twin: p.twin)
            XCTAssertFalse(cam.allowsDirectionGate)
            for heading in stride(from: 0.0, to: 360, by: 10) {
                XCTAssertFalse(RouteCameraDirection.isProvenOncoming(cam, headings: [heading]),
                               "профиль \(index), курс \(heading)")
            }
        }
        // Доказанные стороны, но направление в пределах порога гейта — не встречная.
        let twin = Camera(id: 9, region: "", city: "", location: "", lat: 41.3, lon: 69.2,
                          type: "Стационар радар", violations: [], needsReview: nil, axis: 0, dir: 0,
                          lanes: 3, cls: "primary", split: true, twin: true)
        for heading in stride(from: 0.0, to: 360, by: 5)
        where GeoMath.angleDifference(heading, 0) <= AppConfig.cameraDirectionMaxAngle {
            XCTAssertFalse(RouteCameraDirection.isProvenOncoming(twin, headings: [heading]))
        }
        // Без флага остаток по маршруту — прежний.
        XCTAssertEqual(LocationGates.routeRemaining(cameraAlong: 5_000, provenOncoming: false, progressAlong: 4_200,
                                                    isOffRoute: false, isProgressFrozen: false), 800)
        XCTAssertNil(LocationGates.routeRemaining(cameraAlong: 5_000, provenOncoming: true, progressAlong: 4_200,
                                                  isOffRoute: false, isProgressFrozen: false))
    }

    func testOncomingIsLeftOutOfTheCameraListAhead() {
        let cam = Camera(id: 1, region: "", city: "", location: "", lat: 41.3, lon: 69.2,
                         type: "Стационар радар", violations: [], needsReview: nil)
        let list = RouteCamerasAhead.list([
            RouteService.RouteCamera(camera: cam, distanceAlong: 500, provenOncoming: true),
            RouteService.RouteCamera(camera: Camera(id: 2, region: "", city: "", location: "", lat: 41.3,
                                                    lon: 69.2, type: "Стационар радар", violations: [],
                                                    needsReview: nil), distanceAlong: 520),
        ], progress: 0)
        XCTAssertEqual(list.map(\.camera.id), [2])
    }
}
