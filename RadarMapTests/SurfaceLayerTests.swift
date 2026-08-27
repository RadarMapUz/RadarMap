//
//  SurfaceLayerTests.swift
//  RadarMapTests
//

import Testing

@testable import RadarMap

@Suite("Поверхность дороги на телефоне")
struct SurfaceLayerTests {

    private func tile(_ rows: [[Any]]) -> Data {
        let json = rows.map { row -> String in
            let flat = (row[2] as! [Int]).map(String.init).joined(separator: ",")
            return "[\(row[0]),\(row[1]),[\(flat)]]"
        }.joined(separator: ",")
        return Data("{\"version\":2,\"roads\":[\(json)]}".utf8)
    }

    @Test("Полотно разбирается со своим классом")
    func classTravelsInFlags() throws {
        // Класс — в тех же старших битах, что этажность у дома. Пятый элемент
        // записи невозможен: decodeEntries принимает длину 3 или 4 и на пятом
        // возвращает nil на ВЕСЬ тайл.
        let flags = 1 | (3 << 1)
        let square = [4131000, 6928000, 200, 0, 0, 200, -200, 0]
        let areas = try #require(RoadTiles.decodeAreas(tile([[7, flags, square]])))
        #expect(areas.count == 1)
        #expect(areas[0].kind == .road)
        #expect(areas[0].isClosed)
        #expect(areas[0].roadClass == 3)
    }

    @Test("Перекрёсток класса не несёт")
    func junctionHasNoClass() throws {
        let square = [4131000, 6928000, 200, 0, 0, 200, -200, 0]
        let areas = try #require(RoadTiles.decodeAreas(tile([[8, 1, square]])))
        #expect(areas[0].kind == .junction)
        #expect(areas[0].roadClass == 0)
    }

    @Test("Дом по-прежнему читает те же биты как этажность")
    func houseStillReadsLevels() throws {
        // Одно поле старших битов значит разное у разных видов. Проверка
        // именно на то, что виды не перепутаны.
        let square = [4131000, 6928000, 200, 0, 0, 200, -200, 0]
        let areas = try #require(RoadTiles.decodeAreas(tile([[6, 1 | (9 << 1), square]])))
        #expect(areas[0].kind == .house)
        #expect(areas[0].levels == 9)
        #expect(areas[0].roadClass == 0)
    }

    @Test("Поверхность — ближний охват и только он")
    func surfaceIsCloseRangeOnly() {
        // На охвате района полотно вырождается в линию, и штрих там честнее и
        // дешевле: видно костяк района, а не отдельные проезжие части.
        #expect(SketchArea.Kind.road.maxSpanMeters == 250)
        #expect(SketchArea.Kind.junction.maxSpanMeters == 250)
        #expect(SketchArea.Kind.road.maxSpanMeters < RoadSketch.farNetworkSpan)
    }

    @Test("Поверхность ложится над местностью и под сетью")
    func drawOrderHolds() {
        let order = RoadSketch.drawOrder
        #expect(order(.road) > order(.sidewalk), "полотно ушло под тротуар")
        #expect(order(.junction) > order(.road),
                "перекрёсток под полотном не закроет стыки")
        #expect(order(.house) < order(.road))
    }

    @Test("Набор d — площадной")
    func surfaceIsAnAreaSet() {
        #expect(RoadTiles.Set.surface.isArea)
        #expect(RoadTiles.Set(rawValue: "d") == .surface)
    }
}
