//
//  ParkedCarTests.swift
//  RadarMapTests
//
//  «Где машина» (12б.1): паркует только точный конец поездки за рулём,
//  показ — отойдя и выждав, сброс — вернувшись к машине или через трое суток.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class ParkedCarTests: XCTestCase {
    private let car = CLLocationCoordinate2D(latitude: 41.3111, longitude: 69.2797)
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Точка в `meters` к северу от машины.
    private func north(_ meters: Double) -> CLLocationCoordinate2D {
        GeoMath.destination(from: car, bearing: 0, distanceMeters: meters)
    }

    private func fix(accuracy: Double) -> ParkedCar.Fix {
        ParkedCar.Fix(lat: car.latitude, lon: car.longitude, accuracy: accuracy)
    }

    private func parked() -> ParkedCar {
        ParkedCar.park(lastDriven: fix(accuracy: 8), asPassenger: false, now: t0)!
    }

    func testOnlyPreciseDriverEndParks() {
        XCTAssertNotNil(ParkedCar.park(lastDriven: fix(accuracy: 30), asPassenger: false, now: t0))
        XCTAssertNil(ParkedCar.park(lastDriven: fix(accuracy: 31), asPassenger: false, now: t0),
                     "плохая точность не паркует")
        XCTAssertNil(ParkedCar.park(lastDriven: fix(accuracy: 8), asPassenger: true, now: t0),
                     "пассажир машину не ставил")
        XCTAssertNil(ParkedCar.park(lastDriven: nil, asPassenger: false, now: t0),
                     "в поездке ни разу не ехали — машины нет")
        XCTAssertNil(ParkedCar.park(lastDriven: fix(accuracy: -1), asPassenger: false, now: t0),
                     "неизвестная точность — не точная")
    }

    func testWalkingIsNotDriving() {
        XCTAssertFalse(ParkedCar.isDriving(speedKmh: 6), "пешком от машины — не точка машины")
        XCTAssertFalse(ParkedCar.isDriving(speedKmh: 11), "бег — тоже")
        XCTAssertTrue(ParkedCar.isDriving(speedKmh: 15))
    }

    func testShownOnlyAwayAndAfterWait() {
        var spot = parked()
        XCTAssertEqual(spot.update(here: north(20), now: t0.addingTimeInterval(600)), .hidden(recheckIn: nil),
                       "у машины — не показываем")
        let early = spot.update(here: north(400), now: t0.addingTimeInterval(60))
        XCTAssertEqual(early, .hidden(recheckIn: 60), "отошли, но двух минут нет — перепроверить через минуту")
        guard case .shown(let meters, let bearing) = spot.update(here: north(400), now: t0.addingTimeInterval(130)) else {
            return XCTFail("отошли и выждали — показываем")
        }
        XCTAssertEqual(meters, 400, accuracy: 3)
        XCTAssertEqual(bearing, 180, accuracy: 1, "машина к югу от нас")
        XCTAssertEqual(spot.update(here: north(100), now: t0.addingTimeInterval(200)), .hidden(recheckIn: nil),
                       "ближе 150 м — машину видно глазами")
    }

    func testReturnToCarExpiresOnlyAfterLeaving() {
        var spot = parked()
        XCTAssertNotEqual(spot.update(here: north(10), now: t0.addingTimeInterval(300)), .expired,
                          "сразу после парковки человек стоит рядом — это не возвращение")
        XCTAssertFalse(spot.hasLeft)
        _ = spot.update(here: north(300), now: t0.addingTimeInterval(400))
        XCTAssertTrue(spot.hasLeft)
        XCTAssertEqual(spot.update(here: north(25), now: t0.addingTimeInterval(1800)), .expired,
                       "вернулись к машине — точку забыть")
    }

    func testExpiresAfterThreeDays() {
        var spot = parked()
        XCTAssertEqual(spot.update(here: nil, now: t0.addingTimeInterval(3 * 24 * 3600)), .expired)
        var fresh = parked()
        XCTAssertEqual(fresh.update(here: nil, now: t0.addingTimeInterval(3600)), .hidden(recheckIn: nil),
                       "без позиции — молчим, но точку храним")
    }

    func testHintStepsAndArrow() {
        XCTAssertEqual(ParkedCar.Hint(meters: 347, bearing: 93).meters, 350)
        XCTAssertEqual(ParkedCar.Hint(meters: 1_249, bearing: 93).meters, 1_200)
        XCTAssertEqual(ParkedCar.Hint(meters: 347, bearing: 93).bearing, 90)
        XCTAssertEqual(ParkedCar.Hint(meters: 347, bearing: 357).bearing, 0, "360 — это север")
        XCTAssertEqual(ParkedCar.arrowRotation(bearing: 90, mapDirection: 0), 90)
        XCTAssertEqual(ParkedCar.arrowRotation(bearing: 10, mapDirection: 40), 330,
                       "карта повёрнута — стрелка туда же, где метка машины")
    }

    func testSurvivesStorageRoundTrip() throws {
        var spot = parked()
        _ = spot.update(here: north(500), now: t0.addingTimeInterval(200))
        let data = try JSONEncoder().encode(spot)
        XCTAssertEqual(try JSONDecoder().decode(ParkedCar.self, from: data), spot)
    }
}
