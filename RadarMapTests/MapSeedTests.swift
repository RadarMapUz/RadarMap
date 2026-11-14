//
//  MapSeedTests.swift
//  RadarMapTests
//
//  Обзорная основа из бандла (план 13.11, решение 5): копии слоёв земли,
//  воды и дорог на своём источнике — под всей сетевой основой, без подписей,
//  не выше масштаба поездки.
//

import Foundation
import Testing
@testable import RadarMap

@Suite("Основа карты из бандла")
struct MapSeedTests {
    private func base() -> [[String: Any]] {
        [["id": "background", "type": "background"],
         ["id": "water", "type": "fill", "source": "openmaptiles", "paint": ["fill-color": "#a9d5f7"]],
         ["id": "highway-primary-casing", "type": "line", "source": "openmaptiles", "maxzoom": 15,
          "paint": ["line-color": "#9aa3b0"]],
         ["id": "highway-primary", "type": "line", "source": "openmaptiles", "paint": ["line-color": "#ffffff"]],
         ["id": "radar-roads", "type": "line", "source": "radar"],
         ["id": "highway-name-major", "type": "symbol", "source": "openmaptiles"]]
    }

    private func ids(_ layers: [[String: Any]]) -> [String] { layers.compactMap { $0["id"] as? String } }

    @Test("Копии — сразу над фоном, под всей сетевой основой")
    func seedSitsUnderTheNetworkBase() {
        let out = EngineModernStyle.withSeed(base(), daylight: true)
        #expect(ids(out) == ["background", "seed-water", "seed-highway-primary", "water", "highway-primary-casing",
                             "highway-primary", "radar-roads", "highway-name-major"])
        for layer in out where (layer["id"] as? String)?.hasPrefix("seed-") == true {
            #expect(layer["source"] as? String == EngineModernStyle.seedSource)
            #expect((layer["maxzoom"] as? Double ?? 99) <= EngineModernStyle.seedMaxZoom)
            #expect(layer["type"] as? String != "symbol", "подписи с z12 не растянуть")
        }
    }

    @Test("Днём дорога основы — цветом своей каймы, ночью — своим")
    func dayRoadTakesCasingColour() {
        func colour(_ daylight: Bool) -> String? {
            let road = EngineModernStyle.withSeed(base(), daylight: daylight)
                .first { $0["id"] as? String == "seed-highway-primary" }
            return (road?["paint"] as? [String: Any])?["line-color"] as? String
        }
        #expect(colour(true) == "#9aa3b0")
        #expect(colour(false) == "#ffffff")
    }

    @Test("Сетевые слои не меняются")
    func networkLayersUntouched() {
        let out = EngineModernStyle.withSeed(base(), daylight: true)
        let water = out.first { $0["id"] as? String == "water" }
        #expect(water?["source"] as? String == "openmaptiles")
        #expect(water?["maxzoom"] == nil)
    }
}
