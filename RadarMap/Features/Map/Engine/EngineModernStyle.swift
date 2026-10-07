//
//  EngineModernStyle.swift
//  RadarMap
//
//  Новая карта: основа OpenMapTiles и наши слои дороги — стилем из бандла.
//
//  Стиль генерирует server/omt/make_style.py --app (тот же, что видит панель
//  и превью), а test_make_style сверяет, что в бандле лежит ровно он: забыть
//  перегенерировать — красный тест, а не старая карта у водителя.
//
//  Стиль ВШИТ, а не качается: это цвета и порядок слоёв, и молча применять
//  неподписанное с сервера правило 19 не позволяет. С сервера приходят только
//  тайлы — по адресам выпуска (TileRelease), и каждый проходит сторожа.
//
//  Поверх основы — живые слои приложения из EngineMapStyle: маршрут над
//  дорогой и под подписями, камеры и «я» над всем.
//
//  Выключатель — `AppSettings.mapModernStyle`: без него (или без выпуска на
//  сервере) экран остаётся на прежнем стиле EngineMapStyle.
//

import Foundation

nonisolated enum EngineModernStyle {

    static let lightResource = "map_style_light"
    static let darkResource = "map_style_dark"

    /// Свои источники приложения — пустые при сборке, наполняются на тике.
    static let liveSources = ["cameras", "route", "traveled", "maneuver", "position"]

    /// Стиль новой карты. nil — ресурса нет, он битый или в выпуске нет
    /// нужного набора: тогда вызывающий остаётся на прежнем стиле.
    static func json(daylight: Bool, base: URL, release: TileRelease,
                     houses: Bool, places: Bool = true, offline: OfflineFiles? = nil,
                     bundle: Bundle = .main) -> String? {
        guard var style = template(daylight: daylight, base: base, bundle: bundle),
              var sources = style["sources"] as? [String: Any],
              var layers = style["layers"] as? [[String: Any]],
              let omt = release.tilesTemplate(base: base, set: "omt"),
              let mvt = release.tilesTemplate(base: base, set: "mvt") else { return nil }

        // Адреса тайлов — из подписанного корня, а не из шаблона: путь и
        // расширение набора задаёт выпуск.
        for (name, tiles) in [("openmaptiles", omt), ("radar", mvt)] {
            guard var source = sources[name] as? [String: Any] else { return nil }
            source["tiles"] = [tiles]
            sources[name] = source
        }
        // Без связи внутри скачанного региона — локальные файлы PMTiles.
        // Они проверены sha256 при скачивании (OfflineMapService), поэтому
        // сторож тайлов здесь не нужен: чтение идёт с диска, не из сети.
        if let offline {
            for (name, file) in [("openmaptiles", offline.omt), ("radar", offline.mvt)] {
                guard var source = sources[name] as? [String: Any] else { return nil }
                source["tiles"] = nil
                source["url"] = "pmtiles://" + file.absoluteString
                sources[name] = source
            }
        }
        let empty: [String: Any] = ["type": "FeatureCollection", "features": [] as [Any]]
        for name in liveSources { sources[name] = ["type": "geojson", "data": empty] }
        style["sources"] = sources

        // Камеру ставит приложение. Положение из стиля при загрузке дёрнуло
        // бы карту в центр Ташкента на кадр.
        for key in ["center", "zoom", "bearing", "pitch"] { style[key] = nil }

        // Дома — тумблер, общий со схемой: выключенный слой не попадает в стиль
        // вовсе, и движок перестаёт за ним ходить.
        if !houses {
            layers.removeAll { layer in
                let sourceLayer = layer["source-layer"] as? String
                return sourceLayer == "building" || sourceLayer == "houses"
            }
        }

        // «Места» — общие POI (кафе, банки, магазины). Заправки и парковки
        // остаются всегда: это то, что водитель ищет на карте.
        if !places {
            layers.removeAll { ($0["id"] as? String)?.hasPrefix("poi-level") == true }
        }

        // Маршрут — над дорогой и разметкой, под подписями основы.
        let labels = layers.firstIndex {
            $0["type"] as? String == "symbol" && $0["source"] as? String == "openmaptiles"
        } ?? layers.count
        layers.insert(contentsOf: EngineMapStyle.routeLayers(daylight: daylight), at: labels)

        let was = SketchPalette.daylight
        SketchPalette.daylight = daylight
        let label = SketchPalette.labelTone.hex
        let halo = SketchPalette.groundTone.hex
        SketchPalette.daylight = was
        layers += EngineMapStyle.markerLayers(label: label, halo: halo)
        style["layers"] = layers

        guard let data = try? JSONSerialization.data(withJSONObject: style),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Шаблон из бандла с подставленным адресом сервера.
    static func template(daylight: Bool, base: URL, bundle: Bundle = .main) -> [String: Any]? {
        let name = daylight ? lightResource : darkResource
        guard let url = bundle.url(forResource: name, withExtension: "json")
                ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "MapStyle"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Подстановка — по тексту, до разбора: плейсхолдер стоит и в шрифтах,
        // и в спрайте, и в адресах тайлов.
        let text = raw.replacingOccurrences(of: "{{BASE}}", with: TileRelease.root(base))
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}
