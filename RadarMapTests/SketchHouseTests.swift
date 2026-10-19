//
//  SketchHouseTests.swift
//  RadarMapTests
//
//  Дома. Самый большой слой по числу объектов и самый спорный за рулём:
//  водитель едет по дороге, а не по подъездам.
//
//  Числа здесь не круглые и не выдуманы — замерены на живых данных по одному
//  кадру центра Ташкента (0,06° × 0,14°): 54 094 дома из OSM против семисот
//  дорог. Поэтому все три правила слоя про цену, а не про красоту: он не
//  качается там, где не виден; ложится на квартал и под всё остальное;
//  и приходит своим набором, чтобы его можно было не просить вовсе.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class SketchHouseTests: XCTestCase {

    /// Байты в том же виде, в каком их пишет build_roads.py: замкнутый контур
    /// с кодом слоя домов.
    private let golden = #"""
    {"version":2,"roads":[[6,1,[4130000,6925000,0,200,200,0,0,-200,-200,0]]]}
    """#

    func testHouseDecodesAsClosedArea() {
        let areas = RoadTiles.decodeAreas(Data(golden.utf8))
        XCTAssertEqual(areas?.count, 1)
        XCTAssertEqual(areas?.first?.kind, .house)
        XCTAssertEqual(areas?.first?.isClosed, true)
    }

    func testHouseSetMapsToHouseKind() {
        XCTAssertEqual(RoadTiles.Set(rawValue: "h"), .houses)
        XCTAssertEqual(RoadTiles.Set.houses.areaKind, .house)
        XCTAssertTrue(RoadTiles.Set.houses.isArea)
        XCTAssertFalse(RoadTiles.Set.houses.isPoints)
    }

    func testHouseIsOnlyForTheLastTwoHundredMetres() {
        // Дом отвечает на вопрос «мне вот сюда сворачивать». На охвате, где
        // выбирают поворот, он уже не ориентир, а шум — которого по числу
        // объектов больше, чем всей остальной схемы вместе.
        XCTAssertLessThanOrEqual(SketchArea.Kind.house.maxSpanMeters, 200)
        XCTAssertLessThan(SketchArea.Kind.house.maxSpanMeters,
                          SketchArea.Kind.block.maxSpanMeters)
    }

    func testStoreysRideInTheFlags() {
        // Пятый элемент записи невозможен: decodeEntries принимает длину 3 или
        // 4, и пятый отправил бы в nil ВЕСЬ тайл у сборок, которые о нём не
        // знают. Биты старая сборка просто не видит.
        let five = "{\"version\":2,\"roads\":[[6,11,"
            + "[4130000,6925000,0,200,200,0,0,-200,-200,0]]]}"
        let areas = RoadTiles.decodeAreas(Data(five.utf8))
        XCTAssertEqual(areas?.first?.levels, 5)
        XCTAssertEqual(areas?.first?.isClosed, true)
    }

    func testHouseWithoutStoreysClaimsNothing() {
        // Выдуманная высота превращает город в макет из одинаковых коробок, а
        // водитель, поймавший выдумку, перестаёт верить и правде. Замерено:
        // этажность известна у 40 % домов центра.
        XCTAssertEqual(RoadTiles.decodeAreas(Data(golden.utf8))?.first?.levels, 0)
    }

    func testStoreysAreOnlyForHouses() {
        // У воды те же биты значат другое: считать их этажами — рисовать
        // тень под прудом.
        let water = "{\"version\":2,\"roads\":[[1,11,"
            + "[4130000,6925000,0,200,200,0]]]}"
        XCTAssertEqual(RoadTiles.decodeAreas(Data(water.utf8))?.first?.levels, 0)
    }

    func testHouseCodeMatchesTheServer() {
        // Код слоя — контракт с build_roads.py (AREA_HOUSE). Разойдись он —
        // телефон нарисовал бы дома водой, причём молча.
        XCTAssertEqual(SketchArea.Kind.house.rawValue, 6)
    }
}
