//
//  TrafficMapStyleTests.swift
//  RadarMapTests
//
//  Слои пробок на улицах (33H): одна таблица толщины для линии, каймы,
//  сдвига и указателей; сдвиг вправо не даёт встречным линиям наехать друг на
//  друга; указатели — по линии, по ходу, вне раскладки и с корректным
//  выражением (совпавшие ступени step движок молча отбрасывал вместе со слоем).
//

import Foundation
import Testing
@testable import RadarMap

@Suite("Слои пробок на улицах (33H)")
struct TrafficMapStyleTests {

    private func layer(_ id: String, daylight: Bool = true) -> [String: Any]? {
        EngineMapStyle.trafficLayers(daylight: daylight).first { $0["id"] as? String == id }
    }

    @Test("Толщина растёт с масштабом и с классом дороги, у всех слоёв одна таблица")
    func widthTable() {
        for stop in EngineMapStyle.trafficWidthStops {
            #expect(stop.widths[0] > stop.widths[1] && stop.widths[1] > stop.widths[2], "класс на z\(stop.zoom)")
        }
        let zooms = EngineMapStyle.trafficWidthStops.map(\.zoom)
        #expect(zooms == zooms.sorted() && Set(zooms).count == zooms.count)
        for tier in 0..<3 {
            let series = EngineMapStyle.trafficWidthStops.map { $0.widths[tier] }
            #expect(series == series.sorted(), "класс \(tier) тоньше на крупном масштабе")
        }
    }

    @Test("Сдвиг вправо — больше половины толщины: встречные линии не наезжают")
    func offsetKeepsAGap() {
        #expect(EngineMapStyle.trafficOffsetShare > 0.5)
        let line = layer("traffic")?["paint"] as? [String: Any]
        let offset = String(describing: line?["line-offset"] ?? "")
        // Сдвиг — та же таблица, умноженная на долю.
        let first = EngineMapStyle.trafficWidthStops[0].widths[0] * EngineMapStyle.trafficOffsetShare
        #expect(offset.contains(String(first)), "сдвиг из таблицы толщины: \(offset)")
    }

    @Test("Пробки — под маршрутом и камерами, кайма под линией, указатели над ней")
    func order() {
        let ids = EngineMapStyle.trafficLayers(daylight: false).compactMap { $0["id"] as? String }
        #expect(ids == ["traffic-case", "traffic", "traffic-arrows"])
    }

    @Test("Указатели: по линии, по ходу, не переворачиваются и не вытесняют подписи")
    func arrowsFollowTheFlow() throws {
        let arrows = try #require(layer("traffic-arrows"))
        let layout = try #require(arrows["layout"] as? [String: Any])
        #expect(layout["symbol-placement"] as? String == "line")
        #expect(layout["icon-rotation-alignment"] as? String == "map")
        #expect(layout["icon-keep-upright"] as? Bool == false, "перевёрнутый указатель — неправда о направлении")
        #expect(layout["icon-allow-overlap"] as? Bool == true)
        #expect(layout["icon-ignore-placement"] as? Bool == true)
        #expect((arrows["minzoom"] as? Double ?? 0) >= 13, "на мелком масштабе указателей нет")
    }

    @Test("Ступени step у прозрачности указателей — строго по возрастанию", arguments: [true, false])
    func opacityStepsAscend(daylight: Bool) throws {
        let paint = try #require(layer("traffic-arrows", daylight: daylight)?["paint"] as? [String: Any])
        let step = try #require(paint["icon-opacity"] as? [Any])
        #expect(step.first as? String == "step")
        let zooms = stride(from: 3, to: step.count, by: 2).compactMap { step[$0] as? Double }
        #expect(zooms.count >= 3)
        #expect(zooms == zooms.sorted() && Set(zooms).count == zooms.count, "ступени \(zooms)")
    }

    @Test("Каждое имя указателя в стиле есть среди растров, что кладёт карта", arguments: [true, false])
    func arrowImagesExist(daylight: Bool) throws {
        let layout = try #require(layer("traffic-arrows", daylight: daylight)?["layout"] as? [String: Any])
        let text = String(describing: layout["icon-image"] ?? "")
        for level in 1...4 {
            for model in [false, true] {
                #expect(text.contains(EngineMapStyle.trafficChevronImage(level: level, daylight: daylight, model: model)))
            }
        }
    }

    @Test("Цвета линии — из палитры пробок; модель — своим (светлее) цветом", arguments: [true, false])
    func coloursFromPalette(daylight: Bool) throws {
        let paint = try #require(layer("traffic", daylight: daylight)?["paint"] as? [String: Any])
        let text = String(describing: paint["line-color"] ?? "")
        for level in 1...4 {
            let pair = TrafficPalette.level(level)
            #expect(text.contains(RouteColors.pick(pair, daylight: daylight)))
            #expect(text.contains(RouteColors.pick(TrafficPalette.model(pair), daylight: daylight)))
        }
        #expect(!text.contains("#d93025"), "красный камеры — не цвет пробки")
    }

    @Test("Горячий телефон гасит указатели, но не линию")
    @MainActor
    func hotPhoneDropsArrowsOnly() {
        let hidden = EngineMapView.Coordinator.hotHiddenLayers
        #expect(hidden.contains(EngineMapStyle.trafficLayerIDs.chevrons))
        #expect(!hidden.contains(EngineMapStyle.trafficLayerIDs.line))
        #expect(!hidden.contains(EngineMapStyle.trafficLayerIDs.casing))
    }
}
