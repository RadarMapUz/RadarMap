//
//  LaneOffsetTests.swift
//  RadarMapTests
//
//  Машина в своей полосе.
//
//  Самое заметное, чем чужая схема отличается от нашей: машина стоит в полосе,
//  а не на осевой. Данные для этого у нас есть — разница между точкой GPS и её
//  проекцией на ось.
//
//  Но именно здесь легче всего соврать, поэтому сторожатся ОТКАЗЫ: три случая,
//  в которых «своя полоса» перестаёт быть фактом и машина обязана вернуться на
//  ось.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class LaneOffsetTests: XCTestCase {

    private let axis = CLLocationCoordinate2D(latitude: 41.311, longitude: 69.279)

    /// Точка в `metres` вправо от оси при курсе `course`.
    private func beside(_ metres: Double, course: Double) -> CLLocationCoordinate2D {
        let heading = course * .pi / 180
        let east = metres * cos(heading)
        let north = -metres * sin(heading)
        let metresPerLon = 111_320.0 * cos(axis.latitude * .pi / 180)
        return CLLocationCoordinate2D(
            latitude: axis.latitude + north / 111_320.0,
            longitude: axis.longitude + east / metresPerLon)
    }

    private func offset(_ metres: Double, course: Double = 0,
                        width: Double = 14, measured: Bool = true,
                        accuracy: Double = 2) -> Double? {
        RoadSketch.laneOffset(me: beside(metres, course: course), onAxis: axis,
                              courseDegrees: course, roadWidthMeters: width,
                              lanesMeasured: measured, accuracyMeters: accuracy)
    }

    // MARK: - Геометрия

    func testRightOfAxisIsPositive() {
        XCTAssertEqual(try XCTUnwrap(offset(3.5)), 3.5, accuracy: 0.15)
    }

    func testLeftOfAxisIsNegative() {
        XCTAssertEqual(try XCTUnwrap(offset(-3.5)), -3.5, accuracy: 0.15)
    }

    func testOnTheAxisIsZero() {
        XCTAssertEqual(try XCTUnwrap(offset(0)), 0, accuracy: 0.05)
    }

    func testWorksOnAnyCourse() {
        // Курс — это точка зрения, а смещение — факт: на восток, на юг и на
        // северо-запад оно обязано быть одним и тем же.
        for course in [0.0, 90, 180, 270, 315] {
            XCTAssertEqual(try XCTUnwrap(offset(2.5, course: course)), 2.5,
                           accuracy: 0.2, "курс \(course)")
        }
    }

    // MARK: - Отказы

    func testUnmeasuredRoadKeepsTheCarOnTheAxis() {
        // Полосы не измерены — мы не знаем ни сколько их, ни где они.
        XCTAssertNil(offset(3.5, measured: false))
    }

    func testPoorAccuracyKeepsTheCarOnTheAxis() {
        // Полоса три с половиной метра: на пяти метрах ошибки машину покажет
        // в соседней, и это будет выглядеть уверенно.
        XCTAssertNil(offset(3.5, accuracy: 5))
        XCTAssertNil(offset(3.5, accuracy: -1), "точность неизвестна — тоже отказ")
    }

    func testAccuracyExactlyAtTheLimitIsStillTrusted() {
        XCTAssertNotNil(offset(3.5, accuracy: RoadSketch.laneAccuracyMeters))
    }

    func testOffRoadIsRefused() {
        // Дальше половины проезжей части — значит мы не на этой дороге, а на
        // дублёре, на тротуаре, или это промах посадки.
        XCTAssertNil(offset(9, width: 14))
    }

    func testEdgeOfTheCarriagewayIsStillOnIt() {
        XCTAssertNotNil(offset(6.9, width: 14))
    }

    func testZeroWidthIsRefused() {
        XCTAssertNil(offset(1, width: 0))
    }
}
