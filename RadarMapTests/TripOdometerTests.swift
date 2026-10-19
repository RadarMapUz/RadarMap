//
//  TripOdometerTests.swift
//  RadarMapTests
//
//  Пробег (S13, 20.10): час в пробке на месте — не километр, туннель — не
//  ноль, перелёт приёмника — не путь.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class TripOdometerTests: XCTestCase {
    private let lat = 41.30, lon = 69.20
    private var k: Double { 111_320 * cos(lat * .pi / 180) }
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func point(east: Double, north: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat + north / 111_320, longitude: lon + east / k)
    }

    /// Час стоянки, фикс в секунду, приёмник гуляет ±15 м: ноль метров; потом
    /// тронулись на 40 м — засчитаны 40 от точки остановки, а не от шума.
    func testJitterAtAStopIsNotDistance() {
        var odometer = TripOdometer()
        var total = odometer.advance(to: point(east: 0), at: t0, stopped: false)
        var generator = SystemRandomNumberGenerator()
        for i in 1...3600 {
            let jitter = point(east: Double.random(in: -15...15, using: &generator),
                               north: Double.random(in: -15...15, using: &generator))
            total += odometer.advance(to: jitter, at: t0.addingTimeInterval(Double(i)), stopped: true)
        }
        XCTAssertEqual(total, 0)
        total += odometer.advance(to: point(east: 40), at: t0.addingTimeInterval(3601), stopped: false)
        XCTAssertEqual(total, 40, accuracy: 0.5)
    }

    /// Старое правило на том же шуме: каждый шаг < 500 м шёл в пробег.
    func testOldRuleWouldCountKilometres() {
        var total = 0.0
        var last = point(east: 0)
        for i in 1...3600 {
            let next = point(east: i % 2 == 0 ? 8 : -8)
            total += GeoMath.fastDistance(last.latitude, last.longitude, next.latitude, next.longitude)
            last = next
        }
        XCTAssertGreaterThan(total, 50_000, "шум на месте давал десятки километров — поэтому и опора")
    }

    /// Туннель 1,2 км за 70 с: хордой в пробег; перелёт на 5 км за 10 с — нет.
    func testGapCountsAndJumpDoesNot() {
        var odometer = TripOdometer(anchor: point(east: 0), at: t0)
        XCTAssertEqual(odometer.advance(to: point(east: 1200), at: t0.addingTimeInterval(70), stopped: false),
                       1200, accuracy: 1)
        XCTAssertEqual(odometer.advance(to: point(east: 6200), at: t0.addingTimeInterval(80), stopped: false), 0)
        XCTAssertEqual(odometer.advance(to: point(east: 6230), at: t0.addingTimeInterval(81), stopped: false),
                       30, accuracy: 0.5, "после перелёта — от новой точки")
    }

    /// Склейка: опора — финиш прошлой ноги и её время; поздний автостарт в
    /// 800 м после 20 минут в магазине — путь, а не ноль.
    func testLateAutostartAfterAStopCountsTheWay() {
        var odometer = TripOdometer(anchor: point(east: 0), at: t0)
        XCTAssertEqual(odometer.advance(to: point(east: 800), at: t0.addingTimeInterval(1200), stopped: false),
                       800, accuracy: 1)
    }

    func testNoTimeKeepsTheOldRuleForLongSteps() {
        XCTAssertEqual(TripOdometer.counted(600, seconds: nil, stopped: false), 0)
        XCTAssertEqual(TripOdometer.counted(100, seconds: nil, stopped: false), 100)
        XCTAssertNil(TripOdometer.counted(100, seconds: 1, stopped: true))
    }
}
