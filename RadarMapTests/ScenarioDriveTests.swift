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

    private struct Drive {
        var filter = LocationFilter()
        var engine = AlertEngine()
        /// Камера → сколько раз о ней предупредили с начала (новый подъезд).
        private(set) var firstAlerts: [Int: Int] = [:]
        private(set) var rejected = 0

        mutating func run(_ fixes: [LocationFilter.Fix], cameras: [Camera]) {
            for fix in fixes {
                guard case .accepted(let good) = filter.accept(fix, now: fix.timestamp) else {
                    rejected += 1
                    continue
                }
                let here = CLLocationCoordinate2D(latitude: good.lat, longitude: good.lon)
                let speedKmh = max(0, good.speed ?? 0) * 3.6
                let situation = LocationGates.Situation(coordinate: here, course: good.course,
                                                        speedKmh: speedKmh,
                                                        horizontalAccuracy: good.accuracy, context: .city)
                // Как в LocationService.recomputeNearest: проеханные — до выбора ближайшей.
                engine.notePassed(cameras.filter { engine.isAnnounced($0.id) }, in: situation)
                var nearest: (camera: Camera, distance: Double)?
                for camera in cameras {
                    let distance = GeoMath.fastDistance(here.latitude, here.longitude, camera.lat, camera.lon)
                    guard LocationGates.isOnOurRoad(camera, in: situation, isOnRoute: false),
                          LocationGates.isAhead(camera, in: situation) else { continue }
                    if distance < (nearest?.distance ?? .greatestFiniteMagnitude) { nearest = (camera, distance) }
                }
                guard let nearest else { continue }
                let radius = AlertEngine.effectiveRadius(speedKmh: speedKmh, baseRadius: AppConfig.alertRadius)
                if let decision = engine.evaluate(cameraID: nearest.camera.id, distance: nearest.distance,
                                                  radius: radius,
                                                  approaching: LocationGates.isFilteringActive(situation)),
                   decision.isFirst {
                    firstAlerts[nearest.camera.id, default: 0] += 1
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
    private func camera(_ id: Int, x: Double, y: Double) -> Camera {
        let p = point(x, y)
        return Camera(id: id, region: "Т", city: "", location: "к", lat: p.lat, lon: p.lon,
                      type: "Стационар радар", violations: [], needsReview: false, axis: nil, dir: nil,
                      lanes: 2, cls: nil, bridge: nil, road: nil, split: nil, twin: nil)
    }

    // MARK: - A6: разворот и круг

    /// Проехали камеру, через 300 м развернулись и едем обратно мимо неё:
    /// стороны не доказаны — камера снимает и нашу, и предупредить надо снова.
    /// До 20.10 движок помнил «уже сказал» всю поездку и молчал.
    func testUTurnAfterACameraWarnsAgain() {
        let route = fixes(from: (0, 0), legs: [Leg(x: 1300, y: 0, speed: 14),
                                               Leg(x: 0, y: 0, speed: 14)])
        var drive = Drive()
        drive.run(route, cameras: [camera(1, x: 1000, y: 0)])
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
        drive.run(route, cameras: [camera(1, x: 1000, y: 0)])
        XCTAssertEqual(drive.firstAlerts[1], 2)
    }

    /// Стоим у светофора в 40 м за камерой две минуты: курса нет, она ближайшая
    /// «вокруг» — но это та же камера, о ней уже сказали. Повтора нет.
    func testStandingRightAfterACameraStaysQuiet() {
        let route = fixes(from: (0, 0), legs: [Leg(x: 1040, y: 0, speed: 14, stopSeconds: 120),
                                               Leg(x: 1600, y: 0, speed: 14)])
        var drive = Drive()
        drive.run(route, cameras: [camera(1, x: 1000, y: 0)])
        XCTAssertEqual(drive.firstAlerts[1], 1)
    }

    /// Пробка перед камерой: десять минут стоим в 150 м до неё — одно
    /// предупреждение на весь подъезд, не по разу на каждую остановку.
    func testJamBeforeACameraWarnsOnce() {
        let route = fixes(from: (0, 0), legs: [Leg(x: 850, y: 0, speed: 14, stopSeconds: 300),
                                               Leg(x: 900, y: 0, speed: 2, stopSeconds: 300),
                                               Leg(x: 1500, y: 0, speed: 12)])
        var drive = Drive()
        drive.run(route, cameras: [camera(1, x: 1000, y: 0)])
        XCTAssertEqual(drive.firstAlerts[1], 1)
    }

    /// Движок сам по себе: проеханная камера без подъезда (стоим) не
    /// сбрасывается; с подъездом — серия начинается заново.
    func testPassedCameraRestartsOnlyOnARealApproach() {
        var engine = AlertEngine()
        let cam = camera(7, x: 0, y: 0)
        XCTAssertEqual(engine.evaluate(cameraID: 7, distance: 50, radius: 400)?.level, 3)
        // Едем на восток, камера в 200 м позади.
        let behind = LocationGates.Situation(coordinate: CLLocationCoordinate2D(latitude: point(200, 0).lat,
                                                                                longitude: point(200, 0).lon),
                                             course: 90, speedKmh: 50, horizontalAccuracy: 6, context: .city)
        XCTAssertTrue(LocationGates.isClearlyBehind(cam, in: behind))
        engine.notePassed([cam], in: behind)
        XCTAssertNil(engine.evaluate(cameraID: 7, distance: 150, radius: 400, approaching: false),
                     "стоим — курса нет: та же камера, повтора нет")
        XCTAssertEqual(engine.evaluate(cameraID: 7, distance: 150, radius: 400, approaching: true)?.isFirst, true,
                       "едем к ней снова — новый подъезд")
        // Без курса «позади» не решается.
        let standing = LocationGates.Situation(coordinate: behind.coordinate, course: -1, speedKmh: 0,
                                               horizontalAccuracy: 6, context: .city)
        XCTAssertFalse(LocationGates.isClearlyBehind(cam, in: standing))
        // Шум траверза (30 м за спиной) — ещё не «проехали».
        let atTraverse = LocationGates.Situation(coordinate: CLLocationCoordinate2D(latitude: point(30, 0).lat,
                                                                                    longitude: point(30, 0).lon),
                                                 course: 90, speedKmh: 50, horizontalAccuracy: 6, context: .city)
        XCTAssertFalse(LocationGates.isClearlyBehind(cam, in: atTraverse))
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
        drive.run(route, cameras: [camera(1, x: 1400, y: 0), camera(2, x: 1950, y: 0)])
        XCTAssertEqual(drive.rejected, 0, "после тоннеля фиксы принимаются")
        XCTAssertEqual(drive.firstAlerts[2], 1, "камера за выездом звучит")
        XCTAssertLessThanOrEqual(drive.firstAlerts[1] ?? 0, 1, "проеханная в тоннеле не звучит после выезда")
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
        drive.run(route, cameras: [camera(1, x: 800, y: 300), camera(2, x: 1200, y: 0)])
        XCTAssertEqual(drive.rejected, 1)
        XCTAssertNil(drive.firstAlerts[1], "камера на соседней улице не звучит из-за выброса")
        XCTAssertEqual(drive.firstAlerts[2], 1)
    }
}
