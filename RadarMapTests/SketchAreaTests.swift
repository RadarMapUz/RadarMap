//
//  SketchAreaTests.swift
//  RadarMapTests
//
//  Слои местности: вода, зелень, рельсы, кварталы.
//
//  Данные для них приезжали на сервер всё это время внутри того же .pbf, что
//  качается ради дорог, и выбрасывались фильтром по highway. Тесты сторожат
//  контракт формата и три правила: местность не качается там, где не видна;
//  рисуется ПОД дорогами; и гаснет в перегреве раньше всего, что несёт смысл.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class SketchAreaTests: XCTestCase {

    /// Байты из настоящего выхода build_roads.py: вода замкнутым контуром,
    /// рельсы лентой.
    private let golden = #"""
    {"version":2,"roads":[[1,1,[4130000,6925000,0,300,300,0,0,-300,-300,0]],\#
    [3,0,[4130500,6925000,200,200,200,200]]]}
    """#

    func testAreasDecodeWithKindAndClosedFlag() {
        let areas = RoadTiles.decodeAreas(Data(golden.utf8))
        XCTAssertEqual(areas?.count, 2)
        XCTAssertEqual(areas?.first?.kind, .water)
        XCTAssertEqual(areas?.first?.isClosed, true)
        XCTAssertEqual(areas?.last?.kind, .rail)
        XCTAssertEqual(areas?.last?.isClosed, false)
        XCTAssertEqual(areas?.first?.points.first?.latitude ?? 0, 41.3, accuracy: 1e-6)
    }

    func testUnknownKindIsSkippedNotFatal() {
        // Сервер вправе завести новый вид местности раньше, чем приложение о
        // нём узнает. Правильный ответ — не нарисовать его, а не выбросить
        // весь тайл: воду в том же файле водитель должен увидеть.
        let mixed = #"{"version":2,"roads":[[99,1,[4130000,6925000,0,300,300,0]],[1,1,[4130000,6925000,0,300,300,0]]]}"#
        let areas = RoadTiles.decodeAreas(Data(mixed.utf8))
        XCTAssertEqual(areas?.count, 1)
        XCTAssertEqual(areas?.first?.kind, .water)
    }

    func testSetsKnowWhichDecoderTheyNeed() {
        XCTAssertFalse(RoadTiles.Set.streets.isArea)
        XCTAssertFalse(RoadTiles.Set.far.isArea)
        XCTAssertTrue(RoadTiles.Set.water.isArea)
        XCTAssertEqual(RoadTiles.Set.blocks.areaKind, .block)
        XCTAssertNil(RoadTiles.Set.yards.areaKind)
    }

    // MARK: - Правила слоёв

    func testBlocksAreNearOnlyWhileWaterIsAlways() {
        // Вода и зелень — крупные ориентиры, они читаются на любом охвате.
        // Кварталы вблизи, где их вообще видно.
        XCTAssertEqual(SketchArea.Kind.water.maxSpanMeters, .greatestFiniteMagnitude)
        XCTAssertEqual(SketchArea.Kind.block.maxSpanMeters, RoadSketch.farNetworkSpan)
    }

    func testTerrainIsDrawnUnderRoads() {
        // Порядок задаётся сценой один раз, а не рендерером на каждой
        // пересборке. Кварталы под всем, вода поверх зелени.
        let order = [SketchArea.Kind.block, .green, .water, .rail].map(RoadSketch.drawOrder)
        XCTAssertEqual(order, order.sorted(), "слои обязаны идти снизу вверх")
    }

    func testSceneKeepsOnlyLayersVisibleAtThisSpan() {
        let block = SketchArea(points: ring(at: 41.3, 69.25), kind: .block, isClosed: true)
        let water = SketchArea(points: ring(at: 41.3, 69.25), kind: .water, isClosed: true)
        let near = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                    areas: [block, water],
                                    anchor: .init(latitude: 41.3, longitude: 69.25),
                                    spanMeters: 200)
        XCTAssertEqual(Set(near.areas.map(\.kind)), [.block, .water])

        let far = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                   areas: [block, water],
                                   anchor: .init(latitude: 41.3, longitude: 69.25),
                                   spanMeters: 600)
        XCTAssertEqual(Set(far.areas.map(\.kind)), [.water],
                       "квартал на охвате района неразличим и не рисуется")
    }

    func testThermalBudgetSilencesTerrainFirst() {
        // Местность — ориентиры, а не предупреждения. Она гаснет раньше всего,
        // что несёт смысл: дороги, маршрут и камеры не режутся ни на одной
        // ступени.
        XCTAssertGreaterThan(PerformanceMode.full.sketchAreaBudget,
                             PerformanceMode.reduced.sketchAreaBudget)
        XCTAssertEqual(PerformanceMode.minimal.sketchAreaBudget, 0)
        XCTAssertGreaterThan(PerformanceMode.minimal.carPlayAnnotationBudget, 0,
                             "камеры не гаснут никогда")
    }

    func testAreaBudgetIsRespected() {
        let many = (0..<50).map {
            SketchArea(points: ring(at: 41.3 + Double($0) * 0.0001, 69.25),
                       kind: .green, isClosed: true)
        }
        let scene = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                     areas: many, areaBudget: 10,
                                     anchor: .init(latitude: 41.3, longitude: 69.25),
                                     spanMeters: 200)
        XCTAssertEqual(scene.areas.count, 10)
    }

    private func ring(at latitude: Double, _ longitude: Double) -> [CLLocationCoordinate2D] {
        [(0.0, 0.0), (0.0, 0.001), (0.001, 0.001), (0.001, 0.0), (0.0, 0.0)].map {
            CLLocationCoordinate2D(latitude: latitude + $0.0, longitude: longitude + $0.1)
        }
    }

    // MARK: - Имя улицы и кольца

    func testNameArrivesFromTheFourthElement() {
        // Четвёртый элемент необязателен: имя есть у одной дороги из семи.
        let tile = #"{"version":2,"roads":[[3,0,[4130000,6925000,100,0],"Амира Темура"],[3,0,[4130500,6925000,100,0]]]}"#
        let lines = RoadTiles.decodeTile(Data(tile.utf8))
        XCTAssertEqual(lines?.count, 2)
        XCTAssertEqual(lines?.first?.name, "Амира Темура")
        XCTAssertEqual(lines?.last?.name, "", "нет имени — не «безымянная», а «не знаем»")
    }

    func testRingIsNeverDrawnAsOneWay() {
        // Бит кольца снимает одностороннесть: стрелки по кругу читаются как
        // ошибка рендера, а не как направление.
        let tile = #"{"version":2,"roads":[[3,9,[4130000,6925000,100,0,0,100,-100,0]]]}"#
        let line = RoadTiles.decodeTile(Data(tile.utf8))?.first
        XCTAssertEqual(line?.isRing, true)
        XCTAssertEqual(line?.isOneWay, false)
    }

    func testCurrentStreetTakesTheNearestNamedRoad() {
        let me = CLLocationCoordinate2D(latitude: 41.3, longitude: 69.25)
        let near = RoadLine(points: line(from: 41.3, lon: 69.2501),
                            kind: .primary, isDetailed: true, name: "Амира Темура")
        let far = RoadLine(points: line(from: 41.3, lon: 69.2530),
                           kind: .primary, isDetailed: true, name: "Далёкая")
        let network = StubNetwork(lines: [far, near])
        XCTAssertEqual(RoadSketch.currentStreet(network: network, at: me),
                       "Амира Темура")
    }

    func testUnnamedRoadGivesNoLabel() {
        // Пустая подпись под курсором хуже её отсутствия: она выглядит
        // сломанной, а не честной.
        let me = CLLocationCoordinate2D(latitude: 41.3, longitude: 69.25)
        let network = StubNetwork(lines: [RoadLine(points: line(from: 41.3, lon: 69.2501),
                                                   kind: .primary, isDetailed: true)])
        XCTAssertNil(RoadSketch.currentStreet(network: network, at: me))
    }

    func testDistantStreetIsNotOurs() {
        let me = CLLocationCoordinate2D(latitude: 41.3, longitude: 69.25)
        let network = StubNetwork(lines: [RoadLine(points: line(from: 41.3, lon: 69.2540),
                                                   kind: .primary, isDetailed: true,
                                                   name: "Соседняя")])
        XCTAssertNil(RoadSketch.currentStreet(network: network, at: me),
                     "улица в трёхстах метрах — не та, по которой мы едем")
    }

    private func line(from latitude: Double, lon: Double) -> [CLLocationCoordinate2D] {
        (0...4).map {
            CLLocationCoordinate2D(latitude: latitude - 0.002 + Double($0) * 0.001,
                                   longitude: lon)
        }
    }
}

/// Источник, отдающий заранее известные линии: имя улицы — чистая функция, и
/// проверять её надо без сеточных индексов и кэшей.
private struct StubNetwork: RoadNetworkSource {
    let lines: [RoadLine]
    func roads(near coordinate: CLLocationCoordinate2D,
               radius: CLLocationDistance) -> [RoadLine] { lines }
}
