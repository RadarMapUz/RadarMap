//
//  ScenarioDriveTests.swift
//  RadarMapTests
//
//  Сценарии поездки до релиза (план 19.10, этап 12в): маршрут целиком
//  проходит через НАСТОЯЩИЙ конвейер, как в LocationService на каждом фиксе —
//  LocationFilter → LocationGates (наша ли дорога, впереди ли) → ближайшая
//  уцелевшая → AlertEngine; проеханные камеры помечаются тем же
//  `notePassed`, что и в сервисе. Утверждения — про то, что слышит водитель:
//  сколько раз о камере предупредили С НАЧАЛА (`isFirst`).
//
//  Каждый найденный по сценарию баг остаётся здесь тестом, который его
//  воспроизводит: разворот за камерой (A6) — первый из них.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class ScenarioDriveTests: XCTestCase {

    // MARK: - Стенд

    /// Маршрут для стенда: ломаная в метрах; у камеры — одна позиция вдоль
    /// него (ближайший отрезок, первый при равенстве — как
    /// RouteService.camerasAlong), прогресс — проекция в окне у прошлого
    /// прогресса и с отставанием на фикс (сервис обновляет его после выбора
    /// ближайшей камеры).
    private struct RouteModel {
        let points: [(x: Double, y: Double)]

        func project(_ p: (x: Double, y: Double), near: Double? = nil) -> (along: Double, offset: Double) {
            var best = (along: 0.0, offset: Double.infinity)
            var cumulative = 0.0
            for (a, b) in zip(points, points.dropFirst()) {
                let dx = b.x - a.x, dy = b.y - a.y
                let len = (dx * dx + dy * dy).squareRoot()
                let t = len > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (len * len))) : 0
                let qx = a.x + dx * t, qy = a.y + dy * t
                let offset = ((p.x - qx) * (p.x - qx) + (p.y - qy) * (p.y - qy)).squareRoot()
                let along = cumulative + t * len
                cumulative += len
                if let near, along < near - 50 || along > near + 500 { continue }
                // При равенстве — дальше по маршруту (как штраф «против хода» у
                // сервиса): обратная нога не проецируется на прямую.
                if offset < best.offset - 0.01
                    || (abs(offset - best.offset) <= 0.01 && near != nil && along > best.along) {
                    best = (along, offset)
                }
            }
            return best
        }
    }

    /// Тот же порядок решений, что в LocationService на каждом фиксе:
    /// фильтр → (о ком сказали: траверз, «явно позади») → кандидаты
    /// (LocationGates.candidateDistance: маршрут или прямая) → первая «наша»
    /// (LocationGates.isOnOurRoad) → AlertEngine.
    private struct Drive {
        var filter = LocationFilter()
        var engine = AlertEngine()
        var route: RouteModel?
        /// Город или трасса — как alertContext сервиса (ширина коридора, радиус).
        var context: AlertPolicy.Context = .city
        /// Камера → сколько раз о ней предупредили с начала (новый подъезд).
        private(set) var firstAlerts: [Int: Int] = [:]
        /// Где прозвучало каждое «первое» (x, y в метрах).
        private(set) var firstAlertPoints: [Int: [(x: Double, y: Double)]] = [:]
        private(set) var rejected = 0
        /// Учёт проездов — как в сервисе: на каждом принятом фиксе, с той же
        /// проверкой «доказанно не на дороге камеры» в точке траверза.
        var passTracking = PassTracking()
        /// Записанные проезды: камера → скорость, км/ч.
        private(set) var passes: [Int: Double] = [:]
        private var progress: Double?
        /// Фикс без скорости — держим прошлую, как сервис (нулём считать
        /// нельзя: «стоим» выключил бы гейты посреди езды).
        private var speedKmh = 0.0
        /// Съехали с линии дальше rerouteDeviationMeters (как RouteService.isOffRoute).
        private var offRoute = false

        /// Конец поездки: незакрытые проезды — как flush в endTrip.
        mutating func finish() {
            for pass in passTracking.flush() { passes[pass.camera.id] = pass.speedKmh }
        }

        mutating func run(_ fixes: [LocationFilter.Fix], cameras: [Camera],
                          xy: (Double, Double) -> (x: Double, y: Double)) {
            let cameraAlong: [Int: Double] = route.map { route in
                Dictionary(uniqueKeysWithValues: cameras.compactMap { camera in
                    let hit = route.project(xy(camera.lat, camera.lon))
                    return hit.offset <= 30 ? (camera.id, hit.along) : nil
                })
            } ?? [:]
            for fix in fixes {
                guard case .accepted(let good) = filter.accept(fix, now: fix.timestamp) else {
                    rejected += 1
                    continue
                }
                let here = CLLocationCoordinate2D(latitude: good.lat, longitude: good.lon)
                if let speed = good.speed { speedKmh = max(0, speed) * 3.6 }
                let situation = LocationGates.Situation(coordinate: here, course: good.course,
                                                        speedKmh: speedKmh,
                                                        horizontalAccuracy: good.accuracy, context: context)
                var candidates: [(camera: Camera, distance: Double, onRoute: Bool)] = []
                for camera in cameras {
                    let straight = GeoMath.fastDistance(here.latitude, here.longitude, camera.lat, camera.lon)
                    if engine.isAnnounced(camera.id) {
                        let atTraverse = straight <= max(PassGeometry.traverseLimit(for: camera),
                                                         AppConfig.alertTraverseMeters)
                        if atTraverse {
                            engine.noteApproach(camera.id, distance: straight, at: here, course: situation.course)
                        }
                        engine.noteGeometry(camera.id, atTraverse: atTraverse,
                                            behind: LocationGates.isClearlyBehind(camera, in: situation),
                                            ahead: engine.isPassed(camera.id)
                                                && LocationGates.isReapproach(camera, in: situation,
                                                                              passLine: engine.passLine(camera.id)))
                    }
                    let remaining = offRoute ? nil : progress.flatMap { p in cameraAlong[camera.id].map { $0 - p } }
                    guard let candidate = LocationGates.candidateDistance(straight: straight, routeRemaining: remaining,
                                                                          announced: engine.isAnnounced(camera.id),
                                                                          in: situation) else { continue }
                    candidates.append((camera, candidate.distance, candidate.onRoute))
                }
                // Прогресс по маршруту — после выбора, как в сервисе (отставание на фикс).
                defer {
                    if let route {
                        let hit = route.project(xy(good.lat, good.lon), near: progress)
                        progress = hit.along
                        offRoute = hit.offset > AppConfig.rerouteDeviationMeters
                    }
                }
                candidates.sort { $0.distance < $1.distance }
                let found = candidates.first(where: {
                    LocationGates.isOnOurRoad($0.camera, in: situation, isOnRoute: $0.onRoute)
                })
                let radius = AlertEngine.effectiveRadius(speedKmh: speedKmh, baseRadius: AppConfig.alertRadius,
                                                         context: context)
                for pass in passTracking.update(nearest: found?.camera, nearestDistance: found?.distance,
                                                coordinate: here, speedKmh: speedKmh, roadLimit: nil,
                                                radius: radius, course: situation.course,
                                                now: fix.timestamp,
                                                offRoad: PassGeometry.isProvenOffRoad(camera:at:)) {
                    passes[pass.camera.id] = pass.speedKmh
                }
                guard let nearest = found else { continue }
                if let decision = engine.evaluate(cameraID: nearest.camera.id, distance: nearest.distance,
                                                  radius: radius,
                                                  moving: LocationGates.isFilteringActive(situation)),
                   decision.isFirst {
                    firstAlerts[nearest.camera.id, default: 0] += 1
                    firstAlertPoints[nearest.camera.id, default: []].append(xy(good.lat, good.lon))
                }
            }
        }
    }

    // MARK: - Маршруты

    private let lat0 = 41.30, lon0 = 69.20
    private var kx: Double { 111_320 * cos(lat0 * .pi / 180) }
    private let start = Date(timeIntervalSince1970: 1_770_000_000)

    private func point(_ x: Double, _ y: Double) -> (lat: Double, lon: Double) {
        (lat0 + y / 111_320, lon0 + x / kx)
    }

    private func xy(_ lat: Double, _ lon: Double) -> (x: Double, y: Double) {
        ((lon - lon0) * kx, (lat - lat0) * 111_320)
    }

    /// Отрезок пути: куда ехать (x, y в метрах), с какой скоростью (м/с) и
    /// сколько стоять в конце, с.
    private struct Leg {
        let x: Double, y: Double, speed: Double
        var stopSeconds = 0
    }

    /// Фикс раз в секунду вдоль ломаной; курс — по отрезку, достоверный. На
    /// стоянке курса нет (−1), скорость 0 — как отдаёт iOS стоящей машине.
    private func fixes(from origin: (Double, Double), legs: [Leg]) -> [LocationFilter.Fix] {
        var out: [LocationFilter.Fix] = []
        var (x, y) = origin
        var t = start
        func emit(_ x: Double, _ y: Double, speed: Double, course: Double) {
            let p = point(x, y)
            out.append(LocationFilter.Fix(lat: p.lat, lon: p.lon, horizontalAccuracy: 6,
                                          speed: speed, speedAccuracy: speed > 0 ? 1 : -1,
                                          course: course, courseAccuracy: course >= 0 ? 5 : -1,
                                          timestamp: t))
            t = t.addingTimeInterval(1)
        }
        for leg in legs {
            let dx = leg.x - x, dy = leg.y - y
            let length = (dx * dx + dy * dy).squareRoot()
            let course = (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            let steps = max(1, Int((length / leg.speed).rounded()))
            for k in 1...steps {
                let f = Double(k) / Double(steps)
                emit(x + dx * f, y + dy * f, speed: leg.speed, course: course)
            }
            (x, y) = (leg.x, leg.y)
            for _ in 0..<leg.stopSeconds { emit(x, y, speed: 0, course: -1) }
        }
        return out
    }

    /// Камера без доказанных сторон (половина базы): может снимать обе стороны.
    private func camera(_ id: Int, x: Double, y: Double, type: String = "Стационар радар") -> Camera {
        let p = point(x, y)
        return Camera(id: id, region: "Т", city: "", location: "к", lat: p.lat, lon: p.lon,
                      type: type, violations: [], needsReview: false, axis: nil, dir: nil,
                      lanes: 2, cls: nil, road: nil, split: nil, twin: nil)
    }

    /// Камера со снапом, как в базе: кусок своей проезжей части ±100 м по
    /// оси, разделённая дорога, стороны не доказаны.
    private func snappedCamera(_ id: Int, x: Double, y: Double, axis: Double, lanes: Int = 3) -> Camera {
        let p = point(x, y)
        let rad = axis * .pi / 180
        let dLat = Int((100 * cos(rad) / 111_320 * 1e6).rounded())
        let dLon = Int((100 * sin(rad) / kx * 1e6).rounded())
        return Camera(id: id, region: "Т", city: "", location: "к", lat: p.lat, lon: p.lon,
                      type: "Стационар радар", violations: [], needsReview: false, axis: Int(axis), dir: nil,
                      lanes: lanes, cls: "primary", road: [-dLat, -dLon, 0, 0, dLat, dLon],
                      split: true, twin: nil)
    }

    /// Петля по часовой стрелке: из точки `from` с курсом на север, центр —
    /// справа на `radius`, `degrees` дуги; точки дуги — легами по 10°.
    private func loop(from start: (x: Double, y: Double), radius: Double, degrees: Double,
                      speed: Double) -> (legs: [Leg], end: (x: Double, y: Double)) {
        let centre = (x: start.x + radius, y: start.y)
        var legs: [Leg] = []
        var end = start
        for step in stride(from: 10.0, through: degrees, by: 10) {
            let angle = (180 - step) * .pi / 180   // от западной точки по часовой
            end = (centre.x + radius * cos(angle), centre.y + radius * sin(angle))
            legs.append(Leg(x: end.x, y: end.y, speed: speed))
        }
        return (legs, end)
    }

    // MARK: - A6: разворот и круг

    /// Проехали камеру, через 300 м развернулись и едем обратно мимо неё:
    /// стороны не доказаны — камера снимает и нашу, и предупредить надо снова.
    /// До 20.10 движок помнил «уже сказал» всю поездку и молчал.
    func testUTurnAfterACameraWarnsAgain() {
        let route = fixes(from: (0, 0), legs: [Leg(x: 1300, y: 0, speed: 14),
                                               Leg(x: 0, y: 0, speed: 14)])
        var drive = Drive()
        drive.run(route, cameras: [camera(1, x: 1000, y: 0)], xy: xy)
        XCTAssertEqual(drive.rejected, 0)
        XCTAssertEqual(drive.firstAlerts[1], 2, "туда и после разворота обратно")
    }

    /// Круг по кварталу и снова по той же улице в ту же сторону.
    func testLoopAroundTheBlockWarnsAgain() {
        let route = fixes(from: (0, 0), legs: [Leg(x: 1250, y: 0, speed: 12),
                                               Leg(x: 1250, y: 250, speed: 10),
                                               Leg(x: 600, y: 250, speed: 12),
                                               Leg(x: 600, y: 0, speed: 10),
                                               Leg(x: 1300, y: 0, speed: 12)])
        var drive = Drive()
        drive.run(route, cameras: [camera(1, x: 1000, y: 0)], xy: xy)
        XCTAssertEqual(drive.firstAlerts[1], 2)
    }

    /// Стоим у светофора в 40 м за камерой две минуты: курса нет, она ближайшая
    /// «вокруг» — но это та же камера, о ней уже сказали. Повтора нет.
    func testStandingRightAfterACameraStaysQuiet() {
        let route = fixes(from: (0, 0), legs: [Leg(x: 1040, y: 0, speed: 14, stopSeconds: 120),
                                               Leg(x: 1600, y: 0, speed: 14)])
        var drive = Drive()
        drive.run(route, cameras: [camera(1, x: 1000, y: 0)], xy: xy)
        XCTAssertEqual(drive.firstAlerts[1], 1)
    }

    /// Пробка перед камерой: десять минут стоим в 150 м до неё — одно
    /// предупреждение на весь подъезд, не по разу на каждую остановку.
    func testJamBeforeACameraWarnsOnce() {
        let route = fixes(from: (0, 0), legs: [Leg(x: 850, y: 0, speed: 14, stopSeconds: 300),
                                               Leg(x: 900, y: 0, speed: 2, stopSeconds: 300),
                                               Leg(x: 1500, y: 0, speed: 12)])
        var drive = Drive()
        drive.run(route, cameras: [camera(1, x: 1000, y: 0)], xy: xy)
        XCTAssertEqual(drive.firstAlerts[1], 1)
    }

    /// Движок сам по себе: «проехали» — о камере сказали, были на траверзе и
    /// она явно позади два фикса подряд; «новый подъезд» — явно впереди два
    /// фикса подряд. Одиночный кривой фикс — ни то, ни другое.
    func testPassedCameraRestartsOnlyOnARealApproach() {
        var engine = AlertEngine()
        let cam = camera(7, x: 0, y: 0)
        XCTAssertEqual(engine.evaluate(cameraID: 7, distance: 50, radius: 400, moving: true)?.level, 3)
        // Без траверза «позади» — не «проехали» (свернули до неё, шпилька).
        for _ in 0..<3 { engine.noteGeometry(7, atTraverse: false, behind: true, ahead: false) }
        for _ in 0..<3 { engine.noteGeometry(7, atTraverse: false, behind: false, ahead: true) }
        XCTAssertNil(engine.evaluate(cameraID: 7, distance: 150, radius: 400, moving: true), "серия не забыта")
        // Траверз; позади, кривой фикс, позади — ещё не проехали.
        engine.noteGeometry(7, atTraverse: true, behind: true, ahead: false)
        engine.noteGeometry(7, atTraverse: false, behind: false, ahead: false)
        engine.noteGeometry(7, atTraverse: false, behind: true, ahead: false)
        for _ in 0..<3 { engine.noteGeometry(7, atTraverse: false, behind: false, ahead: true) }
        XCTAssertNil(engine.evaluate(cameraID: 7, distance: 150, radius: 400, moving: true), "не проехали — не забыта")
        // Позади два подряд — проехали; стоим (ни позади, ни впереди) — та же камера.
        engine.noteGeometry(7, atTraverse: true, behind: true, ahead: false)
        engine.noteGeometry(7, atTraverse: false, behind: true, ahead: false)
        engine.noteGeometry(7, atTraverse: false, behind: true, ahead: false)
        for _ in 0..<5 { engine.noteGeometry(7, atTraverse: false, behind: false, ahead: false) }
        XCTAssertNil(engine.evaluate(cameraID: 7, distance: 150, radius: 400, moving: true))
        // Впереди один раз, потом снова позади — не подъезд (отражение).
        engine.noteGeometry(7, atTraverse: false, behind: false, ahead: true)
        engine.noteGeometry(7, atTraverse: false, behind: true, ahead: false)
        engine.noteGeometry(7, atTraverse: false, behind: false, ahead: true)
        XCTAssertNil(engine.evaluate(cameraID: 7, distance: 150, radius: 400, moving: true))
        // Впереди два подряд — новый подъезд, серия с начала; но первое
        // оповещение перевзведённой — только на ходу (стоя гейтов нет).
        engine.noteGeometry(7, atTraverse: false, behind: false, ahead: true)
        // В полосе гистерезиса (за радиусом) решения нет — перевзвод не снят:
        // иначе дальше, стоя без гейтов, она звучала бы «первой» (N3).
        XCTAssertNil(engine.evaluate(cameraID: 7, distance: 440, radius: 400, moving: true))
        XCTAssertNil(engine.evaluate(cameraID: 7, distance: 140, radius: 400, moving: false))
        XCTAssertEqual(engine.evaluate(cameraID: 7, distance: 140, radius: 400, moving: true)?.isFirst, true)
        // Геометрия: без курса «позади»/«впереди» не решается; шум траверза — не «позади».
        let east = { (x: Double) in LocationGates.Situation(
            coordinate: CLLocationCoordinate2D(latitude: self.point(x, 0).lat, longitude: self.point(x, 0).lon),
            course: 90, speedKmh: 50, horizontalAccuracy: 6, context: .city) }
        XCTAssertTrue(LocationGates.isClearlyBehind(cam, in: east(200)))
        XCTAssertFalse(LocationGates.isClearlyBehind(cam, in: east(30)))
        XCTAssertTrue(LocationGates.isClearlyAhead(cam, in: east(-200)))
        XCTAssertFalse(LocationGates.isClearlyAhead(cam, in: east(-30)))
        let standing = LocationGates.Situation(coordinate: east(200).coordinate, course: -1, speedKmh: 0,
                                               horizontalAccuracy: 6, context: .city)
        XCTAssertFalse(LocationGates.isClearlyBehind(cam, in: standing))
        XCTAssertFalse(LocationGates.isClearlyAhead(cam, in: standing))
    }

    // MARK: - S4 на маршруте (ревью 20.10)

    /// Камера на маршруте: остаток по маршруту держит её «0 м» за спиной ещё
    /// фикс-другой после траверза. Второго «0 метров» быть не должно — это
    /// была бы каждая камера каждого маршрута.
    func testRouteCameraWarnsOnce() {
        let track = fixes(from: (0, 0), legs: [Leg(x: 1800, y: 0, speed: 14)])
        var drive = Drive()
        drive.route = RouteModel(points: [(0, 0), (1800, 0)])
        drive.run(track, cameras: [camera(1, x: 1000, y: 0)], xy: xy)
        XCTAssertEqual(drive.firstAlerts[1], 1)
    }

    /// Маршрут сам с разворотом: туда мимо камеры, разворот через 300 м и
    /// обратно мимо неё же. Позиция камеры на маршруте одна (первый проезд),
    /// на обратном пути она — камера «как все», и о ней снова предупреждают.
    func testRouteWithAUTurnWarnsAgainOnTheWayBack() {
        let track = fixes(from: (0, 0), legs: [Leg(x: 1300, y: 0, speed: 14), Leg(x: 0, y: 0, speed: 14)])
        var drive = Drive()
        drive.route = RouteModel(points: [(0, 0), (1300, 0), (0, 0)])
        drive.run(track, cameras: [camera(1, x: 1000, y: 0)], xy: xy)
        XCTAssertEqual(drive.firstAlerts[1], 2)
    }

    /// Один фикс с кривым, но «достоверным» курсом (отражение от стены): ни
    /// камера впереди не становится «проеханной», ни проеханная позади — «новой».
    func testOneBadCourseFixDoesNotWarnTwice() {
        var route = fixes(from: (0, 0), legs: [Leg(x: 1600, y: 0, speed: 14)])
        func flipCourse(at index: Int) {
            let f = route[index]
            route[index] = LocationFilter.Fix(lat: f.lat, lon: f.lon, horizontalAccuracy: f.horizontalAccuracy,
                                              speed: f.speed, speedAccuracy: f.speedAccuracy, course: 270,
                                              courseAccuracy: 5, timestamp: f.timestamp)
        }
        flipCourse(at: 50)    // ~700 м: камера в 300 м впереди «вдруг позади»
        flipCourse(at: 82)    // ~1150 м: проеханная «вдруг впереди»
        var drive = Drive()
        drive.run(route, cameras: [camera(1, x: 1000, y: 0)], xy: xy)
        XCTAssertEqual(drive.firstAlerts[1], 1)
    }

    // MARK: - S4: ревью 20.10, третий круг

    /// Круг по кварталу со светофором на обратной улице: камера, проеханная
    /// по y=0, с параллельной улицы y=250 «впереди по курсу», но на чужой
    /// дороге — не перевзводится; стоя у светофора — не звучит. Второе
    /// «первое» — на настоящем подъезде по y=0.
    func testLoopWithALightOnTheParallelStreet() {
        let route = fixes(from: (0, 0), legs: [Leg(x: 1250, y: 0, speed: 12),
                                               Leg(x: 1250, y: 250, speed: 10),
                                               Leg(x: 1100, y: 250, speed: 10, stopSeconds: 40),
                                               Leg(x: 600, y: 250, speed: 12),
                                               Leg(x: 600, y: 0, speed: 10),
                                               Leg(x: 1300, y: 0, speed: 12)])
        var drive = Drive()
        drive.run(route, cameras: [camera(1, x: 1000, y: 0)], xy: xy)
        XCTAssertEqual(drive.firstAlerts[1], 2)
        let second = drive.firstAlertPoints[1]?.last
        XCTAssertEqual(second?.y ?? 999, 0, accuracy: 1, "второе «первое» — на подъезде по y=0, а не у светофора")
    }

    /// Разворот всего в 60 м за камерой: «впереди» после него — дважды, и
    /// подъезд новый (порог «впереди» мягче порога «позади»).
    func testUTurnSoonAfterTheCameraWarnsAgain() {
        let route = fixes(from: (0, 0), legs: [Leg(x: 1065, y: 0, speed: 12), Leg(x: 0, y: 0, speed: 12)])
        var drive = Drive()
        drive.run(route, cameras: [camera(1, x: 1000, y: 0)], xy: xy)
        XCTAssertEqual(drive.firstAlerts[1], 2)
    }

    /// Развязка-клевер (ревью S4, третий круг): проехали камеру со снапом на
    /// север и ушли петлёй на 270° на пересекающую дорогу. На петле курс на
    /// одну-три точки смотрит прямо на камеру, и коридор (сбоку от НАШЕГО
    /// курса) перевзводил её — второе «первое» в 190 м от камеры, с петли.
    /// Своя дорога камеры (кусок и прямая по оси) такого не допускает — на
    /// любой петле: начало 120–340 м за камерой, радиус 35–80 м.
    func testCloverleafLoopDoesNotWarnTwice() {
        for loopStart in [120.0, 200, 340] {
            for radius in [35.0, 55, 80] {
                let ramp = loop(from: (0, loopStart), radius: radius, degrees: 270, speed: 8.3)
                let route = fixes(from: (0, -900), legs: [Leg(x: 0, y: loopStart, speed: 13.9)] + ramp.legs
                                    + [Leg(x: -600, y: ramp.end.y, speed: 13.9)])
                var drive = Drive()
                drive.run(route, cameras: [snappedCamera(1, x: 0, y: 0, axis: 0)], xy: xy)
                XCTAssertEqual(drive.firstAlerts[1], 1,
                               "петля с \(Int(loopStart)) м, радиус \(Int(radius)): \(drive.firstAlertPoints[1] ?? [])")
            }
        }
    }

    /// Тренога (и своя камера) без куска и оси: на клевере коридор
    /// перевзводил её с петли — сирена второй раз. Своя дорога такой камеры —
    /// та, по которой мы мимо неё проехали (ревью S4, четвёртый круг).
    func testCloverleafLoopDoesNotRepeatATripod() {
        for type in ["Тренога", "Стационар радар"] {
            for loopStart in [120.0, 200, 340] {
                for radius in [35.0, 55, 80] {
                    let ramp = loop(from: (0, loopStart), radius: radius, degrees: 270, speed: 8.3)
                    let route = fixes(from: (0, -900), legs: [Leg(x: 0, y: loopStart, speed: 13.9)] + ramp.legs
                                        + [Leg(x: -600, y: ramp.end.y, speed: 13.9)])
                    var drive = Drive()
                    drive.run(route, cameras: [camera(1, x: 0, y: 0, type: type)], xy: xy)
                    XCTAssertEqual(drive.firstAlerts[1], 1,
                                   "\(type), петля с \(Int(loopStart)) м, радиус \(Int(radius))")
                }
            }
        }
    }

    /// Тренога, поставленная в 18 м от дороги: разворот по той же дороге —
    /// новый подъезд (своя дорога — наш след, а не отметка).
    func testTripodOffTheRoadStillWarnsAfterAUTurn() {
        let route = fixes(from: (0, -900), legs: [Leg(x: 0, y: 300, speed: 13.9),
                                                  Leg(x: -10, y: 300, speed: 5),
                                                  Leg(x: -10, y: -900, speed: 13.9)])
        var drive = Drive()
        drive.run(route, cameras: [camera(1, x: 18, y: 0, type: "Тренога")], xy: xy)
        XCTAssertEqual(drive.firstAlerts[1], 2)
    }

    /// Широкий проспект: разворот на дальнюю проезжую часть в 42 м от оси
    /// камеры с недоказанными сторонами — новый подъезд (она может снимать
    /// и ту сторону; до четвёртого круга предел был 35 м — молчание).
    func testFarCarriagewayOfAWideAvenueWarnsAgain() {
        let route = fixes(from: (0, -900), legs: [Leg(x: 0, y: 300, speed: 13.9),
                                                  Leg(x: -42, y: 300, speed: 5),
                                                  Leg(x: -42, y: -900, speed: 13.9)])
        var drive = Drive()
        drive.run(route, cameras: [snappedCamera(1, x: 0, y: 0, axis: 0)], xy: xy)
        XCTAssertEqual(drive.firstAlerts[1], 2)
    }

    /// Настоящий разворот на встречную проезжую часть (12 м от оси) у камеры
    /// со снапом — по-прежнему новый подъезд.
    func testSnappedCameraUTurnStillWarnsAgain() {
        let route = fixes(from: (0, -900), legs: [Leg(x: 0, y: 300, speed: 13.9),
                                                  Leg(x: 12, y: 300, speed: 5),
                                                  Leg(x: 12, y: -900, speed: 13.9)])
        var drive = Drive()
        drive.run(route, cameras: [snappedCamera(1, x: 0, y: 0, axis: 0)], xy: xy)
        XCTAssertEqual(drive.firstAlerts[1], 2)
    }

    /// Перевзвод на параллельной улице, проверка в полосе гистерезиса без
    /// решения, потом красный свет (гейты выключены): камера с той улицы не
    /// звучит «первой» (ревью S4, третий круг, N3).
    func testRearmedCameraStaysQuietAtALightOnAParallelStreet() {
        let route = fixes(from: (0, 0), legs: [Leg(x: 1475, y: 0, speed: 13.9),
                                               Leg(x: 1475, y: 72, speed: 8),
                                               Leg(x: 1300, y: 72, speed: 13.9, stopSeconds: 40),
                                               Leg(x: 500, y: 72, speed: 13.9)])
        var drive = Drive()
        drive.run(route, cameras: [camera(1, x: 1000, y: 0)], xy: xy)
        XCTAssertEqual(drive.firstAlerts[1], 1, "\(drive.firstAlertPoints[1] ?? [])")
    }

    // MARK: - S7: съехали с маршрута без сети

    /// Маршрут на восток с камерой R в 300 м за поворотом; водитель свернул
    /// на север (сети нет — перестроения нет), на новой дороге камера C.
    /// Застывший прогресс держал R «по маршруту» в 300 м и нашей без
    /// условий: C молчала, пока не стала ближе R, а R звучала с чужой дороги.
    func testOffRouteCamerasDoNotMaskTheRealOne() {
        let route = fixes(from: (0, 0), legs: [Leg(x: 600, y: 0, speed: 13.9),
                                               Leg(x: 600, y: 1400, speed: 13.9)])
        var drive = Drive()
        drive.route = RouteModel(points: [(0, 0), (2000, 0)])
        drive.run(route, cameras: [camera(1, x: 900, y: 0), camera(2, x: 600, y: 800)], xy: xy)
        let first = drive.firstAlertPoints[2]?.first
        XCTAssertNotNil(first, "настоящая камера на новой дороге звучит")
        XCTAssertLessThan(first?.y ?? 999, 450,
                          "звучит за полный радиус, а не когда стала ближе застывшей R: \(drive.firstAlertPoints)")
    }

    // MARK: - A3: тоннель

    /// 45 с без фиксов на 50 км/ч, потом сигнал на 600 м дальше: перелёт
    /// правдоподобен (скорость та же) — фикс принят; камера сразу за выездом
    /// предупреждается; камера, проеханная в тоннеле, позади — молчит.
    func testTunnelGapThenTheCameraAfterTheExit() {
        var route = fixes(from: (0, 0), legs: [Leg(x: 1000, y: 0, speed: 14)])
        let resumed = fixes(from: (1625, 0), legs: [Leg(x: 2600, y: 0, speed: 14)])
        let gap = route.last!.timestamp.addingTimeInterval(45).timeIntervalSince(resumed.first!.timestamp)
        route += resumed.map {
            LocationFilter.Fix(lat: $0.lat, lon: $0.lon, horizontalAccuracy: $0.horizontalAccuracy,
                               speed: $0.speed, speedAccuracy: $0.speedAccuracy, course: $0.course,
                               courseAccuracy: $0.courseAccuracy, timestamp: $0.timestamp.addingTimeInterval(gap))
        }
        var drive = Drive()
        drive.run(route, cameras: [camera(1, x: 1400, y: 0), camera(2, x: 1950, y: 0)], xy: xy)
        XCTAssertEqual(drive.rejected, 0, "после тоннеля фиксы принимаются")
        XCTAssertEqual(drive.firstAlerts[2], 1, "камера за выездом звучит")
        XCTAssertLessThanOrEqual(drive.firstAlerts[1] ?? 0, 1, "проеханная в тоннеле не звучит после выезда")
        // Проезды (12в A3): камеру в тоннеле не мерили — проезда нет, и уж
        // точно не с выдуманной скоростью; камера за выездом — честные 50.
        drive.finish()
        XCTAssertNil(drive.passes[1], "камера, проеханная без сигнала, — не проезд")
        XCTAssertEqual(drive.passes[2] ?? 0, 50.4, accuracy: 1)
    }

    /// Спидометр после 45 с без сигнала: та же скорость — ни скачка, ни
    /// «хвоста» от прежнего значения (12в A3).
    func testSpeedAfterATunnelDoesNotJump() {
        var smoother = SpeedSmoother()
        let t0 = start
        var shown = 0.0
        for second in 0..<10 { shown = smoother.update(rawKmh: 50, at: t0.addingTimeInterval(Double(second))) }
        XCTAssertEqual(shown, 50, accuracy: 0.5)
        let afterGap = smoother.update(rawKmh: 51, at: t0.addingTimeInterval(55))
        XCTAssertEqual(afterGap, 51, accuracy: 1.5, "после тоннеля — сразу живая цифра")
        let braked = smoother.update(rawKmh: 20, at: t0.addingTimeInterval(56))
        XCTAssertLessThan(braked, 30, "настоящее торможение — сразу, без хвоста")
    }

    // MARK: - A4: плохая точность

    /// Каньон: после 300 м нормального GPS — фиксы точностью 60 м без курса
    /// и скорости системы, с дрожанием ±35 м вбок (12в A4). Гарантировано:
    /// своя камера звучит, проезда мимо камеры соседней улицы нет.
    ///
    /// НЕ гарантировано и вынесено владельцу (план 12в, «Ждёт владельца»):
    /// курс по земле между такими точками иногда не считается (сдвиг меньше
    /// 12 м), курс на тик «неизвестен», гейты выключаются — и по правилу
    /// «неизвестно — предупреждать» звучит камера соседней улицы, даже в
    /// 300 м. Заглушить такой тик — риск задержать настоящую камеру.
    private func noisyFixes(lateralNoise: Double, accuracy: Double) -> [LocationFilter.Fix] {
        let clean = fixes(from: (0, 0), legs: [Leg(x: 2000, y: 0, speed: 12)])
        // Первые 300 м — нормальный GPS (скорость и курс есть), дальше каньон.
        let goodPrefix = 25
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func next() -> Double {   // xorshift — воспроизводимо
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Double(seed % 10_000) / 10_000 * 2 - 1
        }
        return clean.enumerated().map { index, fix in
            guard index >= goodPrefix else { return fix }
            let p = xy(fix.lat, fix.lon)
            let q = point(p.x + next() * lateralNoise * 0.3, p.y + next() * lateralNoise)
            return LocationFilter.Fix(lat: q.lat, lon: q.lon, horizontalAccuracy: accuracy,
                                      speed: -1, speedAccuracy: -1, course: -1, courseAccuracy: -1,
                                      timestamp: fix.timestamp)
        }
    }

    func testWiFiQualityFixesKeepTheOwnCameraAndRecordNoFalsePass() {
        var drive = Drive()
        drive.run(noisyFixes(lateralNoise: 35, accuracy: 60),
                  cameras: [snappedCamera(1, x: 1000, y: 300, axis: 90), snappedCamera(2, x: 1600, y: 0, axis: 90)],
                  xy: xy)
        drive.finish()
        XCTAssertEqual(drive.firstAlerts[2], 1, "своя камера звучит и при плохом GPS")
        XCTAssertNil(drive.passes[1], "проезда мимо камеры соседней улицы нет")
        XCTAssertNotNil(drive.passes[2], "проезд своей записан")
    }

    /// Хуже 65 м — фикс в оповещения не идёт вовсе.
    func testWorseThanTheLimitIsRejected() {
        var drive = Drive()
        drive.run(noisyFixes(lateralNoise: 35, accuracy: AppConfig.maxHorizontalAccuracyMeters + 5),
                  cameras: [snappedCamera(2, x: 1600, y: 0, axis: 90)], xy: xy)
        XCTAssertGreaterThan(drive.rejected, 100)
        XCTAssertNil(drive.firstAlerts[2])
    }

    // MARK: - A4: выброс

    /// Один фикс в 300 м вбок посреди поездки (отражение от стены): отброшен,
    /// камера на «той» улице не звучит.
    func testOneSpikeSidewaysIsRejected() {
        var route = fixes(from: (0, 0), legs: [Leg(x: 1500, y: 0, speed: 14)])
        let p = point(700, 300)
        let spike = route[50]
        route.insert(LocationFilter.Fix(lat: p.lat, lon: p.lon, horizontalAccuracy: 10, speed: 14,
                                        speedAccuracy: 1, course: 90, courseAccuracy: 5,
                                        timestamp: spike.timestamp.addingTimeInterval(0.5)), at: 51)
        var drive = Drive()
        drive.run(route, cameras: [camera(1, x: 800, y: 300), camera(2, x: 1200, y: 0)], xy: xy)
        XCTAssertEqual(drive.rejected, 1)
        XCTAssertNil(drive.firstAlerts[1], "камера на соседней улице не звучит из-за выброса")
        XCTAssertEqual(drive.firstAlerts[2], 1)
    }
}

// MARK: - A1: город с камерами на настоящей базе

extension ScenarioDriveTests {
    /// Проезд по собственной проезжей части камеры (`road` из базы) с
    /// разгоном 500 м и выездом 200 м, в её направлении, где оно известно.
    private func ownRoadDrive(for target: Camera, approach: Double = 500) -> [(x: Double, y: Double)]? {
        guard let road = target.road, road.count >= 4 else { return nil }
        var path: [(x: Double, y: Double)] = stride(from: 0, to: road.count - 1, by: 2).map { i in
            xy(target.lat + Double(road[i]) / 1e6, target.lon + Double(road[i + 1]) / 1e6)
        }
        guard let first = path.first, let last = path.last else { return nil }
        let bearing = (atan2(last.x - first.x, last.y - first.y) * 180 / .pi + 360)
            .truncatingRemainder(dividingBy: 360)
        if let dir = target.dir, GeoMath.angleDifference(bearing, Double(dir)) > 90 { path.reverse() }
        func extended(_ a: (x: Double, y: Double), from b: (x: Double, y: Double), by meters: Double)
            -> (x: Double, y: Double) {
            let dx = a.x - b.x, dy = a.y - b.y
            let length = max(0.1, (dx * dx + dy * dy).squareRoot())
            return (a.x + dx / length * meters, a.y + dy / length * meters)
        }
        let head = extended(path[0], from: path[1], by: approach)
        let tail = extended(path[path.count - 1], from: path[path.count - 2], by: 200)
        return [head] + path + [tail]
    }

    /// Боковое отклонение от пути — только для точки, чья проекция внутри
    /// него: камера за концом линии (следующая на той же дороге) — не «сбоку»,
    /// её расстояние продольное. nil — судить нечем.
    private func lateral(_ p: (x: Double, y: Double), to path: [(x: Double, y: Double)]) -> Double? {
        let hit = RouteModel(points: path).project(p)
        let total = zip(path, path.dropFirst()).reduce(0.0) { sum, pair in
            sum + ((pair.1.x - pair.0.x) * (pair.1.x - pair.0.x) + (pair.1.y - pair.0.y) * (pair.1.y - pair.0.y)).squareRoot()
        }
        guard hit.along > 5, hit.along < total - 5 else { return nil }
        return hit.offset
    }

    /// A1 (план 12в): ташкентские камеры базы (каждая четвёртая, ~200), проезд
    /// по их собственной проезжей части через весь конвейер: о самой камере
    /// предупредили — и заранее, кроме стоящих в группе с камерой перед ней
    /// (голос объявляет группу); ни одна камера дальше 160 м сбоку от пути
    /// (параллельная улица, эстакада — коридор города не шире 90 м,
    /// щедрый — 140) не прозвучала. Камеры за концом пути не судим: их
    /// расстояние продольное (следующая на той же дороге).
    private struct OwnRoadResult {
        var drives = 0
        var silent: [Int] = []
        var late: [Int] = []
        var offPath: [(target: Int, other: Int, lateral: Int)] = []
        /// Проехали по своей дороге через камеру, а проезд не записан.
        var unrecorded: [Int] = []
    }

    private func bundledCameras() throws -> [Camera] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "cameras", withExtension: "json"))
        return TwinCheck.verified(try JSONDecoder().decode([Camera].self, from: Data(contentsOf: url))).cameras
    }

    /// Проезды по собственной дороге каждой камеры выборки: кто промолчал,
    /// кто прозвучал позже `minAhead` м (не в группе), кто чужой сбоку.
    private func ownRoadDrives(_ sample: [Camera], all: [Camera], speed: Double,
                               context: AlertPolicy.Context, minAhead: Double,
                               approach: Double = 500,
                               groupMeters: Double = AppConfig.voiceGroupMeters) -> OwnRoadResult {
        var result = OwnRoadResult()
        for target in sample {
            guard let path = ownRoadDrive(for: target, approach: approach) else { continue }
            result.drives += 1
            let legs = path.dropFirst().map { Leg(x: $0.x, y: $0.y, speed: speed) }
            let fixes = self.fixes(from: (path[0].x, path[0].y), legs: Array(legs))
            let nearby = all.filter {
                GeoMath.fastDistance($0.lat, $0.lon, target.lat, target.lon) <= 3_000
            }
            var drive = Drive()
            drive.context = context
            drive.run(fixes, cameras: nearby, xy: xy)
            drive.finish()
            if target.kind.recordsPasses, drive.passes[target.id] == nil,
               !drive.passes.keys.contains(where: { other in
                   // Дубль базы в 15 м — его проезд и есть проезд цели (11.1).
                   guard let camera = nearby.first(where: { $0.id == other }) else { return false }
                   return GeoMath.fastDistance(camera.lat, camera.lon, target.lat, target.lon)
                       <= AppConfig.passDuplicateMeters
               }) {
                result.unrecorded.append(target.id)
            }
            let targetXY = xy(target.lat, target.lon)
            // Группа: о камере в voiceGroupMeters от цели сказали — голос
            // объявил и цель («Камеры впереди…»).
            let grouped = drive.firstAlertPoints.keys.contains { other in
                guard other != target.id, let camera = nearby.first(where: { $0.id == other }) else { return false }
                return GeoMath.fastDistance(camera.lat, camera.lon, target.lat, target.lon)
                    <= groupMeters
            }
            if let first = drive.firstAlertPoints[target.id]?.first {
                let ahead = ((first.x - targetXY.x) * (first.x - targetXY.x)
                             + (first.y - targetXY.y) * (first.y - targetXY.y)).squareRoot()
                if ahead < minAhead, !grouped { result.late.append(target.id) }
            } else if !grouped {
                result.silent.append(target.id)
            }
            for (other, points) in drive.firstAlertPoints where other != target.id {
                guard let camera = nearby.first(where: { $0.id == other }), !points.isEmpty else { continue }
                if let side = lateral(xy(camera.lat, camera.lon), to: path), side > 160 {
                    result.offPath.append((target.id, other, Int(side)))
                }
            }
        }
        return result
    }

    func testCityCamerasOnTheirOwnRoad() throws {
        let all = try bundledCameras()
        let city = all.filter { $0.region.hasPrefix("Toshkent shahar") && $0.road != nil
            && $0.hasTrustedRoadProfile && $0.needsReview != true }
        let sample = stride(from: 0, to: city.count, by: 4).map { city[$0] }
        let result = ownRoadDrives(sample, all: all, speed: 14, context: .city, minAhead: 60)
        print("A1: камер \(result.drives), молчали \(result.silent), поздно \(result.late), чужие \(result.offPath.prefix(20)), без проезда \(result.unrecorded)")
        XCTAssertGreaterThan(result.drives, 150)
        XCTAssertEqual(result.silent, [], "о камере на своей дороге молчать нельзя")
        XCTAssertEqual(result.late, [], "первое — заранее, если камера не в группе с соседкой")
        XCTAssertEqual(result.offPath.map(\.other), [], "камера дальше 160 м от пути — не наша")
        XCTAssertEqual(result.unrecorded, [], "проехали через камеру по её дороге — проезд записан")
    }

    /// A2 (план 12в): трасса 94 км/ч — камеры на trunk/motorway вне Ташкента.
    /// Умный радиус даёт водителю секунды, а не метры: первое оповещение —
    /// не ближе 0,8 радиуса на этой скорости, кроме камеры, перед которой в
    /// пределах радиуса прозвучала другая (пока не проехали её, ближайшая —
    /// она: 10 из 182 стоят в 90–650 м за соседкой); молчащих и
    /// чужих сбоку нет и на трассовом, более широком коридоре.
    func testHighwayCamerasWarnEarlyEnough() throws {
        let all = try bundledCameras()
        let highway = all.filter { !$0.region.hasPrefix("Toshkent shahar") && $0.road != nil
            && ["trunk", "motorway"].contains($0.cls ?? "") && $0.needsReview != true }
        let sample = stride(from: 0, to: highway.count, by: max(1, highway.count / 150)).map { highway[$0] }
        let speed = 26.0
        let radius = AlertEngine.effectiveRadius(speedKmh: speed * 3.6, baseRadius: AppConfig.alertRadius,
                                                 context: .highway)
        // Разгон длиннее радиуса: на трассе он 754 м, и с городскими 500 м
        // оповещению физически негде было прозвучать раньше.
        let result = ownRoadDrives(sample, all: all, speed: speed, context: .highway, minAhead: radius * 0.8,
                                   approach: radius + 400, groupMeters: radius)
        print("A2: камер \(result.drives), радиус \(Int(radius)), молчали \(result.silent), поздно \(result.late), чужие \(result.offPath.prefix(20))")
        XCTAssertGreaterThan(result.drives, 100)
        XCTAssertEqual(result.silent, [])
        XCTAssertEqual(result.late, [], "на трассе — заранее, по секундам, а не по метрам")
        XCTAssertEqual(result.offPath.map(\.other), [])
    }
}
