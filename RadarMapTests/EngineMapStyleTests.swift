//
//  EngineMapStyleTests.swift
//  RadarMapTests
//
//  Стиль карты на движке — единственное место, где наши данные встречаются с
//  чужим рендером. Ошибка здесь не падает и не логируется: стиль остаётся
//  валидным, а карта — пустой.
//
//  Первый же прогон это и поймал: адреса тайлов собирались через
//  appendingPathComponent, а он кодирует фигурные скобки, и движок уходил за
//  «mvt/%7Bz%7D/%7Bx%7D/%7By%7D.mvt». Тест написан раньше, чем карта уехала на
//  телефон, поэтому ошибка стоила десяти минут, а не поездки.
//

import Foundation
import Testing
import MapKit
import MapLibre

@testable import RadarMap

@Suite("Стиль карты на движке")
struct EngineMapStyleTests {

    private let base = URL(string: "https://soulmed.uz/radarmap")!

    private func style(daylight: Bool = true) -> [String: Any] {
        let text = EngineMapStyle.json(daylight: daylight, base: base)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private func layers(_ style: [String: Any]) -> [[String: Any]] {
        style["layers"] as? [[String: Any]] ?? []
    }

    @Test("Стиль — валидный JSON восьмой версии")
    func styleIsValid() {
        #expect(style()["version"] as? Int == 8)
        #expect(!layers(style()).isEmpty)
    }

    @Test("Адрес тайла остаётся шаблоном, а не превращается в %7Bz%7D")
    func tileTemplateSurvives() {
        let sources = style()["sources"] as? [String: Any] ?? [:]
        for name in ["far", "near"] {
            let tiles = (sources[name] as? [String: Any])?["tiles"] as? [String] ?? []
            #expect(tiles.count == 1)
            #expect(tiles.first?.hasSuffix("/mvt/{z}/{x}/{y}.mvt") == true,
                    "шаблон адреса испорчен: \(tiles)")
        }
        let glyphs = style()["glyphs"] as? String ?? ""
        #expect(glyphs.hasSuffix("/glyphs/{fontstack}/{range}.pbf"))
    }

    @Test("Два источника с одним зумом каждый, а не диапазон")
    func twoSourcesNotARange() {
        // Сборка пишет только зумы 15 и 11. Источник, объявленный «11…15»,
        // погнал бы движок за 12, 13 и 14, которых нет: каждый такой запрос —
        // дырка в кадре.
        let sources = style()["sources"] as? [String: Any] ?? [:]
        for (name, zoom) in [("far", EngineMapStyle.farZoom),
                             ("near", EngineMapStyle.detailZoom)] {
            let source = sources[name] as? [String: Any] ?? [:]
            #expect(source["minzoom"] as? Int == zoom)
            #expect(source["maxzoom"] as? Int == zoom)
        }
    }

    @Test("Сначала ВСЕ каймы, потом ВСЕ полотна")
    func casingBeforeFill() {
        // Ради этого переход и затевался: пока кайма рисовалась вместе со
        // своей дорогой, она ложилась поверх соседней и рассекала перекрёсток
        // швом. Порядок слоёв в стиле — и есть двухпроходная схема.
        let ids = layers(style()).compactMap { $0["id"] as? String }
        let lastCasing = ids.lastIndex { $0.hasPrefix("roads-case") }
        let firstFill = ids.firstIndex { $0 == "roads" || $0 == "roads-far" }
        #expect(lastCasing != nil && firstFill != nil)
        if let lastCasing, let firstFill { #expect(firstFill > lastCasing) }
    }

    @Test("У дорог круглые стыки и торцы")
    func roundJoins() {
        // Срезанные торцы — одна из трёх названных жалоб. Здесь она закрыта
        // свойством движка, а не нашей геометрией.
        for layer in layers(style()) where (layer["id"] as? String)?.contains("roads") == true {
            let layout = layer["layout"] as? [String: Any] ?? [:]
            #expect(layout["line-cap"] as? String == "round")
            #expect(layout["line-join"] as? String == "round")
        }
    }

    @Test("Ширина дороги берётся из тайла, а не из класса")
    func widthComesFromTheTile() {
        let roads = layers(style()).first { $0["id"] as? String == "roads" }
        let paint = roads?["paint"] as? [String: Any] ?? [:]
        #expect(String(describing: paint["line-width"] ?? "").contains("width"),
                "ширина считается не по измеренным метрам")
    }

    @Test("Маршрут масштабируется, разметка не перечёркивает перекрёстки")
    func routeAndJunctionReadability() {
        let all = layers(style())
        #expect(!all.contains { $0["id"] as? String == "centreline" })
        for id in ["route", "route-case"] {
            let paint = all.first { $0["id"] as? String == id }?["paint"] as? [String: Any]
            let width = paint?["line-width"] as? [Any]
            #expect(width?.first as? String == "interpolate")
        }
        let halo = all.first { $0["id"] as? String == "camera-halo" }
        #expect(halo?["filter"] != nil, "фоновые камеры не должны светиться как предупреждение")
        #expect(all.contains { $0["id"] as? String == "camera-icons" })
    }

    @Test("До проверки индекса нет сетевых источников, локальные маркеры остаются")
    func preparingIndexHasNoTileRequests() throws {
        let json = EngineMapStyle.json(daylight: true, base: base, tilesReady: false)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let sources = try #require(object["sources"] as? [String: Any])
        #expect(Set(sources.keys) == Set(["cameras", "route", "position", "traveled", "maneuver", "traffic-usual", "traffic", "route-traffic", "route-near", "route-arrows", "marks", "road-events", "cng-status", "hotspots",
                                         "camera-label"]))
        for layer in layers(object) {
            if let source = layer["source"] as? String { #expect(sources[source] != nil) }
        }
    }

    #if canImport(MapLibre)
    @Test("Охват карты — метры видимой высоты, а не расстояние до камеры")
    @MainActor func viewportScale() {
        let latitude = 41.311
        let zoom = EngineMapView.Coordinator.zoom(spanMeters: 1400, height: 874, latitude: latitude)
        let visible = 40_075_016.686 * cos(latitude * .pi / 180) / (512 * pow(2, zoom)) * 874
        #expect(abs(visible - 1400) < 0.01)
        #expect(zoom > 15 && zoom < 16)
    }
    #endif

    @Test("Каждый слой ссылается на существующий источник")
    func everyLayerHasItsSource() {
        let sources = style()["sources"] as? [String: Any] ?? [:]
        for layer in layers(style()) {
            guard let source = layer["source"] as? String else { continue }
            #expect(sources[source] != nil, "слой \(layer["id"] ?? "?") без источника")
        }
    }

    @Test("Ни одного чужого хоста")
    func noThirdPartyHosts() {
        // На карте водителя не должно быть ни чужих тайлов, ни чужих шрифтов:
        // это и трафик, и слежка, и чужая доступность.
        let text = EngineMapStyle.json(daylight: true, base: base)
        for host in ["mapbox", "openstreetmap.org", "arcgisonline", "maptiler", "google"] {
            #expect(!text.contains(host), "в стиле чужой источник: \(host)")
        }
    }

    @Test("День и ночь — разные тона, и они из общей палитры")
    func themesDiffer() {
        let dayText = EngineMapStyle.json(daylight: true, base: base)
        let nightText = EngineMapStyle.json(daylight: false, base: base)
        #expect(dayText != nightText)

        let was = MapPalette.daylight
        MapPalette.daylight = true
        let ground = MapPalette.groundTone.hex
        MapPalette.daylight = was
        let background = layers(style(daylight: true))
            .first { $0["id"] as? String == "ground" }?["paint"] as? [String: Any]
        #expect(background?["background-color"] as? String == ground,
                "фон карты разошёлся с палитрой схемы")
    }

    @Test("Курс проходит север кратчайшим путём и держится без GPS-курса")
    func shortHeading() {
        #expect(EngineMapPresentation.heading(1, near: 359) == 361)
        #expect(EngineMapPresentation.heading(359, near: 1) == -1)
        #expect(EngineMapPresentation.heading(-1, near: 65) == 65)
    }

    @Test("Маршрут разрезается без щели, в том числе на повторном участке петли")
    func routeSplit() throws {
        let a = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.28)
        let b = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.29)
        let length = MKMapPoint(a).distance(to: MKMapPoint(b))
        let split = EngineMapPresentation.split([a, b, a], at: length * 1.5)
        #expect(split.traveled.count == 3)
        #expect(split.remaining.count == 2)
        let end = try #require(split.traveled.last), start = try #require(split.remaining.first)
        #expect(abs(end.longitude - start.longitude) < 0.0000001)
        #expect(abs(end.longitude - 69.285) < 0.000001)
        #expect(EngineMapPresentation.split([a, b], at: 0).traveled.isEmpty)
        #expect(EngineMapPresentation.split([a, b], at: length * 2).remaining.isEmpty)
    }

    @Test("Выделение манёвра ограничено подходом и реальной линией маршрута")
    func maneuverSegment() {
        let road = [CLLocationCoordinate2D(latitude: 41.31, longitude: 69.28),
                    CLLocationCoordinate2D(latitude: 41.31, longitude: 69.30)]
        #expect(EngineMapPresentation.maneuver(road, at: 900, progress: 0).isEmpty)
        #expect(EngineMapPresentation.maneuver(road, at: nil, progress: 0).isEmpty)
        let turn = EngineMapPresentation.maneuver(road, at: 300, progress: 250)
        #expect(turn.count == 2)
        if turn.count == 2 {
            #expect(abs(MKMapPoint(turn[0]).distance(to: MKMapPoint(turn[1])) - 70) < 0.1)
        }
    }

    @Test("Камера рисуется всегда и занимает место: остальное её обходит")
    func cameraIconsNeverHidden() throws {
        let icons = try #require(layers(style()).first { $0["id"] as? String == "camera-icons" })
        let layout = icons["layout"] as? [String: Any]
        // Подпись или светофор не вправе вытеснить камеру…
        #expect(layout?["icon-allow-overlap"] as? Bool == true)
        // …и не ложатся поверх неё (12.10: «задевает иконки камеры»).
        #expect(layout?["icon-ignore-placement"] as? Bool == false)
    }

    @Test("Тревога лежит поверх соседей, пометки ничего не вытесняют")
    func alertOnTopBadgesOutOfPlacement() throws {
        let all = layers(style())
        let icons = try #require(all.first { $0["id"] as? String == "camera-icons" })
        let sort = (icons["layout"] as? [String: Any])?["symbol-sort-key"] as? [Any]
        // Ключ — из свойства точки (CameraMarkerLook.sortKey: тревога — 2).
        #expect((sort?[1] as? [Any])?.last as? String == "sort")
        let badges = try #require(all.first { $0["id"] as? String == "camera-badges" })
        let layout = badges["layout"] as? [String: Any]
        #expect(layout?["icon-ignore-placement"] as? Bool == true)
        #expect(layout?["icon-allow-overlap"] as? Bool == true)
        // Пометки — над значками.
        let ids = all.compactMap { $0["id"] as? String }
        #expect((ids.firstIndex(of: "camera-badges") ?? 0) > (ids.firstIndex(of: "camera-icons") ?? .max))
    }

    @Test("Светофор новой карты — свой значок, и он не налезает на соседей")
    func ownTrafficLight() {
        let layer: [String: Any] = ["id": "radar-signal-icon",
                                    "layout": ["icon-image": "traffic-light", "icon-allow-overlap": false]]
        let own = EngineModernStyle.ownTrafficLight(layer)["layout"] as? [String: Any]
        #expect(own?["icon-image"] as? String == EngineModernStyle.trafficLightImage)
        #expect(own?["icon-allow-overlap"] as? Bool == false)
        let other: [String: Any] = ["id": "x", "layout": ["icon-image": "fuel_11"]]
        #expect((EngineModernStyle.ownTrafficLight(other)["layout"] as? [String: Any])?["icon-image"] as? String
                == "fuel_11")
    }

    @Test("Разметка берётся из готового слоя, светофоры без онлайн-фаз")
    func roadFurniture() {
        let all = layers(style())
        let markings = all.first { $0["id"] as? String == "lane-markings" }
        #expect(markings?["source-layer"] as? String == "markings")
        let signal = all.first { $0["id"] as? String == "traffic-signals" }
        let layout = signal?["layout"] as? [String: Any]
        #expect(layout?["icon-image"] as? String == "radar-signal")
        #expect(layout?["icon-allow-overlap"] as? Bool == false)
        #expect(all.contains { $0["id"] as? String == "route-traveled" })
    }

    @Test("Полотно узла скрывает внутренние штрихи, мост остаётся сверху")
    func junctionLayerOrder() throws {
        let ids = layers(style()).compactMap { $0["id"] as? String }
        let markings = try #require(ids.firstIndex(of: "lane-markings"))
        let junction = try #require(ids.firstIndex(of: "junction-surface"))
        let median = try #require(ids.firstIndex(of: "median-surface"))
        let bridge = try #require(ids.firstIndex(of: "bridge-deck"))
        let paint = try #require(ids.firstIndex(of: "crossing-paint"))
        let route = try #require(ids.firstIndex(of: "route"))
        #expect(markings < junction && junction < median && median < bridge)
        #expect(bridge < paint && paint < route)
        let signal = layers(style()).first { $0["id"] as? String == "traffic-signals" }
        let layout = signal?["layout"] as? [String: Any]
        #expect(layout?["icon-offset"] == nil)
        #expect(layout?["icon-anchor"] as? String == "bottom")
    }
    @Test("Индекс маршрута режет петлю по пройденному расстоянию")
    func indexedLoop() {
        let a = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.28)
        let b = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.29)
        let c = CLLocationCoordinate2D(latitude: 41.32, longitude: 69.29)
        let points = [a, b, c, a, b]
        let index = EngineMapPresentation.RouteIndex(points)
        for fraction in [0.1, 0.4, 0.7, 0.95] {
            let distance = index.length * fraction
            let expected = EngineMapPresentation.split(points, at: distance)
            let traveled = index.slice(from: 0, to: distance)
            let remaining = index.slice(from: distance, to: index.length)
            #expect(traveled.count == expected.traveled.count)
            #expect(remaining.count == expected.remaining.count)
            #expect(abs(traveled.last!.longitude - remaining.first!.longitude) < 1e-9)
            #expect(abs(traveled.last!.latitude - expected.traveled.last!.latitude) < 1e-9)
        }
        #expect(index.slice(from: index.length, to: index.length + 10).isEmpty)
        #expect(index.slice(from: .nan, to: 10).isEmpty)
        #expect(EngineMapPresentation.RouteIndex([a, a]).slice(from: 0, to: 10).isEmpty)
    }

    @Test("Фоновая геометрия: индекс, линия среза, стрелки; манёвр — только впереди и близко")
    func preparedRoute() async {
        let points = [CLLocationCoordinate2D(latitude: 41.31, longitude: 69.28),
                      CLLocationCoordinate2D(latitude: 41.31, longitude: 69.30)]
        let frame = await EngineMapPresentation.prepareCut(points)
        #expect(abs(frame.index.length - frame.line.length) < 0.01)
        #expect(!frame.arrows.isEmpty)
        #expect(frame.traffic.isEmpty)
        let again = await EngineMapPresentation.prepareCut(points, reuse: (frame.index, frame.line, frame.arrows))
        #expect(again.arrows == frame.arrows)
        let range = EngineMapPresentation.maneuverRange(at: 300, progress: 250)
        #expect(range.map { $0.upperBound - $0.lowerBound } == 70)
        #expect(EngineMapPresentation.maneuverRange(at: 300, progress: 301) == nil)
        #expect(EngineMapPresentation.maneuverRange(at: 900, progress: 0) == nil)
        #expect(EngineMapPresentation.maneuverRange(at: nil, progress: 0) == nil)
    }

    @Test("Кэш области выдерживает небольшой сдвиг, обновляется при выходе и zoom out")
    func viewportCache() {
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 41.31, longitude: 69.28),
                                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        let padded = EngineMapPresentation.padded(region)
        #expect(EngineMapPresentation.contains(padded, region))
        var nearby = region
        nearby.center.latitude += 0.001
        #expect(EngineMapPresentation.contains(padded, nearby))
        nearby.center.latitude += 0.01
        #expect(!EngineMapPresentation.contains(padded, nearby))
        nearby = region
        nearby.span.latitudeDelta *= 2
        #expect(!EngineMapPresentation.contains(padded, nearby))
    }

    @Test("Цвета темы передаются как UIColor, включая классы дорог")
    @MainActor func nativeThemeColors() throws {
        let constant = try #require(EngineMapView.Coordinator.colorExpression("#123456"))
        #expect(constant.constantValue is UIColor)
        let match: [Any] = ["match", ["get", "cls"], 1, "#112233", 2, "#334455", "#667788"]
        let expression = try #require(EngineMapView.Coordinator.colorExpression(match))
        let chosen = expression.expressionValue(with: ["cls": 2], context: nil) as? UIColor
        let expected = EngineMapView.Coordinator.colorExpression("#334455")?.constantValue as? UIColor
        #expect(chosen == expected)
        let fallback = expression.expressionValue(with: ["cls": 9], context: nil) as? UIColor
        #expect(fallback == EngineMapView.Coordinator.colorExpression("#667788")?.constantValue as? UIColor)
        #expect(EngineMapView.Coordinator.colorExpression("broken") == nil)
    }

}
