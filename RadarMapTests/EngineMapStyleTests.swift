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
}
