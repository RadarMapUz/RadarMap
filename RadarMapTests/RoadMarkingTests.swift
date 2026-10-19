//
//  RoadMarkingTests.swift
//  RadarMapTests
//
//  Краска на асфальте: зебры и стоп-линии.
//
//  Разметка держится на двух числах, которых у точки раньше не было: азимут
//  дороги под ней и ширина проезжей части. Оба приезжают битами записи точки —
//  контракт с point_flags в server/build_roads.py, — и ошибка в любом из них
//  не роняет ничего: черта просто ляжет вдоль дороги вместо поперёк или не
//  дотянется до кромки. Увидеть это можно только глазами и только в движении,
//  поэтому тесты здесь считают геометрию, а не смотрят.
//

import XCTest
@testable import RadarMap

final class RoadMarkingTests: XCTestCase {

    private func tileData(_ points: [[Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["version": 1, "roads": points])
    }

    /// Биты записи точки: 0–6 азимут шагом 3°, 7–12 ширина целыми метрами.
    private func flags(azimuth: Int, width: Int) -> Int {
        (azimuth / 3) | (width << 7)
    }

    // MARK: - Разбор

    func testAzimuthAndWidthComeOutOfTheBits() throws {
        let data = tileData([[5, flags(azimuth: 273, width: 22), [4_131_000, 6_925_000]]])
        let point = try XCTUnwrap(RoadTiles.decodePoints(data)?.first)
        XCTAssertEqual(point.kind, .crossing)
        XCTAssertEqual(point.azimuthDegrees, 273, accuracy: 1.5)
        XCTAssertEqual(point.widthMeters, 22, accuracy: 0.001)
    }

    func testAzimuthAndWidthDoNotCollide() throws {
        // Ширина живёт выше азимута; сдвиг на бит перепутал бы их местами, и
        // зебра встала бы под случайным углом нужной длины.
        for azimuth in stride(from: 0, to: 360, by: 27) {
            for width in [1, 7, 22, 63] {
                let data = tileData([[5, flags(azimuth: azimuth, width: width),
                                      [4_131_000, 6_925_000]]])
                let point = try XCTUnwrap(RoadTiles.decodePoints(data)?.first)
                XCTAssertEqual(point.azimuthDegrees, Double(azimuth / 3 * 3), accuracy: 0.001)
                XCTAssertEqual(point.widthMeters, Double(width), accuracy: 0.001)
            }
        }
    }

    func testUnknownKindIsSkippedNotFatal() {
        // Панель вправе завести новый вид раньше, чем выйдет сборка, и
        // светофоры из того же файла водитель увидеть обязан.
        let data = tileData([
            [99, 0, [4_131_000, 6_925_000]],
            [1, 0, [4_131_000, 6_925_000]],
        ])
        XCTAssertEqual(RoadTiles.decodePoints(data)?.count, 1)
    }

    // MARK: - Краска или значок

    func testPaintAndGlyphsAreDifferentLayers() {
        // Значок едет слоем, которому возвращён курс, иначе светофор ложится
        // набок на повороте. Краска обязана поворачиваться ВМЕСТЕ с дорогой:
        // зебра, которой вернули курс, встала бы поперёк своего перехода.
        XCTAssertTrue(SketchPoint.Kind.crossing.isPaint)
        XCTAssertTrue(SketchPoint.Kind.stopLine.isPaint)
        XCTAssertFalse(SketchPoint.Kind.trafficLight.isPaint)
        XCTAssertFalse(SketchPoint.Kind.speedBump.isPaint)
    }

    func testPurePaintHasNoFallbackGlyph() {
        // Значком краску не заменишь: зебра и стрелки полос — про место на
        // асфальте, а не про объект рядом с дорогой. Стоп-линия исключение и
        // остаётся со значком: она жила им до появления разметки, и там, где
        // сервер не нашёл дороги, обязана жить дальше.
        XCTAssertFalse(SketchPoint.Kind.crossing.hasGlyph)
        XCTAssertFalse(SketchPoint.Kind.laneArrows.hasGlyph)
        XCTAssertTrue(SketchPoint.Kind.stopLine.hasGlyph)
        for kind in SketchPoint.Kind.allCases where !kind.isPaint {
            XCTAssertTrue(kind.hasGlyph, "\(kind) остался без значка")
        }
    }

    func testPaintDiesOutSoonerThanIcons() {
        // Зебра дальше сотни метров — пиксель, стоп-линия — волос. Решение по
        // ним принимают на подъезде.
        XCTAssertLessThan(SketchPoint.Kind.crossing.maxSpanMeters,
                          SketchPoint.Kind.trafficLight.maxSpanMeters)
        XCTAssertLessThan(SketchPoint.Kind.stopLine.maxSpanMeters,
                          MapViewport.farNetworkSpan)
    }

    // MARK: - Стрелки полос

    func testTurnsComeFromTheHighBits() throws {
        // Направления лежат выше азимута и ширины, по четыре бита на полосу:
        // налево(2), прямо(1), прямо-направо(8).
        let turns = (2 << 13) | (1 << 17) | (8 << 21)
        let data = tileData([[6, flags(azimuth: 0, width: 11) | turns,
                              [4_131_000, 6_925_000]]])
        let point = try XCTUnwrap(RoadTiles.decodePoints(data)?.first)
        XCTAssertEqual(point.kind, .laneArrows)
        XCTAssertEqual(point.turns, [.left, .through, .throughRight])
    }

    func testLaneCountComesFromTurnsNotFromWidth() throws {
        // Ширина знает про метры, а не про разметку: деление её на среднюю
        // полосу давало бы то восемь стрелок там, где их шесть, то наоборот.
        let turns = (1 << 13) | (1 << 17)
        let data = tileData([[6, flags(azimuth: 0, width: 40) | turns,
                              [4_131_000, 6_925_000]]])
        let point = try XCTUnwrap(RoadTiles.decodePoints(data)?.first)
        XCTAssertEqual(point.turns.count, 2, "число полос взято из ширины")
    }

    func testOnlyArrowsCarryTurns() throws {
        let data = tileData([[5, flags(azimuth: 0, width: 11) | (2 << 13),
                              [4_131_000, 6_925_000]]])
        let point = try XCTUnwrap(RoadTiles.decodePoints(data)?.first)
        XCTAssertTrue(point.turns.isEmpty, "у зебры направлений быть не может")
    }

    func testUnknownTurnIsReadAsNothing() throws {
        // В turn:lanes встречается что угодно, и терять из-за этого дорогу
        // нельзя.
        let data = tileData([[6, flags(azimuth: 0, width: 11) | (15 << 13),
                              [4_131_000, 6_925_000]]])
        let point = try XCTUnwrap(RoadTiles.decodePoints(data)?.first)
        XCTAssertTrue(point.turns.isEmpty)
    }

    func testAmbiguousTurnIsDrawnAsTwoArrows() {
        // Одна фигура о двух смыслах читается боковым зрением как ошибка.
        XCTAssertEqual(LaneTurn.throughLeft.angles.count, 2)
        XCTAssertEqual(LaneTurn.throughRight.angles.count, 2)
        XCTAssertEqual(LaneTurn.leftRight.angles.count, 2)
        XCTAssertEqual(LaneTurn.through.angles, [0])
    }

    func testEveryTurnHasADirectionExceptNone() {
        for turn in LaneTurn.allCases where turn != .none {
            XCTAssertFalse(turn.angles.isEmpty, "\(turn) нечем нарисовать")
        }
        XCTAssertTrue(LaneTurn.none.angles.isEmpty)
    }

}
