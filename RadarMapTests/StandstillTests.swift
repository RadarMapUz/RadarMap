//
//  StandstillTests.swift
//  RadarMapTests
//
//  Стоянка: машина стоит, приёмник гуляет. На месте скорость обязана быть
//  нулём, а стрелка — неподвижной (в том числе не уходить «назад»), но
//  настоящее трогание и ползание в пробке не должны залипать.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class StandstillTests: XCTestCase {

    private let spot = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func shifted(_ meters: Double, east: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: spot.latitude + meters / 111_320,
                               longitude: spot.longitude + east / (111_320 * cos(spot.latitude * .pi / 180)))
    }

    /// Приёмник на месте: точки гуляют на 10 м, доплер 2–3 км/ч.
    private func jitter(_ s: inout Standstill, seconds: Int, from start: Int = 0) {
        for i in 0..<seconds {
            let wobble = Double((i * 7) % 11) - 5   // −5…+5 м
            s.update(shifted(wobble, east: -wobble / 2), rawKmh: 2 + Double(i % 2),
                     accuracy: 12, course: Double((i * 40) % 360), at: t0.addingTimeInterval(Double(start + i)))
        }
    }

    func testJitterOnTheSpotIsAStop() {
        var s = Standstill()
        jitter(&s, seconds: 5)
        XCTAssertTrue(s.isStopped)
        XCTAssertNotNil(s.anchor)
    }

    func testOneSlowFixIsNotYetAStop() {
        var s = Standstill()
        s.update(spot, rawKmh: 2, accuracy: 10, course: 90, at: t0)
        XCTAssertFalse(s.isStopped, "светофорное торможение до 2 км/ч на секунду — ещё не стоянка")
    }

    /// Блуждание «назад» на 12 м при точности 12 — шум, стоянка держится.
    func testBackwardDriftKeepsTheStop() {
        var s = Standstill()
        jitter(&s, seconds: 4)
        s.update(shifted(-12), rawKmh: 4, accuracy: 12, course: 270, at: t0.addingTimeInterval(5))
        XCTAssertTrue(s.isStopped)
    }

    func testDriveOffLeavesTheStopAtOnce() {
        var s = Standstill()
        jitter(&s, seconds: 4)
        s.update(shifted(3), rawKmh: 9, accuracy: 8, course: 0, at: t0.addingTimeInterval(5))
        XCTAssertTrue(s.isStopped, "один быстрый фикс может быть выбросом")
        s.update(shifted(7), rawKmh: 12, accuracy: 8, course: 0, at: t0.addingTimeInterval(6))
        XCTAssertFalse(s.isStopped, "два подряд — тронулись")
    }

    /// Ползком в пробке (4 км/ч, ниже порога скорости) — выход по смещению.
    func testCrawlingLeavesByDistance() {
        var s = Standstill()
        jitter(&s, seconds: 4)
        var left = false
        for i in 1...30 {
            s.update(shifted(Double(i) * 1.1), rawKmh: 4, accuracy: 6, course: 0,
                     at: t0.addingTimeInterval(Double(5 + i)))
            if !s.isStopped { left = true; break }
        }
        XCTAssertTrue(left, "ползание набирает смещение и выходит из стоянки")
    }

    func testAnchorKeepsTheCourseBeforeStopping() {
        var s = Standstill()
        s.update(shifted(-30), rawKmh: 30, accuracy: 5, course: 15, at: t0)
        for i in 1...4 {
            s.update(spot, rawKmh: 1, accuracy: 10, course: -1, at: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertTrue(s.isStopped)
        XCTAssertEqual(s.anchorCourse, 15, "стоя стрелка смотрит, куда ехала, а не крутится")
    }

    func testIdleDecayStops() {
        var s = Standstill()
        s.stopIfIdle(at: spot)
        XCTAssertTrue(s.isStopped)
        XCTAssertEqual(s.anchor?.latitude, spot.latitude)
    }
}
