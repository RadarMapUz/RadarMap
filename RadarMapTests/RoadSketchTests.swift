//
//  RoadSketchTests.swift
//  RadarMapTests
//
//  Схема на приборке. Первый тест здесь появился не из головы: схема на
//  симуляторе нарисовала дорогу ПОПЕРЁК экрана, хотя мы по ней ехали, —
//  в повороте был перепутан знак угла. Ошибка чисто арифметическая и видна
//  только глазами или тестом; пусть будет тестом.
//
//  После перехода на «север вверху + transform» поворот живёт в
//  RoadSketch.screenPoint — функции, обязанной совпадать с transform'ами
//  вью, — а сцена собирается без курса вовсе. Тесты покрывают обе половины
//  и решение «когда пересобирать растр»: экономия тиков и есть архитектура.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class RoadSketchTests: XCTestCase {

    private let me = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.25)

    /// Камера в `metres` от `me` по азимуту `bearing` (градусы от севера).
    private func camera(id: Int = 1, metres: Double, bearing: Double,
                        road: [Int]? = nil, axis: Int? = nil) -> Camera {
        let angle = bearing * .pi / 180
        let north = cos(angle) * metres, east = sin(angle) * metres
        let lat = me.latitude + north / 111_320
        let lon = me.longitude + east / (111_320 * cos(me.latitude * .pi / 180))
        return Camera(id: id, region: "Тест", city: "Тест", location: "Тест",
                      lat: lat, lon: lon, type: "Стационар радар",
                      violations: [], needsReview: nil, axis: axis, road: road)
    }

    /// Точка сцены в `metres` по азимуту `bearing` от опоры.
    private func scenePoint(metres: Double, bearing: Double) -> CGPoint {
        let angle = bearing * .pi / 180
        return CGPoint(x: sin(angle) * metres, y: cos(angle) * metres)
    }

    // MARK: - Поворот «по ходу движения» (screenPoint == transform'ы вью)

    func testCameraStraightAheadLandsDirectlyAbove() {
        // Точка ровно по курсу обязана оказаться строго над стрелкой. С
        // перепутанным знаком угла поворот давал x = d·sin(2·курс), и на
        // курсе 45° камеру уносило вбок.
        for course in [0.0, 45, 90, 135, 180, 225, 270, 315] {
            let screen = RoadSketch.screenPoint(scenePoint(metres: 200, bearing: course),
                                                meOffset: .zero, courseDegrees: course,
                                                spanMeters: 300, aspect: 1)
            XCTAssertEqual(screen.x, 0.5, accuracy: 0.01,
                           "курс \(course)°: точка по курсу должна быть строго вверху")
            XCTAssertLessThan(screen.y, RoadSketch.meY,
                              "курс \(course)°: точка впереди — значит выше меня")
        }
    }

    func testPointOnTheRightLandsOnTheRight() {
        // Едем на север, точка на востоке — она справа.
        let screen = RoadSketch.screenPoint(scenePoint(metres: 150, bearing: 90),
                                            meOffset: .zero, courseDegrees: 0,
                                            spanMeters: 300, aspect: 1)
        XCTAssertGreaterThan(screen.x, 0.5)
    }

    func testPointBehindLandsBelow() {
        let screen = RoadSketch.screenPoint(scenePoint(metres: 150, bearing: 180),
                                            meOffset: .zero, courseDegrees: 0,
                                            spanMeters: 300, aspect: 1)
        XCTAssertGreaterThan(screen.y, RoadSketch.meY, "точка позади — ниже стрелки")
    }

    // MARK: - Курс: разматывание и честность

    func testNoCourseEverMeansNoOrientation() {
        // Курса не было ни разу: повернуть схему наугад значило бы соврать
        // направлением (прежде это была honesty-ветка layout == nil).
        XCTAssertNil(RoadSketch.unwound(nil, towards: -1))
        // Стоим: держим прошлый курс — мы никуда не повернули.
        XCTAssertEqual(RoadSketch.unwound(90, towards: -1), 90)
    }

    func testCourseUnwindsAcrossNorth() {
        // 359° → 1° — это поворот на +2°, а не на −358°: анимация
        // интерполирует градусы как есть, и без разматывания схему
        // крутануло бы на полный оборот.
        XCTAssertEqual(RoadSketch.unwound(359, towards: 1) ?? 0, 361, accuracy: 0.001)
        XCTAssertEqual(RoadSketch.unwound(1, towards: 359) ?? 0, -1, accuracy: 0.001)
    }

    // MARK: - Охват и честность

    func testSpanIsClamped() {
        XCTAssertEqual(RoadSketch.span(forDistance: 30), RoadSketch.minSpanMeters,
                       "вблизи масштаб не раздуваем — схема дёргалась бы от шума GPS")
        XCTAssertEqual(RoadSketch.span(forDistance: 4000), RoadSketch.maxSpanMeters)
        XCTAssertEqual(RoadSketch.span(forDistance: nil), RoadSketch.minSpanMeters)
    }

    func testDistantCameraIsNotDrawnAtAll() {
        // Четыре километра: схема отвечает на вопрос «где камера относительно
        // меня и моей дороги», а он осмыслен только вблизи. Показать камеру у
        // края значило бы соврать масштабом, дотянуть к ней дорогу — геометрией.
        let span = RoadSketch.span(forDistance: 4000)
        XCTAssertFalse(RoadSketch.isInRange(distance: 4000, span: span))
        let scene = RoadSketch.scene(alertCamera: camera(metres: 4000, bearing: 0),
                                     alertInRange: false, anchor: me, spanMeters: span)
        XCTAssertNil(scene.alertCamera)
        XCTAssertTrue(scene.road.isEmpty,
                      "дорога далёкой камеры не рисуется — её тут нет")
    }

    func testMeasuredRoadIsMarkedAsSuch() {
        // Кусок дороги из базы — дельты в 1e-6° от координаты камеры.
        let withRoad = camera(metres: 200, bearing: 0, road: [0, -900, 0, 900])
        let measured = RoadSketch.scene(alertCamera: withRoad, alertInRange: true,
                                        anchor: me, spanMeters: 300)
        XCTAssertTrue(measured.roadIsMeasured)
        XCTAssertGreaterThanOrEqual(measured.road.count, 2)

        // Куска нет — чертим ось, и она помечена как предположение.
        let guessed = RoadSketch.scene(alertCamera: camera(metres: 200, bearing: 0, axis: 90),
                                       alertInRange: true, anchor: me, spanMeters: 300)
        XCTAssertFalse(guessed.roadIsMeasured)
        XCTAssertFalse(guessed.road.isEmpty, "ось всё же чертим, но бледнее")

        // Нет ни куска, ни оси — не выдумываем ничего.
        let nothing = RoadSketch.scene(alertCamera: camera(metres: 200, bearing: 0),
                                       alertInRange: true, anchor: me, spanMeters: 300)
        XCTAssertTrue(nothing.road.isEmpty)
    }

    // MARK: - Ступени масштаба и пересборка растра

    func testBucketStaysWithinOneStepBelowSpan() {
        for span in stride(from: 140.0, through: 700, by: 7) {
            let bucket = RoadSketch.bucket(forSpan: span)
            XCTAssertLessThanOrEqual(bucket, span + 0.001,
                                     "ступень выше охвата = scaleEffect растянул бы растр")
            XCTAssertGreaterThan(bucket, span / RoadSketch.bucketRatio - 0.001)
        }
        XCTAssertEqual(RoadSketch.bucket(forSpan: RoadSketch.minSpanMeters),
                       RoadSketch.minSpanMeters)
    }

    func testRebuildOnlyOnDriftOrDataChange() {
        let key = RoadSketch.RebuildKey(spanBucket: RoadSketch.minSpanMeters)
        let scene = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                     anchor: me, spanMeters: RoadSketch.minSpanMeters)
        // Сцены ещё нет — собрать.
        XCTAssertTrue(RoadSketch.needsRebuild(scene: nil, key: key, previousKey: key,
                                              meOffsetMeters: .zero))
        // Тот же ключ, лёгкий дрейф — растр живёт: в этом вся экономия.
        XCTAssertFalse(RoadSketch.needsRebuild(scene: scene, key: key, previousKey: key,
                                               meOffsetMeters: CGPoint(x: 40, y: 40)))
        // Уехали от опоры — пересборка.
        XCTAssertTrue(RoadSketch.needsRebuild(scene: scene, key: key, previousKey: key,
                                              meOffsetMeters: CGPoint(x: 0, y: 120)))
        // Сменилась тревожная камера — пересборка (её дорога в растре).
        var flipped = key
        flipped.alertCameraID = 7
        flipped.alertInRange = true
        XCTAssertTrue(RoadSketch.needsRebuild(scene: scene, key: flipped, previousKey: key,
                                              meOffsetMeters: .zero))
    }

    func testScaleBarPicksRoundNumbers() {
        XCTAssertEqual(RoadSketch.scaleBarMeters(forSpan: 140), 50)
        XCTAssertEqual(RoadSketch.scaleBarMeters(forSpan: 700), 300)
    }

    // MARK: - Все камеры охвата

    func testIntersectionShowsAllFourCameras() {
        // Ферганский чорраха Al.ferganiy—Sayilgoh: четыре камеры (443–446) в
        // сотне метров друг от друга, подпись у всех одна. Схема с
        // единственной точкой прятала три из них.
        let four = [camera(id: 443, metres: 80, bearing: 44),
                    camera(id: 444, metres: 40, bearing: 224),
                    camera(id: 445, metres: 60, bearing: 134),
                    camera(id: 446, metres: 60, bearing: 314)]
        let scene = RoadSketch.scene(alertCamera: four[0], alertInRange: true,
                                     cameras: four, anchor: me, spanMeters: 300)
        XCTAssertEqual(scene.cameras.count, 4, "все камеры чорраха — на схеме")
        XCTAssertEqual(scene.alertCameraID, 443)
        XCTAssertNotNil(scene.alertCamera)
    }

    func testAlertCameraDotIsGuaranteed() {
        // Фильтр вида или лимит выборки могли не включить тревожную камеру
        // в список — но её точка обязана быть: о ней прямо сейчас кричим.
        let scene = RoadSketch.scene(alertCamera: camera(metres: 150, bearing: 0),
                                     alertInRange: true, cameras: [],
                                     anchor: me, spanMeters: 300)
        XCTAssertEqual(scene.cameras.count, 1)
        XCTAssertNotNil(scene.alertCamera)
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
        let myPlace = GeoMath.destination(from: real.coordinate, bearing: 224,
                                          distanceMeters: 38)
        let span = RoadSketch.span(forDistance: 38)
        let scene = RoadSketch.scene(alertCamera: real, alertInRange: true,
                                     cameras: [real], anchor: myPlace,
                                     spanMeters: span)
        guard scene.road.count >= 2 else {
            return XCTFail("дорога камеры не собралась")
        }
        func screen(_ point: CGPoint) -> CGPoint {
            RoadSketch.screenPoint(point, meOffset: .zero, courseDegrees: 44,
                                   spanMeters: span, aspect: 16.0 / 9.0)
        }
        let first = screen(scene.road.first!), last = screen(scene.road.last!)
        XCTAssertGreaterThan(abs(last.y - first.y), abs(last.x - first.x) * 2,
                             "дорога вдоль курса легла поперёк экрана: \(first) → \(last)")
        // Камера прямо по курсу — строго над стрелкой.
        let dot = try? XCTUnwrap(scene.alertCamera)
        XCTAssertEqual(screen(dot ?? .zero).x, 0.5, accuracy: 0.03)
    }

    // MARK: - Окрестная сеть и её бюджет

    /// Заглушка источника: отдаёт заготовленные линии, без сеточного индекса.
    private struct StubNetwork: RoadNetworkSource {
        var lines: [RoadLine]
        func roads(near coordinate: CLLocationCoordinate2D,
                   radius: CLLocationDistance) -> [RoadLine] { lines }
    }

    /// Поперечная улица (восток—запад) в `metresAhead` от опоры, точки каждые 25 м.
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
        let scene = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                     network: network, networkBudget: 1,
                                     anchor: me, spanMeters: 140)
        XCTAssertEqual(scene.network.count, 1)
        XCTAssertEqual(scene.network.first?.kind, .residential,
                       "в бюджет обязана попасть БЛИЖНЯЯ к машине линия")
    }

    func testZeroBudgetCutsNetworkButNeverCameraRoad() {
        // .minimal: сеть — украшение и уходит первой; дорога камеры — нет.
        let withRoad = camera(metres: 200, bearing: 0, road: [0, -900, 0, 900])
        let street = crossStreet(metresAhead: 50, kind: .primary)
        let scene = RoadSketch.scene(alertCamera: withRoad, alertInRange: true,
                                     network: StubNetwork(lines: [street]),
                                     networkBudget: 0,
                                     anchor: me, spanMeters: 300)
        XCTAssertTrue(scene.network.isEmpty)
        XCTAssertFalse(scene.road.isEmpty,
                       "дорога камеры не режется ни на одной ступени")
    }

    func testLineBeyondRasterIsDropped() {
        // Улица дальше радиуса сцены: хранить и гнать её в растр — работа
        // без единого пикселя. Радиус при охвате 140 — ~317 м.
        let network = StubNetwork(lines: [crossStreet(metresAhead: 400, kind: .primary),
                                          crossStreet(metresAhead: 40, kind: .secondary)])
        let scene = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                     network: network,
                                     anchor: me, spanMeters: 140)
        XCTAssertEqual(scene.network.count, 1,
                       "линия целиком за растром не хранится вовсе")
        XCTAssertEqual(scene.network.first?.kind, .secondary)
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

    // MARK: - Ритм анимации (плавность = длительность по реальному интервалу)

    /// Родился из реальной поездки: константа в 1 с при фиксах раз в 2–3 с
    /// давала «секунду едет, две стоит».
    func testAnimationDurationFollowsTickRhythm() {
        XCTAssertEqual(TickPacing.animationDuration(sincePreviousTick: nil), 1)
        XCTAssertEqual(TickPacing.animationDuration(sincePreviousTick: 0.1), 0.35)
        XCTAssertEqual(TickPacing.animationDuration(sincePreviousTick: 2.2), 2.2)
        XCTAssertEqual(TickPacing.animationDuration(sincePreviousTick: 30), 3,
                       "после паузы догонять дольше трёх секунд — врать о том, где мы")
    }

    // MARK: - Мелкие улицы: видны, только когда мы на такой

    private func detailedStreet(metresAhead: Double, kind: RoadClass) -> RoadLine {
        var line = crossStreet(metresAhead: metresAhead, kind: kind)
        line.isDetailed = true
        return line
    }

    func testMinorStreetsHiddenUnlessDrivingOnOne() {
        let network = StubNetwork(lines: [
            detailedStreet(metresAhead: 100, kind: .primary),
            detailedStreet(metresAhead: 60, kind: .service),
        ])
        let hidden = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                      network: network, showMinorRoads: false,
                                      anchor: me, spanMeters: 300)
        XCTAssertEqual(hidden.network.count, 1)
        XCTAssertEqual(hidden.network.first?.kind, .primary)

        let shown = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                     network: network, showMinorRoads: true,
                                     anchor: me, spanMeters: 300)
        XCTAssertEqual(shown.network.count, 2)
    }

    /// Индекс лимитов классов не знает — прятать то, чего не знаешь, нельзя.
    func testUndetailedSourceIsNeverFiltered() {
        let network = StubNetwork(lines: [crossStreet(metresAhead: 60, kind: .unknown)])
        let scene = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                     network: network, showMinorRoads: false,
                                     anchor: me, spanMeters: 300)
        XCTAssertEqual(scene.network.count, 1)
    }

    func testPrefersMinorRoadsOnlyWhenClosestRoadIsMinor() {
        // Едем по дворовой: она в 5 м, проспект в 100 м — мелочь показываем.
        let onMinor = StubNetwork(lines: [
            detailedStreet(metresAhead: 5, kind: .service),
            detailedStreet(metresAhead: 100, kind: .primary),
        ])
        XCTAssertTrue(RoadSketch.prefersMinorRoads(network: onMinor, at: me))

        // Едем по проспекту, дублёр в 20 м сбоку — решает ближняя дорога.
        let onMajor = StubNetwork(lines: [
            detailedStreet(metresAhead: 3, kind: .primary),
            detailedStreet(metresAhead: 20, kind: .service),
        ])
        XCTAssertFalse(RoadSketch.prefersMinorRoads(network: onMajor, at: me))

        // Источник без классов: судить не по чему, мелочь не включаем.
        let vague = StubNetwork(lines: [crossStreet(metresAhead: 5, kind: .unknown)])
        XCTAssertFalse(RoadSketch.prefersMinorRoads(network: vague, at: me))
    }

    /// Камера прячется ВМЕСТЕ со своей мелкой улицей (точка в пустоте читается
    /// как ошибка карты) — но тревожная рисуется всегда, что бы ни было
    /// спрятано: это картинка, а не оповещение.
    func testCameraOnMinorStreetHidesWithItsStreet() {
        let onService = Camera(id: 5, region: "Т", city: "", location: "двор",
                               lat: me.latitude + 100 / 111_320, lon: me.longitude,
                               type: "Стационар радар", violations: [],
                               needsReview: nil, cls: "service")
        let hidden = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                      cameras: [onService], showMinorRoads: false,
                                      anchor: me, spanMeters: 300)
        XCTAssertTrue(hidden.cameras.isEmpty)

        let shown = RoadSketch.scene(alertCamera: nil, alertInRange: false,
                                     cameras: [onService], showMinorRoads: true,
                                     anchor: me, spanMeters: 300)
        XCTAssertEqual(shown.cameras.count, 1)

        let alerting = RoadSketch.scene(alertCamera: onService, alertInRange: true,
                                        cameras: [onService], showMinorRoads: false,
                                        anchor: me, spanMeters: 300)
        XCTAssertEqual(alerting.cameras.map(\.id), [5],
                       "тревожная камера обязана рисоваться, что бы ни пряталось")
    }

    // MARK: - Гейт неподвижности

    /// Стоя на светофоре (дрожание GPS меньше порога) точка зрения не пишется
    /// вовсе — композитор не получает ни кадра работы на самом дешёвом экране.
    func testStandstillSkipsViewpointWrites() {
        XCTAssertFalse(RoadSketch.viewpointMoved(offsetDeltaMeters: 1.2,
                                                 courseDeltaDegrees: 0.8,
                                                 spanChanged: false))
        XCTAssertFalse(RoadSketch.viewpointMoved(offsetDeltaMeters: 0,
                                                 courseDeltaDegrees: 0,
                                                 spanChanged: false))
    }

    /// Любое настоящее изменение — сдвиг, поворот или смена охвата — двигает
    /// точку зрения: гейт экономит стоянку, а не съедает движение.
    func testRealMotionPassesTheGate() {
        XCTAssertTrue(RoadSketch.viewpointMoved(offsetDeltaMeters: 2.5,
                                                courseDeltaDegrees: 0,
                                                spanChanged: false))
        XCTAssertTrue(RoadSketch.viewpointMoved(offsetDeltaMeters: 0,
                                                courseDeltaDegrees: 2.4,
                                                spanChanged: false))
        // Охват сменился (камера вошла в радиус) — зум обязан отработать,
        // даже когда машина стоит.
        XCTAssertTrue(RoadSketch.viewpointMoved(offsetDeltaMeters: 0,
                                                courseDeltaDegrees: 0,
                                                spanChanged: true))
    }
}
