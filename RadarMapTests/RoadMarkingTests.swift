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

    func testOnlyTheZebraHasNoFallbackGlyph() {
        XCTAssertFalse(SketchPoint.Kind.crossing.hasGlyph)
        for kind in SketchPoint.Kind.allCases where kind != .crossing {
            XCTAssertTrue(kind.hasGlyph, "\(kind) остался без запасного значка")
        }
    }

    func testPaintDiesOutSoonerThanIcons() {
        // Зебра дальше сотни метров — пиксель, стоп-линия — волос. Решение по
        // ним принимают на подъезде.
        XCTAssertLessThan(SketchPoint.Kind.crossing.maxSpanMeters,
                          SketchPoint.Kind.trafficLight.maxSpanMeters)
        XCTAssertLessThan(SketchPoint.Kind.stopLine.maxSpanMeters,
                          RoadSketch.farNetworkSpan)
    }

    // MARK: - Геометрия черты

    private func marking(azimuth: Double, width: Double) -> RoadSketch.Marking {
        RoadSketch.Marking(point: .zero, kind: .crossing,
                           azimuthDegrees: azimuth, widthMeters: width)
    }

    func testMarkingLiesAcrossTheRoadNotAlongIt() {
        // Дорога на север — черта строго на восток-запад.
        let (left, right) = marking(azimuth: 0, width: 20).ends
        XCTAssertEqual(Double(left.x), -10, accuracy: 0.001)
        XCTAssertEqual(Double(right.x), 10, accuracy: 0.001)
        XCTAssertEqual(Double(left.y), 0, accuracy: 0.001)
        XCTAssertEqual(Double(right.y), 0, accuracy: 0.001)
    }

    func testMarkingTurnsWithTheRoad() {
        // Дорога на восток — черта на север-юг.
        let (left, right) = marking(azimuth: 90, width: 20).ends
        XCTAssertEqual(Double(left.x), 0, accuracy: 0.001)
        XCTAssertEqual(Double(left.y), 10, accuracy: 0.001)
        XCTAssertEqual(Double(right.y), -10, accuracy: 0.001)
    }

    func testMarkingIsExactlyAsLongAsTheRoadIsWide() {
        for azimuth in stride(from: 0.0, to: 360.0, by: 15.0) {
            let (left, right) = marking(azimuth: azimuth, width: 22.5).ends
            let length = hypot(right.x - left.x, right.y - left.y)
            XCTAssertEqual(Double(length), 22.5, accuracy: 0.001,
                           "азимут \(azimuth): черта не во всю ширину")
        }
    }

    func testMarkingIsCentredOnItsPoint() {
        // Точка стоит на ОСИ дороги, и черта обязана выходить на обе стороны
        // поровну. Смещение оставило бы половину проезжей части неразмеченной.
        let mark = RoadSketch.Marking(point: CGPoint(x: 100, y: -40), kind: .stopLine,
                                      azimuthDegrees: 37, widthMeters: 12)
        let (left, right) = mark.ends
        XCTAssertEqual(Double((left.x + right.x) / 2), 100, accuracy: 0.001)
        XCTAssertEqual(Double((left.y + right.y) / 2), -40, accuracy: 0.001)
    }
}
