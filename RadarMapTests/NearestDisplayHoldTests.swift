//
//  NearestDisplayHoldTests.swift
//  RadarMapTests
//
//  Ближайшая камера для показа на пороге гейтов 10 км/ч (план 25.I).
//
//  Пробка: скорость ходит 5 ↔ 12 км/ч, впереди на нашей дороге камера A в
//  300 м, сбоку на параллельной улице — камера B в 140 м. Ниже порога гейты
//  выключены, и камерой ПРЕДУПРЕЖДЕНИЯ становится ближайшая любая (B), выше —
//  снова A. Это правило асимметрии, и оно не меняется; показ же (HUD, док,
//  часы, Live Activity) мигать между ними не должен.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class NearestDisplayHoldTests: XCTestCase {

    private let start = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Камера в `ahead` к северу и `east` к востоку от старта, с куском
    /// дороги вдоль `roadBearing` через её точку (как в LocationGatesTests).
    private func camera(id: Int, ahead: Double, east: Double = 0,
                        roadBearing: Double = 0) -> Camera {
        var at = GeoMath.destination(from: start, bearing: 0, distanceMeters: ahead)
        at = GeoMath.destination(from: at, bearing: 90, distanceMeters: east)
        var deltas: [Int] = []
        for step in [-100.0, 0, 100] {
            let p = GeoMath.destination(from: at, bearing: roadBearing, distanceMeters: step)
            deltas.append(Int(((p.latitude - at.latitude) * 1e6).rounded()))
            deltas.append(Int(((p.longitude - at.longitude) * 1e6).rounded()))
        }
        return Camera(id: id, region: "Т", city: "", location: "к\(id)",
                      lat: at.latitude, lon: at.longitude, type: "Стационар радар",
                      violations: [], needsReview: false, axis: nil, dir: nil,
                      lanes: 2, cls: "primary", road: deltas, split: nil, twin: nil)
    }

    /// Наша камера впереди и боковая на параллельной улице.
    private lazy var ours = camera(id: 1, ahead: 300)
    private lazy var side = camera(id: 2, ahead: 20, east: 140)

    /// Один тик: точка, курс, скорость, время.
    private struct Tick {
        let coordinate: CLLocationCoordinate2D
        let course: Double
        let speed: Double
        let at: Date
    }

    private func situation(_ tick: Tick) -> LocationGates.Situation {
        LocationGates.Situation(coordinate: tick.coordinate, course: tick.course,
                                speedKmh: tick.speed, horizontalAccuracy: 5, context: .city)
    }

    /// Кандидаты, как их собирает `recomputeNearest` без маршрута: по прямой,
    /// по возрастанию расстояния.
    private func candidates(_ cameras: [Camera], at point: CLLocationCoordinate2D)
        -> [LocationGates.Candidate] {
        cameras.map { camera -> LocationGates.Candidate in
            (camera, GeoMath.fastDistance(point.latitude, point.longitude, camera.lat, camera.lon), false)
        }
        .sorted { $0.distance < $1.distance }
    }

    /// Пробка на север: каждые `period` секунд скорость меняется 12 ↔ 5,
    /// фикс раз в секунду; курс доверенный или (`courseWhenSlow` = −1) теряется
    /// ниже порога.
    private func jam(seconds: Int, period: Int = 2, from point: CLLocationCoordinate2D? = nil,
                     startAt: Date? = nil, courseWhenSlow: Double = 0) -> [Tick] {
        var here = point ?? start
        let begin = startAt ?? t0
        var ticks: [Tick] = []
        for s in 0..<seconds {
            let fast = (s / period) % 2 == 0
            let speed = fast ? 12.0 : 5.0
            ticks.append(Tick(coordinate: here, course: fast ? 0 : courseWhenSlow, speed: speed,
                              at: begin.addingTimeInterval(Double(s))))
            here = GeoMath.destination(from: here, bearing: 0, distanceMeters: speed / 3.6)
        }
        return ticks
    }

    /// Выбор на каждом тике: камера предупреждения и камера показа.
    private struct Picked: Equatable {
        let alert: Int?
        let alertDistance: Double?
        let shown: Int?
    }

    private func run(_ ticks: [Tick], cameras: [Camera],
                     hold: inout NearestDisplayHold) -> [Picked] {
        ticks.map { tick in
            let list = candidates(cameras, at: tick.coordinate)
            let situation = situation(tick)
            let alert = LocationGates.nearestOursIndex(list, in: situation)
            guard let alert else {
                hold = NearestDisplayHold()   // как clearNearest
                return Picked(alert: nil, alertDistance: nil, shown: nil)
            }
            let shown = hold.update(candidates: list, alertIndex: alert,
                                    situation: situation, now: tick.at) ?? alert
            return Picked(alert: list[alert].camera.id, alertDistance: list[alert].distance,
                          shown: list[shown].camera.id)
        }
    }

    // MARK: - Пробка

    /// Пробка 5 ↔ 12 км/ч у нашей камеры впереди: предупреждение по-прежнему
    /// переключается на ближайшую любую (неизвестность — в пользу камеры), а
    /// показ весь подъезд — на нашей.
    func testJamDoesNotFlickerDisplay() {
        var hold = NearestDisplayHold()
        let picked = run(jam(seconds: 40), cameras: [ours, side], hold: &hold)
        XCTAssertEqual(Set(picked.map(\.shown)), [ours.id], "показ мигал: \(picked.map(\.shown))")
        // Предупреждение не тронуто: ниже порога — боковая, как и до 25.I.
        XCTAssertTrue(picked.contains { $0.alert == side.id })
        XCTAssertTrue(picked.contains { $0.alert == ours.id })
    }

    /// То же, когда стоя теряется и курс: держит последний доверенный.
    func testJamWithoutCourseWhenSlow() {
        var hold = NearestDisplayHold()
        let picked = run(jam(seconds: 40, courseWhenSlow: -1), cameras: [ours, side], hold: &hold)
        XCTAssertEqual(Set(picked.map(\.shown)), [ours.id])
    }

    /// Гистерезис порога 10/6 мигал бы на 5 км/ч; удержанию всё равно, как
    /// глубоко провалилась скорость, — и ползком 1–3 км/ч тоже.
    func testCrawlNearZeroStillHolds() {
        var hold = NearestDisplayHold()
        var ticks = jam(seconds: 4)
        let last = ticks.last!
        for s in 1...20 {
            ticks.append(Tick(coordinate: last.coordinate, course: -1, speed: Double(s % 3),
                              at: last.at.addingTimeInterval(Double(s))))
        }
        let picked = run(ticks, cameras: [ours, side], hold: &hold)
        XCTAssertEqual(Set(picked.map(\.shown)), [ours.id])
    }

    // MARK: - Когда отпускать

    /// Настоящий поворот на боковую улицу: курс доверенный и другой — показ
    /// переключается на первом же медленном тике после поворота.
    func testRealTurnSwitchesDisplay() {
        var hold = NearestDisplayHold()
        var ticks = jam(seconds: 6)
        let last = ticks.last!
        var here = last.coordinate
        for s in 1...5 {
            here = GeoMath.destination(from: here, bearing: 90, distanceMeters: 5 / 3.6)
            ticks.append(Tick(coordinate: here, course: 90, speed: 5,
                              at: last.at.addingTimeInterval(Double(s))))
        }
        let picked = run(ticks, cameras: [ours, side], hold: &hold)
        let afterTurn = picked.suffix(5)
        XCTAssertTrue(afterTurn.allSatisfy { $0.shown == $0.alert },
                      "после поворота показ = предупреждение: \(afterTurn)")
        XCTAssertEqual(afterTurn.first?.shown, side.id)
        // Отпущенное не возвращается до тика с гейтами (не мигает на границе).
        XCTAssertNil(hold.anchor)
    }

    /// Стоим давно — прежнее поведение: после `nearestDisplayHoldSeconds`
    /// показ — ближайшая любая («136 м сбоку», 12.10).
    func testLongStandstillFallsBack() {
        var hold = NearestDisplayHold()
        var ticks = jam(seconds: 3)   // 12, 12, 5 — последний тик с гейтами на 1 с
        let lastFiltered = ticks[1].at
        let here = ticks.last!.coordinate
        let limit = Int(AppConfig.nearestDisplayHoldSeconds)
        for s in [10, limit - 1, limit + 1, limit + 30] {
            ticks.append(Tick(coordinate: here, course: -1, speed: 0,
                              at: lastFiltered.addingTimeInterval(Double(s))))
        }
        let picked = run(ticks, cameras: [ours, side], hold: &hold)
        XCTAssertEqual(picked[3].shown, ours.id, "10 с стоим — держим")
        XCTAssertEqual(picked[4].shown, ours.id, "почти минута — держим")
        XCTAssertEqual(picked[5].shown, side.id, "дольше — прежнее поведение")
        XCTAssertEqual(picked[6].shown, side.id)
        // Предупреждение всю стоянку — ближайшая любая, как и до 25.I.
        XCTAssertEqual(picked[3...].map(\.alert), [side.id, side.id, side.id, side.id])
    }

    /// Проехали удержанную камеру ползком — она позади, держать нечего.
    func testPassedHeldCameraIsReleased() {
        var hold = NearestDisplayHold()
        let near = camera(id: 3, ahead: 15)
        var ticks = jam(seconds: 2)   // 12 км/ч, камера в 15 м впереди
        var here = ticks.last!.coordinate
        for s in 1...40 {
            here = GeoMath.destination(from: here, bearing: 0, distanceMeters: 5 / 3.6)
            ticks.append(Tick(coordinate: here, course: 0, speed: 5,
                              at: ticks[1].at.addingTimeInterval(Double(s))))
        }
        let picked = run(ticks, cameras: [near, side], hold: &hold)
        XCTAssertEqual(picked[1].shown, near.id)
        // ~59 м проехали: камера в 44 м позади, дальше допуска «на траверзе»
        // (30 м) — держать нечего, показ = предупреждение.
        XCTAssertEqual(picked.last?.shown, picked.last?.alert)
        XCTAssertNil(hold.anchor)
    }

    /// Камера дальше `nearestDisplayHoldMaxMeters` не держится.
    func testFarCameraIsNotHeld() {
        var hold = NearestDisplayHold()
        let far = camera(id: 4, ahead: AppConfig.nearestDisplayHoldMaxMeters + 200)
        let picked = run(jam(seconds: 6), cameras: [far, side], hold: &hold)
        XCTAssertEqual(picked[0].shown, far.id)
        XCTAssertEqual(picked[2].shown, side.id, "ниже порога — как раньше")
    }

    /// Быстро, но курса нет (туннель) — не порог скорости, не мостим.
    func testFastWithoutCourseIsNotBridged() {
        var hold = NearestDisplayHold()
        var ticks = jam(seconds: 1)
        ticks.append(Tick(coordinate: ticks[0].coordinate, course: -1, speed: 40,
                          at: t0.addingTimeInterval(1)))
        let picked = run(ticks, cameras: [ours, side], hold: &hold)
        XCTAssertEqual(picked[1].shown, picked[1].alert)
        XCTAssertNil(hold.anchor)
    }

    // MARK: - Тест-сверка: предупреждения не изменились

    /// Прежний выбор `recomputeNearest` (до 25.I), строка в строку.
    private func legacyAlertIndex(_ list: [LocationGates.Candidate],
                                  _ situation: LocationGates.Situation) -> Int? {
        list.firstIndex(where: {
            LocationGates.isOnOurRoad($0.camera, in: situation, isOnRoute: $0.onRoute)
        })
    }

    /// На тех же входах камера и расстояние ПРЕДУПРЕЖДЕНИЯ, решения движка
    /// тревоги, уровень и «подъезд» — те же, что до правки. Сценарии — все
    /// выше вместе: пробка, ползком, поворот, долгая стоянка, проезд.
    func testAlertsUnchangedOnSameInputs() {
        var ticks = jam(seconds: 40)
        let last = ticks.last!
        var here = last.coordinate
        for s in 1...90 {   // поворот на восток ползком, потом долго стоим
            if s <= 10 { here = GeoMath.destination(from: here, bearing: 90, distanceMeters: 5 / 3.6) }
            ticks.append(Tick(coordinate: here, course: s <= 10 ? 90 : -1, speed: s <= 10 ? 5 : 0,
                              at: last.at.addingTimeInterval(Double(s))))
        }
        ticks += jam(seconds: 120, period: 3, from: here, startAt: ticks.last!.at.addingTimeInterval(1))
        let cameras = [ours, side, camera(id: 5, ahead: 600), camera(id: 6, ahead: 250, east: -120)]

        var hold = NearestDisplayHold()
        var engineNew = AlertEngine()
        var engineOld = AlertEngine()
        var held = 0
        for tick in ticks {
            let list = candidates(cameras, at: tick.coordinate)
            let situation = situation(tick)
            let old = legacyAlertIndex(list, situation)
            let new = LocationGates.nearestOursIndex(list, in: situation)
            XCTAssertEqual(old, new)
            guard let new else { hold = NearestDisplayHold(); continue }
            // Показ считается МЕЖДУ выбором и тревогой — как в recomputeNearest.
            let shown = hold.update(candidates: list, alertIndex: new, situation: situation, now: tick.at)
            if shown != nil { held += 1 }
            let radius = AlertEngine.effectiveRadius(speedKmh: tick.speed, baseRadius: AppConfig.alertRadius)
            let moving = LocationGates.isFilteringActive(situation)
            let a = list[new], b = list[old!]
            XCTAssertEqual(a.camera.id, b.camera.id)
            XCTAssertEqual(a.distance, b.distance)
            XCTAssertEqual(engineNew.evaluate(cameraID: a.camera.id, distance: a.distance,
                                              radius: radius, moving: moving),
                           engineOld.evaluate(cameraID: b.camera.id, distance: b.distance,
                                              radius: radius, moving: moving))
            XCTAssertEqual(LocationService.alertLevel(distance: a.distance, radius: radius, tripActive: true),
                           LocationService.alertLevel(distance: b.distance, radius: radius, tripActive: true))
            let approaching = LocationService.isApproaching(distance: a.distance, speedKmh: tick.speed,
                                                            radius: radius, signalStale: false)
            // Полноэкранное предупреждение и баннер машины читают камеру
            // предупреждения; удержание включается только ниже порога, где
            // подъезда нет, — показ с ними не расходится.
            if approaching { XCTAssertNil(shown) }
        }
        XCTAssertGreaterThan(held, 0, "сценарий должен задеть удержание")
    }
}
