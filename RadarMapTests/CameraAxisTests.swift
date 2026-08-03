//
//  CameraAxisTests.swift
//  RadarMapTests
//
//  Ось дороги камеры против курса: мост над камерой (движение поперёк оси)
//  не должен ни алертить, ни попадать в статистику. Живой гейт — чистая
//  математика GeoMath.axisDifference; ретро-чистка — TripHistory.axisSanitized.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class CameraAxisTests: XCTestCase {

    // MARK: - Математика оси

    func testAxisDifferenceCourseAlongAxis() {
        // Дорога север-юг (ось 0): курс на север и на юг — оба «вдоль».
        XCTAssertEqual(GeoMath.axisDifference(course: 0, axis: 0), 0, accuracy: 0.001)
        XCTAssertEqual(GeoMath.axisDifference(course: 180, axis: 0), 0, accuracy: 0.001)
        XCTAssertEqual(GeoMath.axisDifference(course: 355, axis: 0), 5, accuracy: 0.001)
    }

    /// Сценарий моста: камера на проспекте (ось ~170°), мы едем по кольцевой
    /// поперёк (~85°) — расхождение ~85°, гейт (55°) отбрасывает.
    func testBridgeCrossingIsBeyondGate() {
        let diff = GeoMath.axisDifference(course: 85, axis: 170)
        XCTAssertEqual(diff, 85, accuracy: 0.001)
        XCTAssertGreaterThan(diff, AppConfig.cameraAxisMaxAngle)
    }

    func testCurvedApproachStaysWithinGate() {
        // Подъезд по дуге: курс до 50° от оси — ещё своя дорога.
        XCTAssertLessThanOrEqual(GeoMath.axisDifference(course: 48, axis: 0),
                                 AppConfig.cameraAxisMaxAngle)
    }

    func testAxisDifferenceIsSymmetricAroundFold() {
        // 270° (запад) для оси 90° (восток-запад) — вдоль, не поперёк.
        XCTAssertEqual(GeoMath.axisDifference(course: 270, axis: 90), 0, accuracy: 0.001)
        XCTAssertEqual(GeoMath.axisDifference(course: 90, axis: 0), 90, accuracy: 0.001)
    }

    // MARK: - Декодирование камеры с осью

    func testCameraDecodesAxisAndToleratesAbsence() throws {
        let with = try JSONDecoder().decode(Camera.self, from: Data("""
        {"id":1,"region":"Т","city":"","location":"м","lat":41.3,"lon":69.2,
         "type":"Стационар радар","axis":97}
        """.utf8))
        XCTAssertEqual(with.axis, 97)
        let without = try JSONDecoder().decode(Camera.self, from: Data("""
        {"id":2,"region":"Т","city":"","location":"м","lat":41.3,"lon":69.2,
         "type":"Стационар радар"}
        """.utf8))
        XCTAssertNil(without.axis, "старые базы без осей должны читаться")
    }

    // MARK: - Ретро-чистка «мостовых» проездов

    /// Трек с запада на восток (курс 90°), камера дороги север-юг (ось 0) прямо
    /// на пути — классический мост. Проезд должен вылететь, балл пересчитаться.
    func testAxisSanitizedDropsBridgePassAndRecomputesScore() {
        let base = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
        var track: [Double] = []
        for step in 0...10 {
            let p = GeoMath.destination(from: base, bearing: 90,
                                        distanceMeters: Double(step) * 100)
            track += [p.latitude, p.longitude, 80]
        }
        let mid = GeoMath.destination(from: base, bearing: 90, distanceMeters: 500)
        let bridgePass = PassedCamera(id: UUID(), cameraID: 501,
                                      typeRaw: "Стационар радар", location: "мост",
                                      speedKmh: 83, date: Date(timeIntervalSince1970: 1e9),
                                      lat: mid.latitude, lon: mid.longitude, limitKmh: 60)
        let start = Date(timeIntervalSince1970: 1e9 - 600)
        let record = TripRecord(id: 1, startedAt: start,
                                endedAt: start.addingTimeInterval(1200),
                                distanceMeters: 1000, maxSpeedKmh: 85,
                                passed: [bridgePass], track: track, score: 60)

        let (cleaned, changed) = TripHistory.axisSanitized([record], axisByID: [501: 0])
        XCTAssertTrue(changed)
        XCTAssertTrue(cleaned[0].passed.isEmpty, "мостовой «проезд» должен вылететь")
        XCTAssertNotNil(cleaned[0].score)
        XCTAssertGreaterThan(cleaned[0].score ?? 0, 60,
                             "без ложного превышения балл обязан вырасти")
    }

    func testAxisSanitizedKeepsAlongAxisPass() {
        let base = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
        var track: [Double] = []
        for step in 0...10 {
            let p = GeoMath.destination(from: base, bearing: 90,
                                        distanceMeters: Double(step) * 100)
            track += [p.latitude, p.longitude, 55]
        }
        let mid = GeoMath.destination(from: base, bearing: 90, distanceMeters: 500)
        let ourPass = PassedCamera(id: UUID(), cameraID: 502,
                                   typeRaw: "Стационар радар", location: "наша",
                                   speedKmh: 55, date: Date(timeIntervalSince1970: 1e9),
                                   lat: mid.latitude, lon: mid.longitude, limitKmh: 60)
        let start = Date(timeIntervalSince1970: 1e9 - 600)
        let record = TripRecord(id: 2, startedAt: start,
                                endedAt: start.addingTimeInterval(1200),
                                distanceMeters: 1000, maxSpeedKmh: 60,
                                passed: [ourPass], track: track, score: 95)

        // Ось дороги камеры 90° — как и трек: проезд свой, ничего не меняется.
        let (cleaned, changed) = TripHistory.axisSanitized([record], axisByID: [502: 90])
        XCTAssertFalse(changed)
        XCTAssertEqual(cleaned[0].passed.count, 1)
    }

    func testAxisSanitizedSkipsUnknownAxes() {
        let pass = PassedCamera(id: UUID(), cameraID: 503, typeRaw: "Стационар радар",
                                location: "без оси", speedKmh: 70,
                                date: Date(timeIntervalSince1970: 1e9),
                                lat: 41.3110, lon: 69.2790, limitKmh: 60)
        let start = Date(timeIntervalSince1970: 1e9 - 600)
        let record = TripRecord(id: 3, startedAt: start,
                                endedAt: start.addingTimeInterval(600),
                                distanceMeters: 800, maxSpeedKmh: 75,
                                passed: [pass],
                                track: [41.3110, 69.2790, 70, 41.3120, 69.2790, 70])
        let (cleaned, changed) = TripHistory.axisSanitized([record], axisByID: [:])
        XCTAssertFalse(changed, "камера без оси — не судим")
        XCTAssertEqual(cleaned[0].passed.count, 1)
    }
}
