//
//  SketchGeometryTests.swift
//  RadarMapTests
//
//  Геометрия новых слоёв схемы: кусок маршрута под стрелку манёвра и под
//  пройденное, окно видимости манёвра и сама стрелка.
//
//  Оба куска считаются В МЕТРАХ ОТ ОПОРЫ СЦЕНЫ и кладутся поверх растра. Цена
//  ошибки здесь наглядная: стрелка, посчитанная не от той опоры или собранная
//  по ближайшим вершинам вместо точных отметок, ложится не на ту дорогу — и
//  показывает поворот там, где его нет.
//

import CoreLocation
import CoreGraphics
import XCTest
@testable import RadarMap

final class SketchGeometryTests: XCTestCase {

    /// Прямая строго на север: шаг 0.001° широты ≈ 111.32 м.
    private let line: [CLLocationCoordinate2D] = (0...3).map {
        CLLocationCoordinate2D(latitude: 41.300 + Double($0) * 0.001, longitude: 69.250)
    }

    // MARK: - Кусок пути

    func testSubPathInterpolatesEndsExactly() {
        let piece = RoadSketch.subPath(line, from: 50, to: 150, anchor: line[0])
        // Начало, вершина на 111 м и конец — ровно три точки.
        XCTAssertEqual(piece.count, 3)
        XCTAssertEqual(Double(piece.first?.y ?? 0), 50, accuracy: 1.5,
                       "начало куска обязано быть на отметке, а не на вершине")
        XCTAssertEqual(Double(piece.last?.y ?? 0), 150, accuracy: 1.5,
                       "конец куска обязан быть на отметке, а не на вершине")
        for point in piece {
            XCTAssertEqual(Double(point.x), 0, accuracy: 1.5, "линия шла строго на север")
        }
    }

    func testSubPathIsRelativeToAnchor() {
        // Опора — вторая вершина: тот же кусок обязан уехать на её смещение.
        let piece = RoadSketch.subPath(line, from: 50, to: 150, anchor: line[1])
        XCTAssertEqual(Double(piece.first?.y ?? 0), 50 - 111.32, accuracy: 1.5)
    }

    func testSubPathRefusesEmptyAndInverted() {
        XCTAssertTrue(RoadSketch.subPath(line, from: 100, to: 100, anchor: line[0]).isEmpty)
        XCTAssertTrue(RoadSketch.subPath(line, from: 200, to: 100, anchor: line[0]).isEmpty)
        XCTAssertTrue(RoadSketch.subPath([line[0]], from: 0, to: 100, anchor: line[0]).isEmpty)
    }

    func testSubPathClampsBeyondTheEnd() {
        // Запрос дальше конца маршрута отдаёт то, что есть, а не пустоту:
        // на подъезде к финишу окно стрелки заведомо вылезает за него.
        let piece = RoadSketch.subPath(line, from: 300, to: 900, anchor: line[0])
        XCTAssertGreaterThanOrEqual(piece.count, 2)
        XCTAssertEqual(Double(piece.last?.y ?? 0), 333.96, accuracy: 1.5)
    }

    // MARK: - Окно манёвра

    func testManeuverWindowHiddenWhileFarAway() {
        XCTAssertNil(RoadSketch.maneuverWindow(stepAlong: 1200, progress: 0),
                     "манёвр за километр — ещё не решение")
    }

    func testManeuverWindowDisappearsAfterPassing() {
        // Пока манёвр под нами, стрелка ещё нужна: поворот длится дольше точки.
        XCTAssertNotNil(RoadSketch.maneuverWindow(stepAlong: 1000, progress: 1020))
        XCTAssertNil(RoadSketch.maneuverWindow(stepAlong: 1000, progress: 1100),
                     "пройденный манёвр показывать нечего")
    }

    func testManeuverWindowStraddlesTheTurn() {
        let window = RoadSketch.maneuverWindow(stepAlong: 1000, progress: 800)
        XCTAssertEqual(window?.from, 1000 - RoadSketch.maneuverLeadMeters)
        XCTAssertEqual(window?.to, 1000 + RoadSketch.maneuverTailMeters)
    }

    func testManeuverWindowNeverStartsBeforeTheRoute() {
        // Манёвр в тридцати метрах от старта: окно обязано начинаться с нуля,
        // а не с отрицательной отметки пути.
        XCTAssertEqual(RoadSketch.maneuverWindow(stepAlong: 30, progress: 0)?.from, 0)
    }
}
