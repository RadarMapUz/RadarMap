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
