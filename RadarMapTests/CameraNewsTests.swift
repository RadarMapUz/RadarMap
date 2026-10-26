//
//  CameraNewsTests.swift
//  RadarMapTests
//
//  Новые камеры на своих дорогах (31E): первый запуск молчит, камера на
//  своей улице — новость, через квартал — нет, пересборка базы — не новость,
//  старая дорога забывается.
//

import XCTest
@testable import RadarMap

final class CameraNewsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Улица на восток: 41.31, от 69.25 до 69.27.
    private func myRoads(daysAgo: Double = 3) -> RoadCells {
        var cells = RoadCells()
        cells.add([(41.31, 69.25), (41.31, 69.27)], on: now.addingTimeInterval(-daysAgo * 86_400))
        return cells
    }

    private func point(_ id: Int, _ lat: Double, _ lon: Double) -> CameraNews.Point {
        CameraNews.Point(id: id, lat: lat, lon: lon)
    }

    func testFirstRunSetsBaselineWithoutNews() {
        let update = CameraNews.update(known: nil, current: [point(1, 41.31, 69.26)], roads: myRoads(), now: now)
        XCTAssertEqual(update?.known, [1])
        XCTAssertEqual(update?.found, [], "вся база оказалась бы новостью")
    }

    func testNewCameraOnMyRoadIsNews() {
        let current = [point(1, 41.31, 69.26), point(2, 41.3102, 69.262), point(3, 41.33, 69.26)]
        let update = CameraNews.update(known: [1], current: current, roads: myRoads(), now: now)
        XCTAssertEqual(update?.found.map(\.id), [2], "камера в 2 км от своей улицы стала новостью")
        XCTAssertEqual(update?.known, [1, 2, 3])
    }

    func testNothingNewMeansNoUpdate() {
        XCTAssertNil(CameraNews.update(known: [1], current: [point(1, 41.31, 69.26)], roads: myRoads(), now: now))
        XCTAssertNil(CameraNews.update(known: [1], current: [], roads: myRoads(), now: now), "база не прочитана")
    }

    func testRebuiltDatabaseIsNotNews() {
        let current = (1000..<1200).map { point($0, 41.31, 69.26) }
        let update = CameraNews.update(known: [1], current: current, roads: myRoads(), now: now)
        XCTAssertEqual(update?.found, [], "новые номера всей базы — не 200 новых камер")
    }

    func testOldRoadsAreForgotten() {
        var cells = myRoads(daysAgo: 70)
        XCTAssertFalse(cells.covers(lat: 41.31, lon: 69.26, now: now), "дорога 70 дней назад — уже не своя")
        cells.prune(now: now)
        XCTAssertTrue(cells.isEmpty)
        XCTAssertTrue(myRoads().covers(lat: 41.311, lon: 69.26, now: now), "в 110 м от оси — своя улица")
    }

    func testRoadCellsRoundTrip() throws {
        let cells = myRoads()
        let data = try JSONEncoder().encode(cells)
        XCTAssertEqual(try JSONDecoder().decode(RoadCells.self, from: data), cells)
        XCTAssertGreaterThan(cells.count, 5, "между точками трека в 1,7 км остались дыры")
    }

    func testVisibleDropsOldAndRemovedCameras() {
        let items = [CameraNews.Item(id: 1, found: now.addingTimeInterval(-86_400)),
                     CameraNews.Item(id: 2, found: now.addingTimeInterval(-40 * 86_400)),
                     CameraNews.Item(id: 3, found: now.addingTimeInterval(-3600)),
                     CameraNews.Item(id: 1, found: now.addingTimeInterval(-7200))]
        let shown = CameraNews.visible(items, existing: [1, 2], now: now)
        XCTAssertEqual(shown.map(\.id), [1], "старая новость, снятая камера или дубль остались на экране")
    }
}
