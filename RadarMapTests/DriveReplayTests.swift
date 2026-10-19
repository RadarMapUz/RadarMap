//
//  DriveReplayTests.swift
//  RadarMapTests
//
//  Стенд проигрывания поездки: поток GPS-фиксов гоняется через НАСТОЯЩИЙ
//  конвейер — LocationFilter → LocationGates → AlertEngine.
//
//  До него девятьсот тестов проверяли чистые функции поодиночке, а конвейер
//  целиком — никто: любая регрессия в алертах ловилась только рулём. Именно
//  поэтому пять дефектов пришли от водителя (docs/plan_algorithms.md, А2).
//
//  Стенд возможен потому, что весь путь решения уже отвязан от
//  CLLocationManager: `Fix` — восемь чисел, `Situation` — пять полей.
//
//  Утверждения здесь — про ИНВАРИАНТЫ, а не про фразы: «о камере, мимо которой
//  мы проехали вплотную, предупредили», «о камере позади — нет». Фраза может
//  меняться, инвариант — нет.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class DriveReplayTests: XCTestCase {

    // MARK: - Стенд

    private struct Replay {
        var filter = LocationFilter()
        var engine = AlertEngine()
        /// Камера → сколько раз о ней предупредили.
        private(set) var alerted: [Int: Int] = [:]
        /// Камера → на сколько метров мы к ней приблизились.
        private(set) var closest: [Int: Double] = [:]
        /// Сколько фиксов отбраковал фильтр качества.
        private(set) var rejected = 0

        mutating func run(_ fixes: [LocationFilter.Fix], cameras: [Camera],
                          context: AlertPolicy.Context = .city) {
            for fix in fixes {
                guard case .accepted(let good) = filter.accept(fix, now: fix.timestamp) else {
                    rejected += 1
                    continue
                }
                let here = CLLocationCoordinate2D(latitude: good.lat, longitude: good.lon)
                let situation = LocationGates.Situation(
                    coordinate: here,
                    course: good.course,
                    speedKmh: (good.speed ?? 0) * 3.6,
                    horizontalAccuracy: good.accuracy,
                    context: context)

                // Как в приложении: гейты отбирают камеры, и решение движок
                // принимает по БЛИЖАЙШЕЙ из уцелевших, а не по каждой.
                var nearest: (camera: Camera, distance: Double)?
                for camera in cameras {
                    let distance = GeoMath.fastDistance(here.latitude, here.longitude,
                                                        camera.lat, camera.lon)
                    closest[camera.id] = min(closest[camera.id] ?? .greatestFiniteMagnitude,
                                             distance)
                    guard LocationGates.isOnOurRoad(camera, in: situation, isOnRoute: false),
                          LocationGates.isAhead(camera, in: situation) else { continue }
                    if distance < (nearest?.distance ?? .greatestFiniteMagnitude) {
                        nearest = (camera, distance)
                    }
                }
                guard let nearest else { continue }
                if engine.evaluate(cameraID: nearest.camera.id, distance: nearest.distance,
                                   radius: AppConfig.alertRadius, moving: true) != nil {
                    alerted[nearest.camera.id, default: 0] += 1
                }
            }
        }
    }

    // MARK: - Поездка

    /// Прямая на восток вдоль 41.30: шаг 20 метров, фикс раз в секунду,
    /// то есть 72 км/ч. Курс и скорость достоверные — гейты направления
    /// работают, как в живой поездке.
    private func driveEast(fromLon: Double, steps: Int) -> [LocationFilter.Fix] {
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        // 20 м по долготе на широте 41.3.
        let stepLon = 20.0 / (111_320.0 * cos(41.30 * .pi / 180))
        return (0..<steps).map { i in
            LocationFilter.Fix(lat: 41.30,
                               lon: fromLon + Double(i) * stepLon,
                               horizontalAccuracy: 8,
                               speed: 20,
                               speedAccuracy: 1,
                               course: 90,
                               courseAccuracy: 5,
                               timestamp: start.addingTimeInterval(Double(i)))
        }
    }

    private func camera(id: Int, lat: Double, lon: Double) -> Camera {
        Camera(id: id, region: "Т", city: "", location: "к",
               lat: lat, lon: lon, type: "Стационар радар",
               violations: [], needsReview: false, axis: nil, dir: nil,
               lanes: 2, cls: nil, bridge: nil, road: nil,
               split: nil, twin: nil)
    }

    // MARK: - Инварианты

    func testDrivePastCamerasHoldsTheInvariants() {
        // 3,3 км на восток от 69.200.
        let fixes = driveEast(fromLon: 69.200, steps: 165)
        let ahead = camera(id: 1, lat: 41.30, lon: 69.2250)      // прямо по курсу
        let behind = camera(id: 2, lat: 41.30, lon: 69.1980)     // позади с самого старта
        let parallel = camera(id: 3, lat: 41.3030, lon: 69.2300) // улица в 330 м севернее

        var replay = Replay()
        replay.run(fixes, cameras: [ahead, behind, parallel])

        XCTAssertEqual(replay.rejected, 0, "чистый поток фиксов не должен браковаться")

        // 1. О камере, мимо которой проехали вплотную, предупредили.
        XCTAssertLessThan(replay.closest[1] ?? .greatestFiniteMagnitude, 40)
        XCTAssertGreaterThan(replay.alerted[1] ?? 0, 0,
                             "камера на нашей дороге обязана прозвучать")

        // 2. О камере позади — ни разу. Это и есть цена ошибки в другую
        //    сторону: предупреждение о том, что уже проехали, обесценивает все
        //    остальные.
        XCTAssertNil(replay.alerted[2], "камера позади звучать не должна")

        // 3. Улица в трёхстах метрах вбок — не наша дорога.
        XCTAssertNil(replay.alerted[3], "параллельная улица звучать не должна")

        // 4. Разных камер прозвучало не больше, чем их было.
        XCTAssertLessThanOrEqual(replay.alerted.count, 3)
    }

    /// Плохой фикс не доходит до алертов: у стенда это видно целиком, а не по
    /// одной функции. Кэшированная точка со старого места когда-то
    /// регистрировалась настоящим проездом камеры на выдуманной скорости.
    func testGarbageFixNeverReachesTheAlerts() {
        // Шагов столько, чтобы камеру ПРОЕХАТЬ: сорока не хватало, машина
        // не доезжала до неё шестидесяти метров, и тест падал на своей же
        // фикстуре, а не на поведении конвейера.
        var fixes = driveEast(fromLon: 69.200, steps: 70)
        // Фикс с отрицательной погрешностью — система сама говорит «не верь».
        fixes.insert(LocationFilter.Fix(lat: 41.50, lon: 69.60,
                                        horizontalAccuracy: -1,
                                        speed: 20, speedAccuracy: 1,
                                        course: 90, courseAccuracy: 5,
                                        timestamp: fixes[10].timestamp),
                     at: 10)
        var replay = Replay()
        replay.run(fixes, cameras: [camera(id: 1, lat: 41.30, lon: 69.2100)])

        XCTAssertEqual(replay.rejected, 1, "негодный фикс обязан быть отброшен")
        // И он не сдвинул наше представление о том, где мы: до камеры мы всё
        // равно доехали вплотную.
        XCTAssertLessThan(replay.closest[1] ?? .greatestFiniteMagnitude, 40)
    }
}
