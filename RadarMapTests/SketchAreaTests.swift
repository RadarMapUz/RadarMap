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

    // MARK: - Правила слоёв

    func testBlocksLiveAtEveryScaleNow() {
        // Вода и зелень — крупные ориентиры, они читаются на любом охвате.
        // Кварталы — тоже, и это правка: они гасли после 340 метров, ровно
        // там, где город должен превращаться в массу застройки. Вместо неё
        // оставалось пустое поле, а кварталов в кадре на полкилометра всего
        // восемьдесят восемь — это дёшево.
        XCTAssertEqual(SketchArea.Kind.water.maxSpanMeters, .greatestFiniteMagnitude)
        XCTAssertEqual(SketchArea.Kind.block.maxSpanMeters, .greatestFiniteMagnitude)
        // А дом и тротуар остаются вблизи: их по числу больше всего
        // остального вместе, и на дальнем плане они шум, а не ориентир.
        XCTAssertLessThan(SketchArea.Kind.house.maxSpanMeters, RoadSketch.farNetworkSpan)
        XCTAssertLessThan(SketchArea.Kind.sidewalk.maxSpanMeters,
                          SketchArea.Kind.house.maxSpanMeters)
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

    func testRoadAndJunctionsLiveOrDieTogether() {
        // Дорога без площади перекрёстка — это ленты, которые не сходятся, а
        // дорога, у которой выброшен каждый пятый кусок, — рваная. Замерено в
        // перегреве на боевых тайлах: при бюджете 120 терялись ВСЕ 41 площадь
        // перекрёстка и 20 из 82 кусков полотна. Ровно это и было на снимке
        // с баннером «Телефон перегрелся».
        let pavement = (0..<6).map { index in
            SketchArea(points: ring(at: 41.3 + Double(index) * 0.0001, 69.25),
                       kind: index < 4 ? .road : .junction, isClosed: true)
        }
        let tight = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                     areas: pavement, areaBudget: 5,
                                     anchor: .init(latitude: 41.3, longitude: 69.25),
                                     spanMeters: 200)
        XCTAssertFalse(tight.areas.contains { $0.kind.isPavement },
                       "полотно нарисовано наполовину — это и есть рваные дороги")
        XCTAssertFalse(tight.hasPavement,
                       "вью обязана узнать, что полотна нет, и чертить сеть штрихом")

        let enough = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                      areas: pavement, areaBudget: 6,
                                      anchor: .init(latitude: 41.3, longitude: 69.25),
                                      spanMeters: 200)
        XCTAssertEqual(enough.areas.filter { $0.kind.isPavement }.count, 6)
        XCTAssertTrue(enough.hasPavement)
    }

    func testTerrainIsCutBeforeTheRoad() {
        // Когда мест меньше, чем фигур, уходит местность, а не асфальт.
        var mixed: [SketchArea] = (0..<3).map {
            SketchArea(points: ring(at: 41.3 + Double($0) * 0.0001, 69.25),
                       kind: .road, isClosed: true)
        }
        mixed += (0..<20).map {
            SketchArea(points: ring(at: 41.3 + Double($0) * 0.0001, 69.2505),
                       kind: .green, isClosed: true)
        }
        let scene = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                     areas: mixed, areaBudget: 6,
                                     anchor: .init(latitude: 41.3, longitude: 69.25),
                                     spanMeters: 200)
        XCTAssertEqual(scene.areas.filter { $0.kind == .road }.count, 3)
        XCTAssertEqual(scene.areas.count, 6)
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
        XCTAssertEqual(Set(far.areas.map(\.kind)), [.block, .water],
                       "на дальнем плане город держится кварталами — без них пустое поле")
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

    func testAreaBudgetKeepsLandmarksBeforeHouses() {
        // Бюджет местности режет по СЛОЯМ, а не по порядку массива. Массив
        // приезжает flatMap-ом по множеству тайлов, то есть его порядок —
        // порядок хеша: «первые N» означало бы «кто выжил, решил хеш». Река
        // исчезала бы через раз, вытесненная пачкой домов из тайла, который
        // просто оказался раньше в обходе.
        //
        // Заполняться бюджет начнёт ровно тогда, когда поедут дома: их 54 094
        // в одном кадре центра против четырёхсот мест в бюджете.
        var mixed: [SketchArea] = (0..<30).map {
            SketchArea(points: ring(at: 41.3 + Double($0) * 0.0001, 69.25),
                       kind: .house, isClosed: true)
        }
        mixed.append(SketchArea(points: ring(at: 41.3005, 69.2505),
                                kind: .water, isClosed: true))
        let scene = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                     areas: mixed, areaBudget: 5,
                                     anchor: .init(latitude: 41.3, longitude: 69.25),
                                     spanMeters: 150)
        XCTAssertEqual(scene.areas.count, 5)
        XCTAssertTrue(scene.areas.contains { $0.kind == .water },
                      "вода — ориентир, она обязана пережить дома")
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
                       RoadSketch.maxSpanMeters)
        for kind in SketchPoint.Kind.allCases
        where kind != .trafficLight && !kind.isPaint {
            XCTAssertEqual(kind.maxSpanMeters, RoadSketch.farNetworkSpan,
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
            XCTAssertLessThan(kind.maxSpanMeters, RoadSketch.farNetworkSpan,
                              "\(kind) — краска, она обязана гаснуть раньше сети")
        }
    }

    func testSceneKeepsOnlyMarksVisibleAtThisSpan() {
        let light = SketchPoint(coordinate: .init(latitude: 41.3005, longitude: 69.25),
                                kind: .trafficLight)
        let bump = SketchPoint(coordinate: .init(latitude: 41.3005, longitude: 69.25),
                               kind: .speedBump)
        let near = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                    points: [light, bump],
                                    anchor: .init(latitude: 41.3, longitude: 69.25),
                                    spanMeters: 200)
        XCTAssertEqual(Set(near.marks.map(\.kind)), [.trafficLight, .speedBump])

        let far = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                   points: [light, bump],
                                   anchor: .init(latitude: 41.3, longitude: 69.25),
                                   spanMeters: RoadSketch.farNetworkSpan + 1)
        XCTAssertEqual(Set(far.marks.map(\.kind)), [.trafficLight],
                       "на костяке района остаётся только светофор")
    }

    func testTheFarPointSetIsPointsToo() {
        // Два набора, одна распаковка: дальний отличается геометрией, а не
        // форматом. Перепутать их местами нельзя — они разные наборы.
        XCTAssertTrue(RoadTiles.Set.pointsFar.isPoints)
        XCTAssertFalse(RoadTiles.Set.pointsFar.isArea)
        XCTAssertNotEqual(RoadTiles.Set.pointsFar, RoadTiles.Set.points)
    }

    func testMarkBudgetCapsWhatEverArrivesInATile() {
        // Тайл приходит извне, а слой марок перерисовывается на тик: потолок
        // здесь предохранитель, а не оптимизация.
        let anchor = CLLocationCoordinate2D(latitude: 41.3, longitude: 69.25)
        let crowd = (0..<(RoadSketch.markBudget * 2)).map { i in
            SketchPoint(coordinate: .init(latitude: 41.3 + Double(i) * 1e-5,
                                          longitude: 69.25),
                        kind: .trafficLight)
        }
        let scene = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                     points: crowd, anchor: anchor, spanMeters: 200)
        XCTAssertGreaterThan(scene.marks.count, RoadSketch.markBudget,
                             "сцена не режет — режет слой отрисовки")
        XCTAssertEqual(scene.marks.prefix(RoadSketch.markBudget).count,
                       RoadSketch.markBudget)
    }
}

/// Источник, отдающий заранее известные линии: имя улицы — чистая функция, и
/// проверять её надо без сеточных индексов и кэшей.
private struct StubNetwork: RoadNetworkSource {
    let lines: [RoadLine]
    func roads(near coordinate: CLLocationCoordinate2D,
               radius: CLLocationDistance) -> [RoadLine] { lines }
}
