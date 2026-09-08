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
        #expect(Set(sources.keys) == Set(["cameras", "route", "position", "traveled", "maneuver"]))
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

        let was = SketchPalette.daylight
        SketchPalette.daylight = true
        let ground = SketchPalette.groundTone.hex
        SketchPalette.daylight = was
        let background = layers(style(daylight: true))
            .first { $0["id"] as? String == "ground" }?["paint"] as? [String: Any]
        #expect(background?["background-color"] as? String == ground,
                "фон карты разошёлся с палитрой схемы")
    }

    @Test("Приближение к манёвру плавное, скорость расширяет обзор")
    func maneuverZoom() {
        let cruise = EngineMapPresentation.span(speedKmh: 100, maneuverDistance: nil, active: true)
        let far = EngineMapPresentation.span(speedKmh: 100, maneuverDistance: 600, active: true)
        let near = EngineMapPresentation.span(speedKmh: 100, maneuverDistance: 100, active: true)
        #expect(cruise == far)
        #expect(near < far)
        #expect(near > AppConfig.engineCloseSpan)
        #expect(EngineMapPresentation.span(speedKmh: 0, maneuverDistance: 0, active: false) == 1_400)
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
}
