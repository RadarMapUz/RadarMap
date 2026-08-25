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

    // MARK: - Стрелка

    func testTrimmedShortensFromTheEnd() {
        let trimmed = SketchGeometry.trimmed([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100)],
                                             byLast: 30)
        XCTAssertEqual(Double(trimmed.last?.y ?? 0), 70, accuracy: 0.01,
                       "тело стрелки не должно торчать сквозь её голову")
    }

    func testTrimmedEatsWholeSegments() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 50), CGPoint(x: 0, y: 100)]
        let trimmed = SketchGeometry.trimmed(points, byLast: 70)
        XCTAssertEqual(trimmed.count, 2)
        XCTAssertEqual(Double(trimmed.last?.y ?? 0), 30, accuracy: 0.01)
    }

    func testArrowHeadPointsAlongTheLastSegment() {
        let head = SketchGeometry.arrowHead(
            along: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], size: 20)
        let box = head.body.boundingRect
        XCTAssertEqual(Double(box.maxX), 100, accuracy: 0.5, "остриё — в конце ломаной")
        XCTAssertEqual(Double(box.minX), 80, accuracy: 0.5, "голова смотрит по ходу")
        XCTAssertEqual(Double(box.midY), 0, accuracy: 0.5)
    }

    func testArrowHeadIgnoresDegenerateTail() {
        // На выходе из поворота последние точки маршрута могут совпасть.
        // Нулевой вектор развернул бы голову куда угодно — и стрелка смотрела
        // бы поперёк дороги.
        let clean = SketchGeometry.arrowHead(
            along: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], size: 20)
        let doubled = SketchGeometry.arrowHead(
            along: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 0)],
            size: 20)
        XCTAssertEqual(clean.body.boundingRect, doubled.body.boundingRect)
    }

    func testArrowCasingIsBiggerThanBody() {
        let head = SketchGeometry.arrowHead(
            along: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], size: 20)
        XCTAssertGreaterThan(head.casing.boundingRect.width, head.body.boundingRect.width,
                             "кайма обязана обводить голову, а не совпадать с ней")
    }
}
