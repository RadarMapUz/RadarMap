//
//  RoadSketchTests.swift
//  RadarMapTests
//
//  Схема на приборке. Первый тест здесь появился не из головы: схема на
//  симуляторе нарисовала дорогу ПОПЕРЁК экрана, хотя мы по ней ехали, —
//  в повороте был перепутан знак угла. Ошибка чисто арифметическая и видна
//  только глазами или тестом; пусть будет тестом.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class RoadSketchTests: XCTestCase {

    private let me = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.25)

    /// Камера в `metres` от меня по азимуту `bearing` (градусы от севера).
    private func camera(metres: Double, bearing: Double, road: [Int]? = nil,
                        axis: Int? = nil) -> Camera {
        let angle = bearing * .pi / 180
        let north = cos(angle) * metres, east = sin(angle) * metres
        let lat = me.latitude + north / 111_320
        let lon = me.longitude + east / (111_320 * cos(me.latitude * .pi / 180))
        return Camera(id: 1, region: "Тест", city: "Тест", location: "Тест",
                      lat: lat, lon: lon, type: "Стационар радар",
                      violations: [], needsReview: nil, axis: axis, road: road)
    }

    // MARK: - Поворот «по ходу движения»

    func testCameraStraightAheadLandsDirectlyAbove() {
        // Едем на северо-восток, камера ровно по курсу. Она обязана оказаться
        // строго над стрелкой. С перепутанным знаком угла поворот давал
        // x = d·sin(2·курс), и на курсе 45° камеру уносило вбок.
        for course in [0.0, 45, 90, 135, 180, 225, 270, 315] {
            let layout = RoadSketch.layout(camera: camera(metres: 200, bearing: course),
                                           from: me, courseDegrees: course, aspect: 1)
            guard let point = layout?.camera else {
                return XCTFail("курс \(course)°: камеру не разложили")
            }
            XCTAssertEqual(point.x, 0.5, accuracy: 0.01,
                           "курс \(course)°: камера по курсу должна быть строго вверху")
            XCTAssertLessThan(point.y, RoadSketch.meY,
                              "курс \(course)°: камера впереди — значит выше меня")
        }
    }

    func testCameraOnTheRightLandsOnTheRight() throws {
        // Едем на север, камера на востоке — она справа.
        let layout = RoadSketch.layout(camera: camera(metres: 150, bearing: 90),
                                       from: me, courseDegrees: 0, aspect: 1)
        let point = try XCTUnwrap(layout?.camera)
        XCTAssertGreaterThan(point.x, 0.5)
    }

    func testCameraBehindLandsBelow() throws {
        let layout = RoadSketch.layout(camera: camera(metres: 150, bearing: 180),
                                       from: me, courseDegrees: 0, aspect: 1)
        let point = try XCTUnwrap(layout?.camera)
        XCTAssertGreaterThan(point.y, RoadSketch.meY, "камера позади — ниже стрелки")
    }

    // MARK: - Честность

    func testNoLayoutWithoutCourse() {
        // Стоим: «по ходу движения» не определено, и повернуть схему наугад
        // значило бы соврать направлением.
        XCTAssertNil(RoadSketch.layout(camera: camera(metres: 200, bearing: 0),
                                       from: me, courseDegrees: -1, aspect: 1))
    }

    func testDistantCameraIsNotDrawnAtAll() {
        // Четыре километра: схема отвечает на вопрос «где камера относительно
        // меня и моей дороги», а он осмыслен только вблизи. Показать камеру у
        // края значило бы соврать масштабом, дотянуть к ней дорогу — геометрией.
        let layout = RoadSketch.layout(camera: camera(metres: 4000, bearing: 0),
                                       from: me, courseDegrees: 0, aspect: 1)
        XCTAssertNil(layout?.camera)
        XCTAssertTrue(layout?.road.isEmpty ?? false,
                      "дорога далёкой камеры не рисуется — её тут нет")
    }

    func testSpanIsClamped() {
        let near = RoadSketch.layout(camera: camera(metres: 30, bearing: 0),
                                     from: me, courseDegrees: 0, aspect: 1)
        XCTAssertEqual(near?.spanMeters, RoadSketch.minSpanMeters,
                       "вблизи масштаб не раздуваем — схема дёргалась бы от шума GPS")
        let far = RoadSketch.layout(camera: camera(metres: 4000, bearing: 0),
                                    from: me, courseDegrees: 0, aspect: 1)
        XCTAssertEqual(far?.spanMeters, RoadSketch.maxSpanMeters)
    }

    func testMeasuredRoadIsMarkedAsSuch() {
        // Кусок дороги из базы — дельты в 1e-6° от координаты камеры.
        let withRoad = camera(metres: 200, bearing: 0, road: [0, -900, 0, 900])
        let layout = RoadSketch.layout(camera: withRoad, from: me,
                                       courseDegrees: 0, aspect: 1)
        XCTAssertTrue(layout?.roadIsMeasured ?? false)
        XCTAssertGreaterThanOrEqual(layout?.road.count ?? 0, 2)

        // Куска нет — чертим ось, и она помечена как предположение.
        let guessed = RoadSketch.layout(camera: camera(metres: 200, bearing: 0, axis: 90),
                                        from: me, courseDegrees: 0, aspect: 1)
        XCTAssertFalse(guessed?.roadIsMeasured ?? true)
        XCTAssertFalse(guessed?.road.isEmpty ?? true, "ось всё же чертим, но бледнее")

        // Нет ни куска, ни оси — не выдумываем ничего.
        let nothing = RoadSketch.layout(camera: camera(metres: 200, bearing: 0),
                                        from: me, courseDegrees: 0, aspect: 1)
        XCTAssertTrue(nothing?.road.isEmpty ?? false)
    }

    // MARK: - Боевые данные

    func testRealCamera443RoadRendersAlongCourse() {
        // Камера 443 (Фергана, Al.ferganiy—Sayilgoh) с её настоящим куском
        // дороги из базы v10: один сегмент с азимутом 43,5°. Едем по этой же
        // дороге курсом 44° в 38 м от камеры — на схеме её дорога обязана
        // лечь ВДОЛЬ экрана (почти вертикально), а не поперёк.
        let real = Camera(id: 443, region: "Farg‘ona viloyati", city: "Farg‘ona",
                          location: "Al.ferganiy - Sayilgoh", lat: 40.383938,
                          lon: 71.782891, type: "Интеллектуал + радар",
                          violations: [], needsReview: nil, axis: 44,
                          road: [-653, -816, 215, 265])
        let me = GeoMath.destination(from: real.coordinate, bearing: 224,
                                     distanceMeters: 38)
        let layout = RoadSketch.layout(camera: real, from: me,
                                       courseDegrees: 44, aspect: 16.0 / 9.0)
        guard let layout, layout.road.count >= 2 else {
            return XCTFail("дорога камеры не разложилась")
        }
        let first = layout.road.first!, last = layout.road.last!
        // По вертикали (в долях вида) дорога должна тянуться заметно сильнее,
        // чем по горизонтали: вид шире, чем выше, так что для линии «вдоль»
        // |Δy| больше |Δx| с запасом.
        XCTAssertGreaterThan(abs(last.y - first.y), abs(last.x - first.x) * 2,
                             "дорога вдоль курса легла поперёк экрана: \(first) → \(last)")
        // Камера прямо по курсу — строго над стрелкой.
        XCTAssertEqual(layout.camera?.x ?? 0, 0.5, accuracy: 0.03)
    }

    // MARK: - Окрестная сеть и её бюджет

    /// Заглушка источника: отдаёт заготовленные линии, без сеточного индекса.
    private struct StubNetwork: RoadNetworkSource {
        var lines: [RoadLine]
        func roads(near coordinate: CLLocationCoordinate2D,
                   radius: CLLocationDistance) -> [RoadLine] { lines }
    }

    /// Поперечная улица (восток—запад) в `metresAhead` от меня, точки каждые 25 м.
    private func crossStreet(metresAhead: Double, kind: RoadClass) -> RoadLine {
        let metersPerLon = 111_320 * cos(me.latitude * .pi / 180)
        let points = stride(from: -75.0, through: 75.0, by: 25.0).map {
            CLLocationCoordinate2D(latitude: me.latitude + metresAhead / 111_320,
                                   longitude: me.longitude + $0 / metersPerLon)
        }
        return RoadLine(points: points, kind: kind)
    }

    func testNetworkBudgetKeepsNearestLines() {
        // Две поперечные улицы: в 20 м и в 100 м. Бюджет на одну — выживает
        // ближняя: именно она объясняет, что у машины под колёсами.
        let network = StubNetwork(lines: [crossStreet(metresAhead: 100, kind: .primary),
                                          crossStreet(metresAhead: 20, kind: .residential)])
        let layout = RoadSketch.layout(camera: nil, network: network, networkBudget: 1,
                                       from: me, courseDegrees: 0, aspect: 1)
        XCTAssertEqual(layout?.network.count, 1)
        XCTAssertEqual(layout?.network.first?.kind, .residential,
                       "в бюджет обязана попасть БЛИЖНЯЯ к машине линия")
    }

    func testZeroBudgetCutsNetworkButNeverCameraRoad() {
        // .minimal: сеть — украшение и уходит первой; дорога камеры — нет.
        let withRoad = camera(metres: 200, bearing: 0, road: [0, -900, 0, 900])
        let street = crossStreet(metresAhead: 50, kind: .primary)
        let layout = RoadSketch.layout(camera: withRoad,
                                       network: StubNetwork(lines: [street]),
                                       networkBudget: 0,
                                       from: me, courseDegrees: 0, aspect: 1)
        XCTAssertTrue(layout?.network.isEmpty ?? false)
        XCTAssertFalse(layout?.road.isEmpty ?? true,
                       "дорога камеры не режется ни на одной ступени")
    }

    func testOffscreenLineIsDropped() {
        // Улица в 60 м ПОЗАДИ лежит за нижним краем вида (я стою на 0.78
        // высоты): хранить и гнать её в Canvas — работа без единого пикселя.
        let network = StubNetwork(lines: [crossStreet(metresAhead: -60, kind: .primary),
                                          crossStreet(metresAhead: 40, kind: .secondary)])
        let layout = RoadSketch.layout(camera: nil, network: network,
                                       from: me, courseDegrees: 0, aspect: 1)
        XCTAssertEqual(layout?.network.count, 1,
                       "линия целиком за краями вида не рисуется вовсе")
        XCTAssertEqual(layout?.network.first?.kind, .secondary)
    }

    /// Считает обращения к настоящему источнику. Только для тестов и только
    /// с одного потока — потому и @unchecked.
    private final class CountingNetwork: RoadNetworkSource, @unchecked Sendable {
        var calls = 0
        func roads(near coordinate: CLLocationCoordinate2D,
                   radius: CLLocationDistance) -> [RoadLine] {
            calls += 1
            return []
        }
    }

    func testCachedNetworkQueriesOncePerNeighbourhood() {
        // Два километра пути тиками по 20 м. Без кэша — сто сеточных запросов,
        // с кэшем — раз в ~200 м (полуторный запас на радиусе 400 м).
        let counting = CountingNetwork()
        let cached = CachedRoadNetwork(counting)
        for tick in 0..<100 {
            _ = cached.roads(near: .init(latitude: me.latitude + Double(tick) * 20 / 111_320,
                                         longitude: me.longitude),
                             radius: 400)
        }
        XCTAssertLessThan(counting.calls, 15,
                          "кэш окрестности обязан гасить подавляющую часть запросов")
        XCTAssertGreaterThan(counting.calls, 1,
                             "но по мере движения — честно обновляться")
    }

    // MARK: - Продление куска

    func testExtensionKeepsDirection() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 10)]
        let extended = RoadSketch.extended(line, toReach: 5)
        XCTAssertEqual(extended.count, 4)
        XCTAssertEqual(extended.first?.y ?? 0, -5, accuracy: 0.001)
        XCTAssertEqual(extended.last?.y ?? 0, 15, accuracy: 0.001)
        XCTAssertEqual(extended.first?.x ?? 1, 0, accuracy: 0.001, "направление не должно уводить")
    }

    func testShortInputIsLeftAlone() {
        XCTAssertEqual(RoadSketch.extended([CGPoint(x: 1, y: 1)], toReach: 10).count, 1)
        XCTAssertTrue(RoadSketch.extended([], toReach: 10).isEmpty)
    }
}
