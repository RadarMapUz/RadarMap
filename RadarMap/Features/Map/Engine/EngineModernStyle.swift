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
import os

nonisolated enum EngineModernStyle {

    static let lightResource = "map_style_light"
    static let darkResource = "map_style_dark"

    /// Свои источники приложения — пустые при сборке, наполняются на тике.
    static let liveSources = ["cameras", "route", "traveled", "maneuver", "traffic", "route-traffic", "position", "marks", "road-events", "cng-status", "hotspots", "camera-label"]

    /// Готовые стили по набору входов. Сборка — это чтение и разбор 214 КБ
    /// шаблона, правка слоёв и сериализация обратно, и шла она на главном
    /// потоке при КАЖДОЙ смене: тема, «в поездке» на старте и в конце,
    /// дома, места. Входов немного, и они повторяются — второй раз стиль
    /// берётся готовым. Неудача не кэшируется: битый выпуск может починиться.
    private static let cache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// Стиль новой карты. nil — ресурса нет, он битый или в выпуске нет
    /// нужного набора: тогда вызывающий остаётся на прежнем стиле.
    static func json(daylight: Bool, base: URL, release: TileRelease,
                     houses: Bool, places: Bool = true, driving: Bool = false,
                     offline: OfflineFiles? = nil,
                     labelLanguage: String = "ru", bundle: Bundle = .main) -> String? {
        let key = [String(daylight), base.absoluteString,
                   release.tilesTemplate(base: base, set: "omt") ?? "-",
                   release.tilesTemplate(base: base, set: "mvt") ?? "-",
                   String(houses), String(places), String(driving),
                   offline.map { $0.omt.absoluteString + " " + $0.mvt.absoluteString } ?? "-",
                   labelLanguage, bundle.bundlePath].joined(separator: "\u{1F}")
        if let hit = cache.withLock({ $0[key] }) { return hit }
        guard let built = build(daylight: daylight, base: base, release: release, houses: houses,
                                places: places, driving: driving, offline: offline,
                                labelLanguage: labelLanguage, bundle: bundle) else { return nil }
        cache.withLock { store in
            if store.count >= AppConfig.engineStyleCacheLimit { store.removeAll() }
            store[key] = built
        }
        return built
    }

    private static func build(daylight: Bool, base: URL, release: TileRelease,
                              houses: Bool, places: Bool, driving: Bool,
                              offline: OfflineFiles?, labelLanguage: String,
                              bundle: Bundle) -> String? {
        guard var style = template(daylight: daylight, base: base, language: labelLanguage, bundle: bundle),
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

        // В поездке — как у навигаторов: на ходу читают дорогу, а не вывески.
        if driving { layers = drivingLayers(layers) }

        // Светофор — свой значок приложения (EngineMapView.trafficLightIcon).
        // Подменять картинку «traffic-light» спрайта нельзя: спрайт выпуска
        // приходит с сервера ПОСЛЕ загрузки стиля и перезаписывает её обратно
        // (снимки 12.10 — огни остались цветными). Своё имя спрайту не
        // перебить.
        layers = layers.map(Self.ownTrafficLight)
        // АЗС и парковка — значками приложения (EnginePlaceIcons, план 4.7).
        layers = layers.map(Self.ownPlaceIcons)

        // Маршрут — над дорогой и разметкой, под подписями основы.
        let labels = layers.firstIndex {
            $0["type"] as? String == "symbol" && $0["source"] as? String == "openmaptiles"
        } ?? layers.count
        layers.insert(contentsOf: EngineMapStyle.routeLayers(daylight: daylight), at: labels)

        let was = MapPalette.daylight
        MapPalette.daylight = daylight
        let label = MapPalette.labelTone.hex
        let halo = MapPalette.groundTone.hex
        MapPalette.daylight = was
        layers += EngineMapStyle.markerLayers(label: label, halo: halo)
        style["layers"] = layers

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: style)
        } catch {
            Log.app.error("стиль новой карты не сериализовался: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    static let trafficLightImage = "radar-traffic-light"

    static func ownTrafficLight(_ layer: [String: Any]) -> [String: Any] {
        guard var layout = layer["layout"] as? [String: Any],
              layout["icon-image"] as? String == "traffic-light" else { return layer }
        var own = layer
        layout["icon-image"] = trafficLightImage
        own["layout"] = layout
        return own
    }

    static func ownPlaceIcons(_ layer: [String: Any]) -> [String: Any] {
        guard var layout = layer["layout"] as? [String: Any] else { return layer }
        var own = layer
        switch layer["id"] as? String {
        case "radar-poi-fuel":
            layout["icon-image"] = EnginePlaceIcons.fuel
            layout["icon-size"] = ["interpolate", ["linear"], ["zoom"], 13, 0.7, 17, 0.95]
            layout["text-offset"] = [0, 1.25]
        case "radar-poi-parking":
            // Была буква «P» на ореоле текста — теперь значок; подписи нет.
            for key in ["text-field", "text-font", "text-size", "text-padding", "text-allow-overlap"] {
                layout[key] = nil
            }
            layout["icon-image"] = EnginePlaceIcons.parking
            layout["icon-size"] = ["interpolate", ["linear"], ["zoom"], 14.5, 0.6, 17, 0.85]
            layout["icon-allow-overlap"] = false
            layout["icon-padding"] = 4
            own["paint"] = [String: Any]()
        default:
            return layer
        }
        own["layout"] = layout
        return own
    }

    // MARK: - Режим «в поездке»

    /// Слой, которого в поездке нет: общие POI (кафе, банки, магазины),
    /// номера домов и подписи пешеходных дорожек. Заправки, парковки, подписи
    /// улиц, камеры и маршрут — остаются: это то, что нужно за рулём.
    static func hiddenWhileDriving(_ id: String) -> Bool {
        id.hasPrefix("poi-level") || id == "housenumber" || id == "highway-name-path"
    }

    /// Слои стиля для поездки: лишнее убрано, объёмные дома приглушены.
    static func drivingLayers(_ layers: [[String: Any]]) -> [[String: Any]] {
        layers.compactMap { layer in
            guard let id = layer["id"] as? String else { return layer }
            if hiddenWhileDriving(id) { return nil }
            guard id == "building-3d" else { return layer }
            var dimmed = layer
            var paint = dimmed["paint"] as? [String: Any] ?? [:]
            paint["fill-extrusion-opacity"] = AppConfig.engineDrivingBuildingOpacity
            dimmed["paint"] = paint
            return dimmed
        }
    }

    #if DEBUG
    /// Вариант палитры для снимков (27.C, этап 1): `-mapPalette v1|v2|v3`
    /// берёт стиль из MapStyle/Variants (make_style.py --app). Ресурсы
    /// вариантов есть только в DEBUG — Release их исключает
    /// (EXCLUDED_SOURCE_FILE_NAMES), и без ключа карта та же, что у водителя.
    /// Ключ — на весь процесс, поэтому в ключ кэша стилей он не входит.
    static let paletteVariant: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-mapPalette"), index + 1 < args.count else { return nil }
        let value = args[index + 1]
        return ["v1", "v2", "v3"].contains(value) ? value : nil
    }()
    #endif

    /// Шаблон из бандла с подставленным адресом сервера и языком подписей.
    ///
    /// Подписи в стиле — одно имя: `coalesce(name:ru, name)` (make_style.NAME).
    /// Узбекская версия меняет name:ru на name:uz — без узбекского имени у
    /// объекта остаётся местное `name`, а это в Узбекистане и есть узбекское.
    static func template(daylight: Bool, base: URL, language: String = "ru",
                         bundle: Bundle = .main) -> [String: Any]? {
        var name = daylight ? lightResource : darkResource
        #if DEBUG
        if let variant = paletteVariant { name += "_" + variant }
        #endif
        guard let url = bundle.url(forResource: name, withExtension: "json")
                ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "MapStyle")
                ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "MapStyle/Variants")
        else { return nil }
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            Log.app.error("шаблон стиля \(name, privacy: .public) не читается: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // Подстановка — по тексту, до разбора: плейсхолдер стоит и в шрифтах,
        // и в спрайте, и в адресах тайлов.
        var text = raw.replacingOccurrences(of: "{{BASE}}", with: TileRelease.root(base))
        if language != "ru" {
            text = text.replacingOccurrences(of: "\"name:ru\"", with: "\"name:\(language)\"")
        }
        guard let data = text.data(using: .utf8) else { return nil }
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            Log.app.error("шаблон стиля \(name, privacy: .public) — не JSON: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
