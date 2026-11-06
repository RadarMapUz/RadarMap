//
//  RouteLineEndsTests.swift
//  RadarMapTests
//
//  Камера за концом линии маршрута — не камера маршрута. Весь путь выбора, как
//  на каждом фиксе в LocationService: camerasAlong → остаток по маршруту →
//  кандидаты → первая наша → PassTracking → AlertEngine. Утверждения — про то,
//  что слышит водитель и что ляжет в историю.
//
//  Главное здесь — что НЕ изменилось: камера на линии ни на метр, камера с
//  координатой без доказательства и камера без курса предупреждают.
//

import CoreLocation
import MapKit
import XCTest
@testable import RadarMap

final class RouteLineEndsTests: XCTestCase {

    // MARK: - Стенд: дорога на север, y — метры от начала координат

    private let origin = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.25)
    private let speed = 40.0

    private func spot(_ y: Double, east: Double = 0) -> CLLocationCoordinate2D {
        let north = GeoMath.destination(from: origin, bearing: y >= 0 ? 0 : 180, distanceMeters: abs(y))
        return GeoMath.destination(from: north, bearing: east >= 0 ? 90 : 270, distanceMeters: abs(east))
    }

    /// Линия маршрута от `from` до `to` по той же дороге.
    private func line(_ from: Double, _ to: Double, step: Double = 50) -> [MKMapPoint] {
        let sign = to >= from ? 1.0 : -1.0
        var ys = Array(stride(from: from, to: to, by: step * sign))
        ys.append(to)
        return ys.map { MKMapPoint(spot($0)) }
    }

    /// Камера со снапом, как в базе: кусок своей дороги ±100 м под `roadBearing`.
    private func snapped(_ id: Int, _ y: Double, east: Double = 0, roadBearing: Double = 0,
                         type: String = "Стационар радар", cls: String = "primary",
                         needsReview: Bool = false) -> Camera {
        let at = spot(y, east: east)
        var road: [Int] = []
        for step in [-100.0, 0, 100] {
            let p = GeoMath.destination(from: at, bearing: step < 0 ? roadBearing + 180 : roadBearing,
                                        distanceMeters: abs(step))
            road.append(Int(((p.latitude - at.latitude) * 1e6).rounded()))
            road.append(Int(((p.longitude - at.longitude) * 1e6).rounded()))
        }
        return Camera(id: id, region: "Т", city: "", location: "к", lat: at.latitude, lon: at.longitude,
                      type: type, violations: [], needsReview: needsReview, axis: nil, dir: nil,
                      lanes: 2, cls: cls, road: road, split: nil, twin: nil)
    }

    /// Точка без куска дороги: отметка водителей или своя камера.
    private func bare(_ id: Int, _ y: Double, type: String) -> Camera {
        let at = spot(y)
        return Camera(id: id, region: "Т", city: "", location: "к", lat: at.latitude, lon: at.longitude,
                      type: type, violations: [], needsReview: nil)
    }

    private func along(_ points: [MKMapPoint], _ cameras: [Camera]) -> [RouteService.RouteCamera] {
        var bbox = MKMapRect.null
        for p in points { bbox = bbox.union(MKMapRect(origin: p, size: MKMapSize())) }
        return RouteService.camerasAlong(pts: points, bbox: bbox,
                                         centerLat: points[0].coordinate.latitude, cameras: cameras)
    }

    /// Порядок решений — как LocationService на фиксе. Прогресс — проекция на
    /// линию, прижатая к её концам, как у RouteService.project.
    private struct Bench {
        var route: [RouteService.RouteCamera] = []
        var lineStart = 0.0
        var lineSign = 1.0
        var lineLength = 0.0
        var cameras: [Camera]
        var engine = AlertEngine()
        var passTracking = PassTracking()
        private(set) var firstAlerts: [Int: Int] = [:]
        private(set) var firstDistances: [Int: Double] = [:]
        private(set) var passes: [Int: Double] = [:]
        private var clock = Date(timeIntervalSince1970: 1_770_000_000)

        init(cameras: [Camera]) { self.cameras = cameras }

        typealias Pick = (id: Int, distance: Double, onRoute: Bool)

        @discardableResult
        mutating func tick(_ here: CLLocationCoordinate2D, y: Double, course: Double,
                           speed: Double) -> Pick? {
            let situation = LocationGates.Situation(coordinate: here, course: course, speedKmh: speed,
                                                    horizontalAccuracy: 5, context: .city)
            let progress = min(lineLength, max(0, (y - lineStart) * lineSign))
            var candidates: [LocationGates.Candidate] = []
            for camera in cameras {
                let item = route.first { $0.camera.id == camera.id }
                let remaining = LocationGates.routeRemaining(cameraAlong: item?.distanceAlong,
                                                             provenOncoming: item?.provenOncoming ?? false,
                                                             progressAlong: progress,
                                                             isOffRoute: false, isProgressFrozen: false)
                let straight = GeoMath.fastDistance(here.latitude, here.longitude, camera.lat, camera.lon)
                if engine.isAnnounced(camera.id) {
                    let atTraverse = straight <= LocationGates.alertTraverseLimit(for: camera, accuracy: 5)
                    if atTraverse {
                        engine.noteApproach(camera.id, distance: straight, at: here, course: course, accuracy: 5)
                    }
                    engine.noteGeometry(camera.id, atTraverse: atTraverse,
                                        behind: LocationGates.isClearlyBehind(camera, in: situation),
                                        ahead: engine.isPassed(camera.id)
                                            && LocationGates.isReapproach(camera, in: situation,
                                                                          passLine: engine.passLine(camera.id)))
                }
                if let found = LocationGates.candidateDistance(straight: straight, routeRemaining: remaining,
                                                               announced: engine.isAnnounced(camera.id),
                                                               in: situation) {
                    candidates.append((camera, found.distance, found.onRoute))
                }
            }
            candidates.sort { $0.distance < $1.distance }
            let found = LocationGates.nearestOursIndex(candidates, in: situation).map { candidates[$0] }
            let radius = AlertEngine.effectiveRadius(speedKmh: speed, baseRadius: AppConfig.alertRadius,
                                                     context: .city)
            clock = clock.addingTimeInterval(1)
            for pass in passTracking.update(nearest: found?.camera, nearestDistance: found?.distance,
                                            coordinate: here, speedKmh: speed, roadLimit: nil,
                                            radius: radius, course: course, now: clock,
                                            offRoad: PassGeometry.isProvenOffRoad(camera:at:),
                                            axisDeviation: {
                                                PassGeometry.axisDeviation(camera: $0, at: $1, course: $2, accuracy: 5)
                                            }) {
                passes[pass.camera.id] = pass.speedKmh
            }
            guard let found else { return nil }
            if let decision = engine.evaluate(cameraID: found.camera.id, distance: found.distance,
                                              radius: radius,
                                              moving: LocationGates.isFilteringActive(situation)),
               decision.isFirst {
                firstAlerts[found.camera.id, default: 0] += 1
                firstDistances[found.camera.id] = found.distance
            }
            return (found.camera.id, found.distance, found.onRoute)
        }

        mutating func finish() {
            for pass in passTracking.flush() { passes[pass.camera.id] = pass.speedKmh }
        }
    }

    private func bench(line points: [MKMapPoint], start: Double, sign: Double = 1,
                       _ cameras: [Camera]) -> Bench {
        var bench = Bench(cameras: cameras)
        put(line: points, start: start, sign: sign, on: &bench)
        return bench
    }

    private func put(line points: [MKMapPoint], start: Double, sign: Double = 1, on bench: inout Bench) {
        bench.route = along(points, bench.cameras)
        bench.lineStart = start
        bench.lineSign = sign
        bench.lineLength = RouteService.cumulative(of: points).last ?? 0
    }

    /// Едем на север по `ys` с годным курсом.
    @discardableResult
    private func drive(_ bench: inout Bench, _ ys: some Sequence<Double>, speed: Double? = nil) -> [Bench.Pick?] {
        ys.map { bench.tick(spot($0), y: $0, course: 0, speed: speed ?? self.speed) }
    }

    // MARK: - Геометрия: кто на маршруте

    func testCameraBehindTheStartIsNotOnTheRoute() {
        let points = line(0, 2_000)
        for y in [-11.0, -30, -50, -89] {
            XCTAssertTrue(along(points, [snapped(1, y)]).isEmpty, "\(y) м за стартом")
        }
        XCTAssertNil(LocationGates.routeRemaining(cameraAlong: nil, progressAlong: 0,
                                                  isOffRoute: false, isProgressFrozen: false),
                     "не на маршруте — остатка нет, судят гейты")
    }

    func testCameraJustAheadOfTheStartKeepsItsPlace() throws {
        let found = try XCTUnwrap(along(line(0, 2_000), [snapped(1, 3)]).first)
        XCTAssertEqual(found.distanceAlong, 3, accuracy: 0.5)
        let remaining = try XCTUnwrap(LocationGates.routeRemaining(cameraAlong: found.distanceAlong, progressAlong: 0,
                                                                   isOffRoute: false, isProgressFrozen: false))
        XCTAssertEqual(remaining, 3, accuracy: 0.5)
    }

    /// Ни метра разницы для проекции на линию: прежний расчёт (прижатый t на
    /// ближайшем отрезке) и новый совпадают, включая камеру точно сбоку от старта.
    func testEveryCameraProjectedOnTheLineIsUntouched() {
        let points = line(0, 2_000)
        let cum = RouteService.cumulative(of: points)
        var cameras: [Camera] = []
        var id = 1
        for y in stride(from: 0.0, through: 1_990, by: 37) {
            for east in [0.0, 20, -20, 60, -85] {
                cameras.append(snapped(id, y, east: east))
                id += 1
            }
        }
        let found = along(points, cameras)
        XCTAssertEqual(found.count, cameras.count, "ни одна не потерялась")
        for item in found {
            let p = MKMapPoint(item.camera.coordinate)
            var best = (meters: Double.infinity, along: 0.0)
            for i in 0..<(points.count - 1) {
                let a = points[i], b = points[i + 1]
                let dx = b.x - a.x, dy = b.y - a.y
                let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)))
                let meters = p.distance(to: MKMapPoint(x: a.x + t * dx, y: a.y + t * dy))
                if meters < best.meters { best = (meters, cum[i] + t * a.distance(to: b)) }
            }
            XCTAssertEqual(item.distanceAlong, best.along, accuracy: 1e-6)
            XCTAssertTrue(item.countsAsOurs)
        }
    }

    /// Точка старта снапнута с фикса, координата камеры снята снапом: разница
    /// меньше допуска не доказывает ничего — камера остаётся как была.
    func testWithinToleranceOfTheStartStaysOnTheRoute() {
        let points = line(0, 2_000)
        let tolerance = AppConfig.routeLineEndToleranceMeters
        for y in [-1.0, -5, -(tolerance - 1)] {
            let found = along(points, [snapped(1, y)])
            XCTAssertEqual(found.first?.distanceAlong, 0, "\(y) м — шум, остаётся на старте")
        }
        XCTAssertTrue(along(points, [snapped(1, -(tolerance + 1))]).isEmpty)
    }

    /// Сбоку от старта, чуть за его поперечной линией: это не «позади».
    func testBesideTheStartIsNotBehindIt() {
        let found = along(line(0, 2_000), [snapped(1, -3, east: 60)])
        XCTAssertEqual(found.first?.distanceAlong, 0)
    }

    /// Огрызки OSRM: повторённая первая точка и обрезок в метр вбок не должны
    /// ни спрятать камеру позади, ни дать случайный ход линии.
    func testStubsAtTheStartDoNotDecide() {
        let main = line(0, 2_000)
        XCTAssertTrue(along([main[0], main[0]] + main.dropFirst(), [snapped(1, -50)]).isEmpty, "повтор точки")
        let stub = MKMapPoint(spot(1, east: 1))
        XCTAssertTrue(along([main[0], stub] + main.dropFirst(), [snapped(1, -50)]).isEmpty, "обрезок в метр")
    }

    /// Линия короче надёжного хода: доказывать нечем, камера как была.
    func testTooShortALineProvesNothing() {
        XCTAssertEqual(along(line(0, 3), [snapped(1, -50)]).first?.distanceAlong, 0)
    }

    func testCameraPastTheFinish() throws {
        let points = line(0, 1_000)
        let length = try XCTUnwrap(RouteService.cumulative(of: points).last)
        XCTAssertTrue(along(points, [snapped(1, 1_060)]).isEmpty, "за финишем")
        let nearFinish = try XCTUnwrap(along(points, [snapped(1, 1_005)]).first)
        XCTAssertEqual(nearFinish.distanceAlong, length, accuracy: 1e-6, "шум у финиша — как было")
        let before = try XCTUnwrap(along(points, [snapped(1, 990)]).first)
        XCTAssertEqual(before.distanceAlong, 990, accuracy: 3)
    }

    /// Координата без доказательства: камера остаётся на маршруте, как была.
    func testCoordinateWithoutProofStaysOnTheRoute() {
        let points = line(0, 2_000)
        let unproven = [
            ("непроверенная позиция", snapped(1, -50, needsReview: true)),
            ("снап на проезд", snapped(1, -50, cls: "service")),
            ("снап на тротуар", snapped(1, -50, cls: "footway")),
            ("передвижной радар с куском", snapped(1, -50, type: "Передвижной радар")),
            ("передвижной радар", bare(1, -50, type: "Передвижной радар")),
            ("тренога", bare(1, -50, type: "Тренога")),
            ("пост", bare(1, -50, type: "Пост ДПС")),
            ("своя точка", bare(1, -50, type: "Стационар радар")),
        ]
        for (name, camera) in unproven {
            XCTAssertEqual(along(points, [camera]).first?.distanceAlong, 0, name)
        }
    }

    // MARK: - Цепочка: старт у камеры

    func testStartPastTheCameraDrivingAwayIsSilent() {
        var run = bench(line: line(0, 2_000), start: 0, [snapped(1, -30)])
        let picks = drive(&run, stride(from: 5.0, through: 500, by: 15))
        XCTAssertTrue(picks.allSatisfy { $0 == nil }, "ни вибрации, ни «0 м»")
        run.finish()
        XCTAssertNil(run.firstAlerts[1])
        XCTAssertNil(run.passes[1], "и ложного проезда в истории")
    }

    func testStartBeforeTheCameraWarnsAsBefore() throws {
        var run = bench(line: line(0, 2_000), start: 0, [snapped(1, 30)])
        let first = try XCTUnwrap(run.tick(spot(0), y: 0, course: 0, speed: speed))
        XCTAssertEqual(first.id, 1)
        XCTAssertEqual(first.distance, 30, accuracy: 0.5, "по маршруту, как раньше")
        XCTAssertTrue(first.onRoute)
        XCTAssertEqual(run.firstAlerts[1], 1)
        drive(&run, stride(from: 10.0, through: 700, by: 15))
        run.finish()
        XCTAssertNotNil(run.passes[1], "проезд записан")
    }

    /// Шум траверза (`corridorBehindToleranceMeters`) держит камеру и позади —
    /// лишнее предупреждение, сторона, в которую можно ошибаться. Но расстояние
    /// честное: не «0 м», и уходит она раньше прежних 60 м по маршруту.
    func testJustBehindOnTheMoveWarnsWithAnHonestDistance() throws {
        var run = bench(line: line(0, 2_000), start: 0, [snapped(1, -15)])
        let first = try XCTUnwrap(run.tick(spot(0), y: 0, course: 0, speed: speed))
        XCTAssertEqual(first.distance, 15, accuracy: 0.5)
        XCTAssertFalse(first.onRoute)
        XCTAssertNil(run.tick(spot(20), y: 20, course: 0, speed: speed), "за 30 м позади — ушла")
    }

    // MARK: - Глушить можно только доказанное

    func testWithoutCourseItWarns() throws {
        var standing = bench(line: line(0, 2_000), start: 0, [snapped(1, -30)])
        let pick = try XCTUnwrap(standing.tick(spot(0), y: 0, course: -1, speed: 0), "стоим — предупреждаем")
        XCTAssertEqual(pick.distance, 30, accuracy: 0.5, "по прямой, а не «0 м»")
        XCTAssertFalse(pick.onRoute)
        XCTAssertEqual(standing.firstAlerts[1], 1)

        var noCourse = bench(line: line(0, 2_000), start: 0, [snapped(1, -80)])
        XCTAssertEqual(noCourse.tick(spot(40), y: 40, course: -1, speed: speed)?.id, 1,
                       "едем без курса — «позади» не доказано")
        XCTAssertEqual(noCourse.firstAlerts[1], 1)

        // Тронулись с годным курсом — ушла, без второго «первого» и без следа.
        drive(&standing, stride(from: 10.0, through: 300, by: 15))
        XCTAssertEqual(standing.firstAlerts[1], 1)
    }

    func testCoordinateWithoutProofKeepsWarningDrivingAway() throws {
        for (name, camera) in [("needsReview", snapped(1, -50, needsReview: true)),
                               ("передвижной радар", bare(1, -50, type: "Передвижной радар")),
                               ("тренога", bare(1, -50, type: "Тренога"))] {
            var run = bench(line: line(0, 2_000), start: 0, [camera])
            let pick = try XCTUnwrap(run.tick(spot(5), y: 5, course: 0, speed: speed), name)
            XCTAssertEqual(pick.id, 1, name)
            XCTAssertTrue(pick.onRoute, "\(name): маршрут сильнее геометрии, как раньше")
            XCTAssertEqual(run.firstAlerts[1], 1, name)
        }
    }

    // MARK: - Старт снапнут вперёд или линия идёт против нас

    /// Старт в 40 м впереди машины, камера между ними: проекция за началом
    /// линии, а камера впереди по курсу — обязана предупредить через гейты.
    func testCameraBehindAStartSnappedAheadOfTheCarWarns() throws {
        var run = bench(line: line(40, 2_000), start: 40, [snapped(1, 10)])
        XCTAssertTrue(run.route.isEmpty)
        let pick = try XCTUnwrap(run.tick(spot(-30), y: -30, course: 0, speed: speed))
        XCTAssertEqual(pick.id, 1)
        XCTAssertEqual(pick.distance, 40, accuracy: 0.5, "честные метры от машины")
        XCTAssertEqual(run.firstAlerts[1], 1)
        drive(&run, stride(from: -15.0, through: 700, by: 15))
        run.finish()
        XCTAssertNotNil(run.passes[1], "запись проезда не потерялась")
    }

    /// Первый отрезок против нашего курса (старт на встречной проезжей части,
    /// линия начинается с разворота): для линии камера «позади», для машины —
    /// впереди. Решает машина.
    func testLineStartingAgainstOurCourseStillWarns() throws {
        var run = bench(line: line(0, -2_000), start: 0, sign: -1, [snapped(1, 50)])
        XCTAssertTrue(run.route.isEmpty)
        let pick = try XCTUnwrap(run.tick(spot(5), y: 5, course: 0, speed: speed))
        XCTAssertEqual(pick.distance, 45, accuracy: 0.5)
        XCTAssertEqual(run.firstAlerts[1], 1)
    }

    // MARK: - Настоящая камера впереди

    func testCameraBehindNoLongerHidesTheRealOneAhead() throws {
        var run = bench(line: line(0, 2_000), start: 0, [snapped(1, -30), snapped(2, 300)])
        let pick = try XCTUnwrap(run.tick(spot(5), y: 5, course: 0, speed: speed))
        XCTAssertEqual(pick.id, 2, "HUD и голос — о передней")
        XCTAssertEqual(pick.distance, 295, accuracy: 2)
        XCTAssertTrue(pick.onRoute)
        XCTAssertEqual(run.firstAlerts[2], 1, "первое оповещение — на полном радиусе, с первого фикса")
        XCTAssertEqual(run.firstDistances[2] ?? 0, 295, accuracy: 2)
        XCTAssertNil(run.firstAlerts[1])
    }

    /// Передняя ближе 60 м от старта раньше не становилась ближайшей вовсе.
    func testCloseRealCameraAheadIsNotHiddenEither() throws {
        var run = bench(line: line(0, 2_000), start: 0, [snapped(1, -40), snapped(2, 50)])
        let pick = try XCTUnwrap(run.tick(spot(5), y: 5, course: 0, speed: speed))
        XCTAssertEqual(pick.id, 2)
        XCTAssertEqual(pick.distance, 45, accuracy: 0.5)
        XCTAssertEqual(run.firstAlerts[2], 1)
    }

    // MARK: - Перестроение

    func testRerouteRightAfterTheCamera() throws {
        let passed = snapped(1, 0), next = snapped(2, 340)
        var run = bench(line: line(-1_000, 2_000), start: -1_000, [passed, next])
        drive(&run, stride(from: -600.0, through: 30, by: 15), speed: 60)
        XCTAssertEqual(run.firstAlerts[1], 1)
        XCTAssertNil(run.firstAlerts[2])

        // Перестроение в 40 м за камерой: новая линия начинается у машины.
        put(line: line(40, 2_000), start: 40, on: &run)
        XCTAssertEqual(run.route.map(\.id), [2], "проеханная не в новом маршруте")
        let pick = try XCTUnwrap(run.tick(spot(45), y: 45, course: 0, speed: 60))
        XCTAssertEqual(pick.id, 2, "ближайшая — следующая, не прошлая «0 м»")
        XCTAssertEqual(pick.distance, 295, accuracy: 2)
        XCTAssertEqual(run.firstAlerts[2], 1)

        drive(&run, stride(from: 60.0, through: 800, by: 15), speed: 60)
        run.finish()
        XCTAssertEqual(run.firstAlerts[1], 1, "старая не тревожит второй раз")
        XCTAssertEqual(run.passes[1], 60, "проезд, начатый на старом маршруте, записан")
        XCTAssertEqual(run.passes[2], 60)
    }

    /// Новая линия началась чуть впереди камеры, а машина до неё ещё не доехала:
    /// камера вне маршрута, но впереди — предупреждение и запись на месте.
    func testRerouteJustBeforeTheCameraKeepsWarningAndThePass() throws {
        var run = bench(line: line(-1_000, 2_000), start: -1_000, [snapped(1, 0)])
        drive(&run, stride(from: -600.0, through: -30, by: 15), speed: 60)
        XCTAssertEqual(run.firstAlerts[1], 1)

        put(line: line(15, 2_000), start: 15, on: &run)
        XCTAssertTrue(run.route.isEmpty)
        let pick = try XCTUnwrap(run.tick(spot(-20), y: -20, course: 0, speed: 60))
        XCTAssertEqual(pick.id, 1)
        XCTAssertEqual(pick.distance, 20, accuracy: 0.5)

        drive(&run, stride(from: -5.0, through: 800, by: 15), speed: 60)
        run.finish()
        XCTAssertEqual(run.firstAlerts[1], 1, "серия не начата заново")
        XCTAssertEqual(run.passes[1], 60)
    }

    // MARK: - Финиш

    /// Камера за финишем на той же дороге: предупреждаем по геометрии, с
    /// честными метрами до неё, а не до финиша.
    func testCameraPastTheFinishWarnsByGeometry() throws {
        var run = bench(line: line(0, 1_000), start: 0, [snapped(1, 1_060)])
        let pick = try XCTUnwrap(run.tick(spot(700), y: 700, course: 0, speed: speed))
        XCTAssertEqual(pick.distance, 360, accuracy: 1)
        XCTAssertFalse(pick.onRoute)
        XCTAssertEqual(run.firstAlerts[1], 1)
    }

    /// За финишем на поперечной улице: она не на пути, и маршрут больше не
    /// выдаёт её за свою — ось её дороги доказывает.
    func testCameraPastTheFinishOnACrossStreetIsNotOurs() {
        var run = bench(line: line(0, 1_000), start: 0, [snapped(1, 1_060, roadBearing: 90)])
        XCTAssertNil(run.tick(spot(700), y: 700, course: 0, speed: speed))
    }

    // MARK: - Потребители

    /// Счётчики, полоска, зона, цвет «на пути», список — всё читает один список
    /// маршрута, поэтому камера за концом линии из них выходит разом.
    func testConsumersSeeOnlyTheCameraOnTheLine() {
        let points = line(0, 2_000)
        let found = along(points, [snapped(1, -30), snapped(2, 300), snapped(3, 2_060)])
        XCTAssertEqual(found.map(\.id), [2], "счётчик вариантов и RouteChoice")
        XCTAssertEqual(found.filter(\.countsAsOurs).count, 1, "«камер на маршруте»")
        XCTAssertEqual(RouteCamerasAhead.list(found, progress: 0).map(\.camera.id), [2])
        let route = found.map { (id: $0.id, along: $0.distanceAlong) }
        XCTAssertEqual(CameraMarkerLook.pathIDs(route: route, progress: 0,
                                                passedTolerance: AppConfig.routePassedToleranceMeters,
                                                nearest: nil), [2], "цвет «на пути»")
        let spots = CameraOnLine.routeSpots(points: points, cameras: found.map { ($0.camera, $0.distanceAlong) })
        XCTAssertEqual(Set(spots.keys), [2], "на линию не переносится")
        XCTAssertEqual(CameraZone.target(route: route, spots: spots, progress: 0, nearest: nil), 2,
                       "зона — передней камеры")
    }

    /// Прошлое поведение счётчика «впереди» для камеры на старте не изменилось:
    /// стоящая ровно на старте впереди не считалась и не считается.
    func testCameraAtTheStartIsStillNotAhead() {
        let found = along(line(0, 2_000), [snapped(1, -5)])
        XCTAssertEqual(found.first?.distanceAlong, 0)
        XCTAssertTrue(RouteCamerasAhead.list(found, progress: 0).isEmpty)
    }
}
