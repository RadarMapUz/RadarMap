//
//  PassAfterZoneTests.swift
//  RadarMapTests
//
//  Что проезд уносит с собой кроме скорости: пол фиксации, сырой лимит дороги,
//  курс на траверзе и разгон ПОСЛЕ камеры. Последние два — материал для
//  CameraAim, и собираются они здесь, на живом конвейере.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class PassAfterZoneTests: XCTestCase {

    private let lat = 41.30
    private let cameraLon = 69.21

    private var camera: Camera {
        Camera(id: 1, region: "", city: "", location: "тест", lat: lat, lon: cameraLon,
               type: "Стационар радар", violations: [], needsReview: nil)
    }

    /// Один проезд на восток: торможение к камере, разгон после неё.
    private func drive(roadLimit: Int?) -> [PassTracking.Pass] {
        var tracking = PassTracking()
        let cam = camera
        func tick(_ lon: Double, _ speed: Double) -> [PassTracking.Pass] {
            let distance = GeoMath.fastDistance(lat, lon, cam.lat, cam.lon)
            return tracking.update(
                nearest: cam, nearestDistance: distance,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                speedKmh: speed, roadLimit: roadLimit, radius: 500, course: 90)
        }
        XCTAssertTrue(tick(69.2050, 70).isEmpty)   // ~418 м — вошли в радиус
        XCTAssertTrue(tick(69.2095, 62).isEmpty)   // ~42 м — зона измерения
        XCTAssertTrue(tick(69.2100, 57).isEmpty)   // траверз
        XCTAssertTrue(tick(69.2111, 75).isEmpty)   // ~92 м после — зона отхода
        XCTAssertTrue(tick(69.2118, 85).isEmpty)   // ~150 м после — разгон
        return tick(69.2180, 90)                   // ушли за радиус + гистерезис
    }

    /// Время проезда — момент наибольшего сближения, а не момент, когда
    /// камеру отпустили за радиусом: по нему кадры видео ставятся на карту.
    func testPassTimeIsTheTraverseNotTheRelease() {
        var tracking = PassTracking()
        let cam = camera
        let t0 = Date(timeIntervalSince1970: 1_791_350_400)
        var result: [PassTracking.Pass] = []
        for (i, (lon, speed)) in [(69.2050, 70.0), (69.2095, 62), (69.2100, 57), (69.2111, 75),
                                  (69.2118, 85), (69.2180, 90)].enumerated() {
            let distance = GeoMath.fastDistance(lat, lon, cam.lat, cam.lon)
            result += tracking.update(
                nearest: cam, nearestDistance: distance,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                speedKmh: speed, roadLimit: 60, radius: 500, course: 90,
                now: t0.addingTimeInterval(Double(i) * 10))
        }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].date, t0.addingTimeInterval(20), "траверз — третий тик, не последний")
    }

    /// Разгон после камеры не портит записанную скорость (её берут минимумом
    /// зоны), но сам записывается — без него направление камеры не вывести.
    func testAfterZoneSpeedIsRecordedWithoutSpoilingTheMeasurement() {
        let passes = drive(roadLimit: 60)
        XCTAssertEqual(passes.count, 1)
        XCTAssertEqual(passes[0].speedKmh, 57)
        XCTAssertEqual(passes[0].speedAfterKmh, 85)
        XCTAssertEqual(passes[0].courseDegrees, 90)
    }

    /// Пол фиксации применяется РОВНО здесь — один раз, при записи проезда.
    /// Сырой лимит дороги едет рядом: экран проезда обязан уметь назвать знак.
    func testFloorIsAppliedOnceAtRecording() {
        let passes = drive(roadLimit: 50)
        XCTAssertEqual(passes.count, 1)
        XCTAssertEqual(passes[0].limitKmh, 60)
        XCTAssertEqual(passes[0].roadLimitKmh, 50)
        // 57 км/ч по улице с тегом 50 переставало быть нарушением.
        XCTAssertEqual(FineSchedule.fine(overKmh: 57 - Double(passes[0].limitKmh ?? 0)), 0)
    }

    /// Лимита не было — пол его не выдумывает.
    func testNoLimitStaysNoLimit() {
        let passes = drive(roadLimit: nil)
        XCTAssertEqual(passes.count, 1)
        XCTAssertNil(passes[0].limitKmh)
        XCTAssertNil(passes[0].roadLimitKmh)
    }

    /// Курсу нельзя верить (LocationFilter отдал -1) — направление проезда
    /// честно остаётся неизвестным, а не записывается нулём, то есть «север».
    func testUntrustedCourseIsNotRecordedAsNorth() {
        var tracking = PassTracking()
        let cam = camera
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: cameraLon)
        _ = tracking.update(nearest: cam, nearestDistance: 8, coordinate: coordinate,
                            speedKmh: 55, roadLimit: 60, radius: 500, course: -1)
        let passes = tracking.flush()
        XCTAssertEqual(passes.count, 1)
        XCTAssertNil(passes[0].courseDegrees)
    }

    /// Фиксов на отходе не было (поездка кончилась у камеры) — поле пустое,
    /// и CameraAim такой проезд просто не возьмёт.
    func testWithoutAfterFixesTheFieldStaysEmpty() {
        var tracking = PassTracking()
        let cam = camera
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: cameraLon)
        _ = tracking.update(nearest: cam, nearestDistance: 8, coordinate: coordinate,
                            speedKmh: 55, roadLimit: 60, radius: 500, course: 90)
        let passes = tracking.flush()
        XCTAssertNil(passes[0].speedAfterKmh)
    }

    /// Провал скорости считается от записанного проезда: 85 после против 57 у
    /// камеры — двадцать восемь километров в час, заметно выше порога догадки.
    func testBrakeDepthIsReadableFromTheRecord() {
        var pass = PassedCamera(id: UUID(), cameraID: 1, typeRaw: "Стационар радар",
                                location: "", speedKmh: 57, date: Date())
        pass.speedAfterKmh = 85
        XCTAssertEqual(pass.brakeDepthKmh, 28)
        XCTAssertGreaterThan(pass.brakeDepthKmh ?? 0, AppConfig.aimMinBrakeKmh)
    }
}
