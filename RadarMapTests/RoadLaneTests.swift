//
//  RoadLaneTests.swift
//  RadarMapTests
//
//  Полосы и ширина проезжей части — вторая половина контракта с
//  server/build_roads.py.
//
//  Сервер возит НЕ ширину, а число полос, и возит его старшими битами того же
//  поля flags. Тесты здесь про три запрета.
//
//  Пятый элемент записи. Он выглядит очевидным местом для нового поля и
//  уронил бы разбор ЦЕЛОГО тайла: `decodeEntries` принимает записи длиной 3
//  или 4 и на пятом возвращает nil — установленная сборка потеряла бы не
//  дорогу, а весь квадрат. Тест держит это правило со стороны клиента.
//
//  Старшие биты не должны шевелить характер линии. Сборка, ничего не знающая
//  о полосах, читает flags масками, и односторонняя обязана остаться
//  односторонней при любом числе полос.
//
//  Таблицы ширин обязаны совпадать с сервером. Разойдутся — панель
//  конструктора будет рисовать одну дорогу, а телефон другую, и увидит это
//  только водитель.
//

import XCTest
@testable import RadarMap

final class RoadLaneTests: XCTestCase {

    private func tileData(_ roads: [[Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["version": 1, "roads": roads])
    }

    private func line(_ code: Int, _ flags: Int) throws -> RoadLine {
        let data = tileData([[code, flags, [4_131_000, 6_925_000, 100, 0]]])
        return try XCTUnwrap(RoadTiles.decodeTile(data)?.first)
    }

    // MARK: - Разбор

    func testLanesComeFromTheHighBits() throws {
        // 6 полос = 6 << 4 = 96.
        XCTAssertEqual(try line(3, 96).lanes, 6)
        XCTAssertEqual(try line(3, 0).lanes, 0, "ноль — «тайл не сказал»")
        XCTAssertEqual(try line(3, 15 << 4).lanes, 15, "потолок четырёх бит")
    }

    func testLanesDoNotDisturbTheCharacterOfTheLine() throws {
        // Одностороннее + мост + 6 полос.
        let road = try line(1, 96 | 1 | 2)
        XCTAssertEqual(road.lanes, 6)
        XCTAssertTrue(road.isOneWay, "полосы не имеют права выключить односторонность")
        XCTAssertEqual(road.level, 1, "и не имеют права уронить мост на землю")
    }

    func testEveryLaneCountRoundTrips() throws {
        for lanes in 0...15 {
            XCTAssertEqual(try line(4, lanes << 4).lanes, lanes)
        }
    }

    // MARK: - Запрет пятого элемента

    func testFifthElementKillsTheWholeTile() {
        // Не «декодирует четыре и игнорирует пятое», а возвращает nil целиком.
        // Именно поэтому полосы едут битами: тайл с пятым элементом стоил бы
        // установленной сборке региона, а не дороги.
        let data = tileData([[3, 0, [4_131_000, 6_925_000, 100, 0], "Навои", 6]])
        XCTAssertNil(RoadTiles.decodeTile(data),
                     "запись из пяти элементов обязана быть отвергнута целиком")
    }

    func testFourElementsWithANameStillWork() throws {
        let data = tileData([[3, 96, [4_131_000, 6_925_000, 100, 0], "Навои"]])
        let road = try XCTUnwrap(RoadTiles.decodeTile(data)?.first)
        XCTAssertEqual(road.name, "Навои")
        XCTAssertEqual(road.lanes, 6)
    }

    // MARK: - Ширина

    func testWidthFollowsClassAndLanes() {
        // Те же числа, что в LANE_METERS на сервере.
        var avenue = RoadLine(points: [], kind: .primary)
        avenue.lanes = 6
        XCTAssertEqual(avenue.widthMeters, 22.5, accuracy: 1e-9)

        var street = RoadLine(points: [], kind: .residential)
        street.lanes = 2
        XCTAssertEqual(street.widthMeters, 7.0, accuracy: 1e-9)

        var yard = RoadLine(points: [], kind: .service)
        yard.lanes = 1
        XCTAssertEqual(yard.widthMeters, 4.5, accuracy: 1e-9)
    }

    func testSilentTileStillGivesAWidth() {
        // Ноль полос — не «дороги нет»: рисовать её всё равно надо, и ширина
        // берётся дефолтом класса. Это основной путь, а не запасной: тег lanes
        // стоит у 9 % дорог центра Ташкента.
        var quiet = RoadLine(points: [], kind: .secondary)
        quiet.lanes = 0
        XCTAssertEqual(quiet.widthMeters, 4 * 3.5, accuracy: 1e-9)
    }

    func testOneWayHalvesTheDefault() {
        // Тег lanes считает полосы ВСЕЙ дороги, и у односторонней их вдвое
        // меньше. Иначе половина проспекта рисовалась бы шириной целого.
        var both = RoadLine(points: [], kind: .primary)
        both.isOneWay = false
        var single = RoadLine(points: [], kind: .primary)
        single.isOneWay = true
        XCTAssertEqual(both.widthMeters, single.widthMeters * 2, accuracy: 1e-9)
    }

    func testWidthNeverReachesTheGate() {
        // Ворота сервера стоят на 60 м. Четыре бита физически не дают их
        // достичь — опечатка в теге не может уехать на телефоны в принципе.
        let classes: [RoadClass] = [.motorway, .trunk, .primary, .secondary,
                                    .tertiary, .residential, .service]
        for kind in classes {
            var road = RoadLine(points: [], kind: kind)
            road.lanes = 15
            XCTAssertLessThan(road.widthMeters, 60, "\(kind) шире ворот")
        }
    }

}
