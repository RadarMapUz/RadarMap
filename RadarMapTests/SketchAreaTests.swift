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
        // Поверхность — набор с ТРЕМЯ видами внутри: полотно, перекрёсток и
        // разделительная. Вид берётся из записи, а не из буквы файла, и
        // вернуть отсюда один значило бы соврать про две трети набора.
        XCTAssertNil(RoadTiles.Set.surface.areaKind)
    }

    // MARK: - Очередь бюджета

    func testPavementOutranksEverything() {
        // Очередь бюджета была по maxSpanMeters, а он отвечает на другой
        // вопрос — «с какого масштаба слой осмыслен». Ключом бюджета он ставил
        // воду, зелень и кварталы ВПЕРЕДИ проезжей части: на боевых тайлах в
        // перегреве 72 места из 120 уходили на местность прежде, чем
        // рисовалась первая дорога.
        let ranks = SketchArea.Kind.allCases.sorted { $0.budgetRank < $1.budgetRank }
        XCTAssertEqual(Array(ranks.prefix(3)), [.road, .junction, .median])
        XCTAssertEqual(Array(ranks.suffix(2)), [.house, .sidewalk])
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

    private func line(from latitude: Double, lon: Double) -> [CLLocationCoordinate2D] {
        (0...4).map {
            CLLocationCoordinate2D(latitude: latitude - 0.002 + Double($0) * 0.001,
                                   longitude: lon)
        }
    }

    // MARK: - Ручные объекты

    func testPointsDecodeFromASingleCoordinate() {
        // Точка — одна координата, а не вырожденная ломаная: формат записи
        // тот же, что у дорог, но координат ровно две.
        let tile = #"{"version":2,"roads":[[1,0,[4130000,6925000]],[4,0,[4130100,6925100]]]}"#
        let points = RoadTiles.decodePoints(Data(tile.utf8))
        XCTAssertEqual(points?.count, 2)
        XCTAssertEqual(points?.first?.kind, .trafficLight)
        XCTAssertEqual(points?.last?.kind, .uTurn)
        XCTAssertEqual(points?.first?.coordinate.latitude ?? 0, 41.3, accuracy: 1e-6)
    }

    func testUnknownPointKindIsSkippedNotFatal() {
        // Панель вправе завести новый вид раньше, чем выйдет сборка. Светофоры
        // в том же файле водитель увидеть обязан.
        let tile = #"{"version":2,"roads":[[99,0,[4130000,6925000]],[1,0,[4130000,6925000]]]}"#
        let points = RoadTiles.decodePoints(Data(tile.utf8))
        XCTAssertEqual(points?.count, 1)
        XCTAssertEqual(points?.first?.kind, .trafficLight)
    }

    func testPointsSetNeedsItsOwnDecoder() {
        XCTAssertTrue(RoadTiles.Set.points.isPoints)
        XCTAssertFalse(RoadTiles.Set.points.isArea)
        XCTAssertNil(RoadTiles.Set.points.areaKind)
        XCTAssertFalse(RoadTiles.Set.water.isPoints)
    }

    func testOnlyTheTrafficLightSurvivesTheDistrictSpan() {
        // Светофор живёт до самого дальнего охвата, потому что для костяка
        // сервер считает ОТДЕЛЬНЫЙ набор: свои пересечения, своё сведение,
        // своя посадка на сведённую ось. Остальные виды такого набора не
        // имеют, и на костяке им нечего показывать — они обрываются на
        // границе детальной сети.
        XCTAssertEqual(SketchPoint.Kind.trafficLight.maxSpanMeters,
                       MapViewport.maxSpanMeters)
        for kind in SketchPoint.Kind.allCases
        where kind != .trafficLight && !kind.isPaint {
            XCTAssertEqual(kind.maxSpanMeters, MapViewport.farNetworkSpan,
                           "\(kind) живёт ровно до костяка района")
        }
    }

    func testPaintDiesOutBeforeTheDetailedNetworkDoes() {
        // Краска — исключение из правила выше, и в другую сторону. Значок
        // размером с палец читается до самой границы детальной сети; черта
        // шириной в сорок сантиметров дальше сотни метров — волос, а зебра —
        // серое пятно. Решение по ним принимают на подъезде, и держать их
        // дольше значит платить растром за то, чего не видно.
        for kind in SketchPoint.Kind.allCases where kind.isPaint {
            XCTAssertLessThan(kind.maxSpanMeters, MapViewport.farNetworkSpan,
                              "\(kind) — краска, она обязана гаснуть раньше сети")
        }
    }

    func testTheFarPointSetIsPointsToo() {
        // Два набора, одна распаковка: дальний отличается геометрией, а не
        // форматом. Перепутать их местами нельзя — они разные наборы.
        XCTAssertTrue(RoadTiles.Set.pointsFar.isPoints)
        XCTAssertFalse(RoadTiles.Set.pointsFar.isArea)
        XCTAssertNotEqual(RoadTiles.Set.pointsFar, RoadTiles.Set.points)
    }

}

/// Источник, отдающий заранее известные линии: имя улицы — чистая функция, и
/// проверять её надо без сеточных индексов и кэшей.
private struct StubNetwork: RoadNetworkSource {
    let lines: [RoadLine]
    func roads(near coordinate: CLLocationCoordinate2D,
               radius: CLLocationDistance) -> [RoadLine] { lines }
}
