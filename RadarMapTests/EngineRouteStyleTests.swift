//
//  EngineRouteStyleTests.swift
//  RadarMapTests
//
//  Линия маршрута «богаче» (25.D, 21.10): кайма, тело, пробки на линии,
//  светлая середина, стрелки направления, пройденное бледнее — в обоих
//  стилях, в обеих темах; не тоньше 6 точек ни на каком масштабе (в машине
//  на отъезде линия терялась); камеры остаются поверх. И спокойные камеры на
//  виде района — тише, но не исчезают.
//

import Foundation
import Testing

@testable import RadarMap

@Suite("Линия маршрута и спокойные камеры")
struct EngineRouteStyleTests {

    private let order = ["traffic", "route-traveled", "route-glow", "route-near-glow", "route-case", "route-near-case", "route", "route-near",
                         "route-traffic", "route-maneuver", "route-near-maneuver", "route-core",
                         "route-near-core", "route-arrows"]

    private func layers(daylight: Bool) -> [[String: Any]] {
        let text = EngineMapStyle.json(daylight: daylight, base: URL(string: "https://soulmed.uz/radarmap")!)
        let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        return object?["layers"] as? [[String: Any]] ?? []
    }

    private func layer(_ id: String, _ all: [[String: Any]]) -> [String: Any]? {
        all.first { $0["id"] as? String == id }
    }

    /// Значения ступеней interpolate по zoom: [z, v, z, v, …] после третьего элемента.
    private func stops(_ expression: Any?) -> [(Double, Double)] {
        guard let list = expression as? [Any], list.count > 3 else { return [] }
        let rest = Array(list.dropFirst(3))
        return stride(from: 0, to: rest.count - 1, by: 2).compactMap { i in
            guard let z = rest[i] as? Double ?? (rest[i] as? Int).map(Double.init),
                  let v = rest[i + 1] as? Double ?? (rest[i + 1] as? Int).map(Double.init) else { return nil }
            return (z, v)
        }
    }

    @Test("Слои линии — в своём порядке и под камерами", arguments: [true, false])
    func layerOrder(daylight: Bool) throws {
        let all = layers(daylight: daylight)
        let ids = all.compactMap { $0["id"] as? String }
        let positions = try order.map { try #require(ids.firstIndex(of: $0), "нет слоя \($0)") }
        #expect(positions == positions.sorted(), "порядок слоёв маршрута: \(positions)")
        let camera = try #require(ids.firstIndex(of: "camera-dot"))
        #expect(positions.allSatisfy { $0 < camera }, "линия легла поверх камер")
    }

    @Test("Линия не тоньше 6 точек ни на каком масштабе", arguments: [true, false])
    func widthFloor(daylight: Bool) {
        let all = layers(daylight: daylight)
        for id in ["route", "route-traffic", "route-traveled"] {
            let width = stops((layer(id, all)?["paint"] as? [String: Any])?["line-width"])
            #expect(!width.isEmpty, "\(id): ширина не ступенями")
            #expect(width.allSatisfy { $0.1 >= 6 }, "\(id): тоньше 6 точек — \(width)")
            #expect(width.first?.0 ?? 99 <= 11, "\(id): ступени должны начинаться с вида района")
        }
        let body = stops((layer("route", all)?["paint"] as? [String: Any])?["line-width"])
        let rim = stops((layer("route-case", all)?["paint"] as? [String: Any])?["line-width"])
        let core = stops((layer("route-core", all)?["paint"] as? [String: Any])?["line-width"])
        for ((_, b), ((_, r), (_, c))) in zip(body, zip(rim, core)) {
            #expect(r > b, "кайма шире тела")
            #expect(c < b * 0.5 && c > 0, "середина — узкая жила внутри тела")
        }
    }

    @Test("Цвета линии — из RouteColors, по теме", arguments: [true, false])
    func coloursFromRouteColors(daylight: Bool) {
        let all = layers(daylight: daylight)
        func colour(_ id: String) -> String? { (layer(id, all)?["paint"] as? [String: Any])?["line-color"] as? String }
        #expect(colour("route") == RouteColors.pick(RouteColors.body, daylight: daylight))
        #expect(colour("route-case") == RouteColors.pick(RouteColors.casing, daylight: daylight))
        #expect(colour("route-traveled") == RouteColors.pick(RouteColors.traveled, daylight: daylight))
        #expect(colour("route-core") == RouteColors.core(daylight: daylight))
        // На линии — только «медленно» и «стоим»: свободно оставляет её синей.
        let traffic = (layer("route-traffic", all)?["paint"] as? [String: Any])?["line-color"] as? [Any]
        let text = String(describing: traffic ?? [])
        #expect(text.contains(RouteColors.pick(RouteColors.jam, daylight: daylight)))
        #expect(text.contains(RouteColors.pick(RouteColors.slow, daylight: daylight)))
        #expect(!text.contains(RouteColors.pick(RouteColors.free, daylight: daylight)))
    }

    @Test("Стрелки — точками на линии, вне раскладки; позади среза скрыты фильтром")
    func arrowsAlongTheLine() throws {
        let arrows = try #require(layer("route-arrows", layers(daylight: true)))
        let layout = try #require(arrows["layout"] as? [String: Any])
        #expect(arrows["source"] as? String == EngineMapStyle.routeArrowsSource)
        #expect(layout["symbol-placement"] == nil, "точки с местом на линии, не раскладка по линии")
        #expect(String(describing: arrows["filter"] ?? "").contains("a"), "фильтр по месту на линии")
        #expect(layout["icon-image"] as? String == EngineMapStyle.routeArrowImage(daylight: true))
        #expect(layout["icon-ignore-placement"] as? Bool == true)
        #expect(layout["icon-allow-overlap"] as? Bool == true)
        #expect(layout["icon-rotation-alignment"] as? String == "map")
        #expect(String(describing: layout["icon-rotate"] ?? "").contains("b"))
    }

    @Test("Окно у машины: краска по line-progress на источнике с lineMetrics, ширина — как у пары", arguments: [true, false])
    func nearWindowLayers(daylight: Bool) throws {
        let text = EngineMapStyle.json(daylight: daylight, base: URL(string: "https://soulmed.uz/radarmap")!)
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let sources = try #require(object["sources"] as? [String: Any])
        let near = try #require(sources[EngineMapStyle.routeNearSource] as? [String: Any])
        #expect(near["lineMetrics"] as? Bool == true, "без lineMetrics движок не рисует line-gradient")
        #expect(EngineModernStyle.liveSources.contains(EngineMapStyle.routeNearSource))
        #expect(EngineModernStyle.liveSources.contains(EngineMapStyle.routeArrowsSource))
        let all = layers(daylight: daylight)
        let ids = EngineMapStyle.routeNearLayers
        for (id, pair) in [(ids.glow, "route-glow"), (ids.casing, "route-case"), (ids.body, "route"),
                           (ids.maneuver, "route-maneuver"), (ids.core, "route-core")] {
            let paint = try #require(layer(id, all)?["paint"] as? [String: Any])
            #expect(layer(id, all)?["source"] as? String == EngineMapStyle.routeNearSource)
            #expect(String(describing: paint["line-gradient"] ?? "").contains("line-progress"))
            let twin = layer(pair, all)?["paint"] as? [String: Any]
            #expect(String(describing: paint["line-width"] ?? "") == String(describing: twin?["line-width"] ?? "-"),
                    "\(id): ширина не как у \(pair) — стык окна и остатка был бы ступенькой")
        }
    }

    @Test("Источник пробок на линии есть в обоих стилях")
    func routeTrafficSource() {
        #expect(EngineModernStyle.liveSources.contains("route-traffic"))
        let text = EngineMapStyle.json(daylight: true, base: URL(string: "https://soulmed.uz/radarmap")!)
        #expect(text.contains("\"route-traffic\""))
    }

    @Test("Спокойная камера на виде района — без кольца и тише, но видна; на пути — как была")
    func calmDotIsQuietButVisible() throws {
        let dot = try #require(layer("camera-dot", layers(daylight: false)))
        let paint = try #require(dot["paint"] as? [String: Any])
        // ["case", unconfirmed, 0.55, calm, 0.6, 1]
        let opacity = try #require(paint["circle-opacity"] as? [Any])
        let calmOpacity = try #require(opacity[4] as? Double)
        #expect(calmOpacity > 0.3 && calmOpacity < 0.8, "спокойная — тише, но не пропадает")
        #expect(opacity.last as? Int == 1 || opacity.last as? Double == 1, "камера на пути — непрозрачна")
        let stroke = try #require(paint["circle-stroke-width"] as? [Any])
        #expect(stroke[2] as? Int == 3 || stroke[2] as? Double == 3, "тревога — прежнее кольцо")
        #expect((stroke[4] as? Double ?? (stroke[4] as? Int).map(Double.init)) == 0, "спокойная — без кольца")
        #expect((stroke.last as? Double) == 1.8, "на пути — прежнее кольцо")
    }
}
