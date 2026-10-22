//
//  RoutePreviewTests.swift
//  RadarMapTests
//
//  Выбор маршрута на карте (27.D): касание линии выбирает вариант, на общем
//  отрезке выбор не прыгает; кадр «весь маршрут» ложится между панелями, а
//  не под карточку; подпись «24 мин» — там, где вариант отдельно от других.
//

import MapKit
import XCTest
@testable import RadarMap

final class RoutePreviewTests: XCTestCase {

    // MARK: - Касание линии

    /// Два варианта: общий старт, дальше один идёт вправо, другой — вниз.
    private let lines = [
        RoutePreview.Line(id: 0, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 300, y: 0)]),
        RoutePreview.Line(id: 1, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 300)]),
    ]

    func testDistanceToPolyline() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
        XCTAssertEqual(RoutePreview.distance(from: CGPoint(x: 5, y: 3), to: line), 3, accuracy: 1e-9)
        XCTAssertEqual(RoutePreview.distance(from: CGPoint(x: 13, y: 4), to: line), 5, accuracy: 1e-9,
                       "за концом — до конца, а не до продолжения")
        XCTAssertEqual(RoutePreview.distance(from: .zero, to: []), .infinity)
    }

    func testTapNearAnotherVariantSelectsIt() {
        XCTAssertEqual(RoutePreview.variant(at: CGPoint(x: 110, y: 200), lines: lines, selected: 0,
                                            threshold: 22, margin: 6), 1)
        XCTAssertEqual(RoutePreview.variant(at: CGPoint(x: 250, y: 15), lines: lines, selected: 1,
                                            threshold: 22, margin: 6), 0)
    }

    func testTapAwayFromEveryLineIsNothing() {
        XCTAssertNil(RoutePreview.variant(at: CGPoint(x: 250, y: 200), lines: lines, selected: 0,
                                          threshold: 22, margin: 6))
        XCTAssertNil(RoutePreview.variant(at: CGPoint(x: 140, y: 30), lines: lines, selected: 0,
                                          threshold: 22, margin: 6), "23+ pt от обеих — мимо")
    }

    /// Общий отрезок: касание — это выбранный, выбор не прыгает.
    func testSharedStretchKeepsTheSelection() {
        for selected in [0, 1] {
            XCTAssertEqual(RoutePreview.variant(at: CGPoint(x: 50, y: 4), lines: lines, selected: selected,
                                                threshold: 22, margin: 6), selected)
        }
    }

    /// Рядом с изломом, где линии расходятся: чуть ближе к чужой — ещё свой
    /// (в пределах запаса), заметно ближе — чужой.
    func testMarginDecidesNearTheFork() {
        // До линии 0 (y = 0) — 12, до линии 1 (x = 100) — 8: разница 4 < 6.
        XCTAssertEqual(RoutePreview.variant(at: CGPoint(x: 108, y: 12), lines: lines, selected: 0,
                                            threshold: 22, margin: 6), 0)
        // До 0 — 20, до 1 — 3: чужая явно ближе.
        XCTAssertEqual(RoutePreview.variant(at: CGPoint(x: 103, y: 20), lines: lines, selected: 0,
                                            threshold: 22, margin: 6), 1)
    }

    func testWithoutSelectionTheNearestWins() {
        XCTAssertEqual(RoutePreview.variant(at: CGPoint(x: 103, y: 20), lines: lines, selected: nil,
                                            threshold: 22, margin: 6), 1)
    }

    // MARK: - Поля кадра

    /// iPhone 17 Pro: панель сверху до 140 pt, карточка выбора снизу от 470 pt
    /// (высота 874). Поля — до панелей плюс зазор, справа — колонка кнопок.
    func testPaddingFollowsThePanels() {
        let p = RoutePreview.padding(width: 402, height: 874, panelTop: 140, panelBottom: 470,
                                     leading: 16, trailing: 64, margin: 28, minFree: 160)
        XCTAssertEqual(p.top, 168, accuracy: 1e-9)
        XCTAssertEqual(p.bottom, 874 - 470 + 28, accuracy: 1e-9)
        XCTAssertEqual(p.left, 30, accuracy: 1e-9)
        XCTAssertEqual(p.right, 78, accuracy: 1e-9)
    }

    /// Нижнюю панель ещё не мерили — не ноль: карточка выбора уже на экране.
    func testUnmeasuredBottomPanelReservesAShare() {
        let p = RoutePreview.padding(width: 402, height: 874, panelTop: 0, panelBottom: 0,
                                     leading: 16, trailing: 64, margin: 28, minFree: 160)
        XCTAssertEqual(p.bottom, 874 * AppConfig.routeOverviewFallbackBottomShare + 28, accuracy: 1e-9)
        XCTAssertEqual(p.top, 28, accuracy: 1e-9)
    }

    /// SE, три варианта и объявление сверху: на линию осталось бы 47 pt — поля
    /// ужимаются, и свободная высота не меньше `minFree`.
    func testTinyScreenKeepsRoomForTheLine() {
        let p = RoutePreview.padding(width: 375, height: 667, panelTop: 230, panelBottom: 330,
                                     leading: 16, trailing: 64, margin: 28, minFree: 160)
        XCTAssertGreaterThanOrEqual(667 - p.top - p.bottom, 160 - 1e-9)
        XCTAssertGreaterThan(p.top, 0)
        XCTAssertGreaterThan(p.bottom, 0)
        // Сначала ушли зазоры, потом панели — поровну по своей доле.
        XCTAssertLessThan(p.top, 230 + 8)
        XCTAssertLessThan(p.bottom, 667 - 330 + 8)
    }

    // MARK: - Кадр

    private func rect(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> MKMapRect {
        let pa = MKMapPoint(a), pb = MKMapPoint(b)
        return MKMapRect(x: min(pa.x, pb.x), y: min(pa.y, pb.y), width: abs(pa.x - pb.x), height: abs(pa.y - pb.y))
    }

    /// Вписанный маршрут — целиком в свободной части вида между панелями, и
    /// касается её края хотя бы по одной стороне (не мельче, чем нужно).
    func testFitPutsTheRouteBetweenThePanels() {
        let route = rect(CLLocationCoordinate2D(latitude: 41.2930, longitude: 69.2150),
                         CLLocationCoordinate2D(latitude: 41.3285, longitude: 69.3010))
        let padding = RoutePreview.Padding(top: 168, left: 30, bottom: 432, right: 78)
        let (w, h) = (402.0, 874.0)
        let fit = try! XCTUnwrap(RoutePreview.fit(route, width: w, height: h, padding: padding))
        let nw = RoutePreview.screenPoint(MKMapPoint(x: route.minX, y: route.minY), fit: fit, width: w, height: h)
        let se = RoutePreview.screenPoint(MKMapPoint(x: route.maxX, y: route.maxY), fit: fit, width: w, height: h)
        XCTAssertGreaterThanOrEqual(nw.x, padding.left - 0.5)
        XCTAssertGreaterThanOrEqual(nw.y, padding.top - 0.5)
        XCTAssertLessThanOrEqual(se.x, w - padding.right + 0.5)
        XCTAssertLessThanOrEqual(se.y, h - padding.bottom + 0.5)
        let touchesWidth = abs(nw.x - padding.left) < 0.5 && abs(se.x - (w - padding.right)) < 0.5
        let touchesHeight = abs(nw.y - padding.top) < 0.5 && abs(se.y - (h - padding.bottom)) < 0.5
        XCTAssertTrue(touchesWidth || touchesHeight, "кадр не мельче, чем нужно")
        // Центр маршрута — в центре свободной части, а не экрана.
        let mid = RoutePreview.screenPoint(MKMapPoint(x: route.midX, y: route.midY), fit: fit, width: w, height: h)
        XCTAssertEqual(mid.x, (padding.left + w - padding.right) / 2, accuracy: 0.5)
        XCTAssertEqual(mid.y, (padding.top + h - padding.bottom) / 2, accuracy: 0.5)
    }

    /// Строго с севера на юг — ширины нет, масштаб задаёт высота; точка —
    /// потолок масштаба, а не бесконечность.
    func testDegenerateRoutesStayFinite() {
        let northSouth = rect(CLLocationCoordinate2D(latitude: 41.30, longitude: 69.28),
                              CLLocationCoordinate2D(latitude: 41.34, longitude: 69.28))
        let padding = RoutePreview.Padding(top: 100, left: 20, bottom: 300, right: 60)
        let fit = try! XCTUnwrap(RoutePreview.fit(northSouth, width: 402, height: 874, padding: padding))
        XCTAssertTrue(fit.zoom.isFinite)
        XCTAssertLessThan(fit.zoom, AppConfig.routeOverviewMaxZoom)
        let point = MKMapRect(origin: MKMapPoint(CLLocationCoordinate2D(latitude: 41.3, longitude: 69.28)),
                              size: MKMapSize(width: 0, height: 0))
        XCTAssertEqual(RoutePreview.fit(point, width: 402, height: 874, padding: padding)?.zoom,
                       AppConfig.routeOverviewMaxZoom)
        XCTAssertNil(RoutePreview.fit(.null, width: 402, height: 874, padding: padding))
    }

    /// Масштаб — в единицах движка (тайл 512): 1 км по ширине 400 pt на
    /// экваторе — z ≈ 16,9 (40 075 км / (512 · 2^z) = 2,5 м на точку).
    func testZoomMatchesTheEngineScale() {
        let a = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let b = CLLocationCoordinate2D(latitude: 0, longitude: 1000 / 111_319.49)
        let fit = try! XCTUnwrap(RoutePreview.fit(rect(a, b), width: 400, height: 10_000,
                                                  padding: .init(top: 0, left: 0, bottom: 0, right: 0),
                                                  maxZoom: 22))
        XCTAssertEqual(fit.zoom, log2(40_075_016.686 * 400 / (512 * 1000)), accuracy: 0.01)
    }

    // MARK: - Подпись варианта

    /// Подпись — там, где вариант дальше всего от остальных, а не на общем
    /// начале; без соседей — середина линии.
    func testLabelSitsWhereTheVariantIsAlone() {
        func line(_ xy: [(Double, Double)]) -> [MKMapPoint] { xy.map { MKMapPoint(x: $0.0, y: $0.1) } }
        let a = line([(0, 0), (500, 0), (1000, 0)])
        let b = line([(0, 0), (200, 0), (500, 400), (800, 0), (1000, 0)])
        let label = try! XCTUnwrap(RoutePreview.labelPoint(of: 1, lines: [a, b]))
        XCTAssertGreaterThan(label.y, 300, "на отходе от общей линии, у вершины крюка")
        let own = try! XCTUnwrap(RoutePreview.labelPoint(of: 0, lines: [a]))
        XCTAssertEqual(own.x, 500, accuracy: 1)
        XCTAssertNil(RoutePreview.labelPoint(of: 3, lines: [a, b]))
    }

    /// Значок камеры лежит над подписью: на месте лучшей точки стоит камера —
    /// подпись отходит вдоль своей линии на порог, а не прячет цифру под
    /// значком («26 мин» читалось как «6 мин», снимки App Store 22.10).
    func testLabelStepsAwayFromACameraIcon() {
        func line(_ xy: [(Double, Double)]) -> [MKMapPoint] { xy.map { MKMapPoint(x: $0.0, y: $0.1) } }
        let a = line([(0, 0), (500, 0), (1000, 0)])
        let b = line([(0, 0), (200, 0), (500, 400), (800, 0), (1000, 0)])
        let free = try! XCTUnwrap(RoutePreview.labelPoint(of: 1, lines: [a, b]))
        let label = try! XCTUnwrap(RoutePreview.labelPoint(of: 1, lines: [a, b], avoid: [free]))
        let clearance = 1000 * AppConfig.routeVariantLabelCameraClearance
        XCTAssertGreaterThanOrEqual(hypot(label.x - free.x, label.y - free.y), clearance,
                                    "подпись ушла от значка на порог")
        XCTAssertGreaterThan(label.y, 150, "и осталась на отходе варианта, а не на общей линии")
        // Камера вдали от линий ничего не меняет.
        let far = try! XCTUnwrap(RoutePreview.labelPoint(of: 1, lines: [a, b],
                                                         avoid: [MKMapPoint(x: 5000, y: 5000)]))
        XCTAssertEqual(far.x, free.x, accuracy: 0.001)
        XCTAssertEqual(far.y, free.y, accuracy: 0.001)
    }

    /// Камеры на каждой точке-кандидате — подпись всё равно есть (прежний
    /// выбор): спрятать время варианта хуже, чем положить его под значок.
    func testLabelSurvivesCamerasEverywhere() {
        func line(_ xy: [(Double, Double)]) -> [MKMapPoint] { xy.map { MKMapPoint(x: $0.0, y: $0.1) } }
        let a = line([(0, 0), (500, 0), (1000, 0)])
        let b = line([(0, 0), (200, 0), (500, 400), (800, 0), (1000, 0)])
        let free = try! XCTUnwrap(RoutePreview.labelPoint(of: 1, lines: [a, b]))
        let everywhere = RoutePreview.sampled(b, from: 0, to: 1, count: 400)
        let label = try! XCTUnwrap(RoutePreview.labelPoint(of: 1, lines: [a, b], avoid: everywhere))
        XCTAssertEqual(label.x, free.x, accuracy: 0.001)
        XCTAssertEqual(label.y, free.y, accuracy: 0.001)
    }

    #if canImport(MapLibre)
    /// Подпись «24 мин» встаёт под первую метку приложения — то есть над всеми
    /// подписями основы (их раскладка идёт после и обходит подпись) и под
    /// камерами. Якорь обязан быть нижним слоем меток, иначе какая-то метка
    /// окажется под подписью.
    func testVariantLabelsAnchorBelowEveryMarkerLayer() {
        let markers = EngineMapStyle.markerLayers(label: "#000000", halo: "#ffffff").compactMap { $0["id"] as? String }
        XCTAssertEqual(EngineRouteVariants.markerLayerIDs.first, markers.first,
                       "якорь — самый нижний слой меток")
        let cameraLayers = markers.filter { $0.hasPrefix("camera-") }
        let anchorIndex = try! XCTUnwrap(markers.firstIndex(of: EngineRouteVariants.markerLayerIDs[0]))
        for camera in cameraLayers {
            XCTAssertGreaterThan(try! XCTUnwrap(markers.firstIndex(of: camera)), anchorIndex,
                                 "\(camera) выше подписи варианта")
        }
    }
    #endif

    func testThinningKeepsTheEnds() {
        let long = (0...999).map { MKMapPoint(x: Double($0), y: 0) }
        let thin = RoutePreview.thinned(long, limit: 10)
        XCTAssertEqual(thin.count, 10)
        XCTAssertEqual(thin.first?.x, 0)
        XCTAssertEqual(thin.last?.x, 999)
    }

    // MARK: - Цвет времени

    /// Один цвет на телефон и машину; без данных — не «зелёный».
    func testTrafficToneIsShared() {
        XCTAssertEqual(RoutePreview.trafficTone(delay: nil), .unknown)
        XCTAssertEqual(RoutePreview.trafficTone(delay: 60), .free)
        XCTAssertEqual(RoutePreview.trafficTone(delay: AppConfig.routeTrafficNoticeSeconds), .slow)
        XCTAssertEqual(RoutePreview.trafficTone(delay: AppConfig.routeTrafficHeavySeconds), .heavy)
        XCTAssertEqual(CarPlayTripPreview.timeColor(trafficDelay: 11 * 60), .orange,
                       "11 мин — янтарь и в машине, как в карточке телефона")
    }
}
