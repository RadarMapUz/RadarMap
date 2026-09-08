//
//  EngineMapStyle.swift
//  RadarMap
//
//  Стиль карты для движка — тот же язык, что у панели модератора.
//
//  Почему стиль собирается КОДОМ, а не лежит файлом на сервере. Во-первых,
//  палитра одна на всё приложение (SketchPalette), и держать её копию в JSON
//  значило бы завести второй источник правды о цвете. Во-вторых, стиль,
//  который качается по сети, — это чужая геометрия и чужие цвета в обход
//  подписи: правило проекта fail-closed запрещает применять неподписанное
//  молча. Вшитый в бинарник стиль не качается вовсе.
//
//  Что здесь ЕСТЬ и чего не было в самописной схеме: кайма и полотно двумя
//  проходами по всей карте (а не по одному куску), ширина в НАСТОЯЩИХ метрах
//  из тайла на любом зуме, круглые стыки и торцы, порядок «магистраль поверх
//  переулка», подписи вдоль улиц с расстановкой без наложений — всё это
//  делает движок сам.
//

import Foundation

nonisolated enum EngineMapStyle {

    /// Два источника, а не один диапазон 11…15.
    ///
    /// Сборка пишет ТОЛЬКО зумы 15 и 11. Источник, объявленный диапазоном,
    /// заставил бы движок ходить за 12, 13 и 14, которых нет: каждый такой
    /// запрос — пустой ответ и дырка в кадре. Поэтому источника два, каждый
    /// со своим единственным зумом, а промежуточные масштабы движок берёт
    /// растягиванием — ровно так и задумано в MVT.
    static let detailZoom = 15
    static let farZoom = 11

    /// Граница между костяком района и детальной сетью.
    static let detailFromZoom = 14.6

    /// Метры → пиксели на зуме: 2^zoom · 512 / (окружность Земли · cos φ).
    /// Для широты Ташкента множитель постоянен с точностью до процента, и
    /// линия наконец получает ту ширину, которая записана в тайле.
    private static let metresToPixels = 1.7e-5

    /// `houses` — тумблер застройки, общий со схемой. Слой не «прячется»
    /// прозрачностью, а НЕ ПОПАДАЕТ в стиль вовсе: движок не качает того, чего
    /// нет в стиле, и выключенные дома перестают стоить трафика, а не только
    /// внимания.
    static func json(daylight: Bool, base: URL, houses: Bool = false, tilesReady: Bool = true) -> String {
        // Адреса собираются СТРОКОЙ, а не appendingPathComponent.
        //
        // Тот кодирует фигурные скобки в %7B и %7D, и движок уходит за
        // «mvt/%7Bz%7D/…» — то есть за тайлом, которого нет. Ошибка тихая:
        // стиль валиден, карта пуста. Поймана тестом стиля, а не глазами.
        let root = base.absoluteString.hasSuffix("/")
            ? String(base.absoluteString.dropLast()) : base.absoluteString
        let tiles = root + "/mvt/{z}/{x}/{y}.mvt"
        let glyphs = root + "/glyphs/{fontstack}/{range}.pbf"

        // Палитра общая с самописной схемой, и берётся она по ЯВНО заданному
        // времени суток: стиль собирается один раз на тему, а глобальный флаг
        // живёт для отрисовки кадра.
        let was = SketchPalette.daylight
        SketchPalette.daylight = daylight
        defer { SketchPalette.daylight = was }

        let ground = SketchPalette.groundTone.hex
        let casing = SketchPalette.casingTone.hex
        let label = SketchPalette.labelTone.hex
        let halo = SketchPalette.groundTone.hex

        let landColour: [Any] = ["match", ["get", "kind"],
                                 1, SketchPalette.waterTone.hex,
                                 2, SketchPalette.greenTone.hex,
                                 3, SketchPalette.railTone.hex,
                                 4, SketchPalette.blockTone.hex,
                                 5, SketchPalette.sidewalkTone.hex,
                                 6, SketchPalette.houseTone.hex,
                                 SketchPalette.blockTone.hex]
        let asphaltColour: [Any] = ["match", ["get", "cls"],
                                    1, SketchPalette.asphaltTone(.motorway).hex,
                                    2, SketchPalette.asphaltTone(.trunk).hex,
                                    3, SketchPalette.asphaltTone(.primary).hex,
                                    4, SketchPalette.asphaltTone(.secondary).hex,
                                    5, SketchPalette.asphaltTone(.tertiary).hex,
                                    6, SketchPalette.asphaltTone(.residential).hex,
                                    7, SketchPalette.asphaltTone(.service).hex,
                                    SketchPalette.asphaltUnknownTone.hex]

        var style: [String: Any] = [
            "version": 8,
            "glyphs": glyphs,
            "sources": [
                "far": ["type": "vector", "tiles": [tiles],
                        "minzoom": farZoom, "maxzoom": farZoom],
                "near": ["type": "vector", "tiles": [tiles],
                         "minzoom": detailZoom, "maxzoom": detailZoom],
                // Свои слои: камеры и маршрут. Пустые при сборке стиля —
                // наполняются на тике, как и в самописной схеме.
                "cameras": ["type": "geojson", "data": emptyCollection],
                "route": ["type": "geojson", "data": emptyCollection],
                "position": ["type": "geojson", "data": emptyCollection],
            ],
            "layers": layers(ground: ground, casing: casing, label: label,
                             halo: halo,
                             land: landColour, asphalt: asphaltColour,
                             houses: houses),
        ]
        // Do not let Native cache authentication failures while the signed
        // index is still loading. Local overlays work without vector sources.
        if !tilesReady {
            style["sources"] = [
                "cameras": ["type": "geojson", "data": emptyCollection],
                "route": ["type": "geojson", "data": emptyCollection],
                "position": ["type": "geojson", "data": emptyCollection],
            ]
            let all = style["layers"] as? [[String: Any]] ?? []
            style["layers"] = all.filter {
                let source = $0["source"] as? String
                return source != "near" && source != "far"
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: style),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private static let emptyCollection: [String: Any] = [
        "type": "FeatureCollection", "features": [],
    ]

    /// Ширина линии в пикселях по НАСТОЯЩЕЙ ширине дороги из тайла.
    ///
    /// `extra` прибавляется ВНУТРИ каждой ступени, а не снаружи: обернуть
    /// готовое выражение в `['+', …, 2]` нельзя — движок принимает `zoom`
    /// только на верхнем уровне interpolate и падает со стилем целиком. Эту
    /// ошибку панель уже ловила, и вторично её ловить незачем.
    private static func roadWidth(extra: Double = 0) -> [Any] {
        func stop(_ zoom: Double) -> [Any] {
            let scale = pow(2, zoom) * metresToPixels
            return ["max",
                    ["+", ["*", ["coalesce", ["get", "width"], 8], scale], extra],
                    1.2 + extra]
        }
        return ["interpolate", ["exponential", 2], ["zoom"],
                12, stop(12), 15, stop(15), 18, stop(18), 20, stop(20)]
    }

    private static func routeWidth(extra: Double) -> [Any] {
        ["interpolate", ["linear"], ["zoom"],
         11, 3 + extra, 14, 4 + extra, 16, 6 + extra, 19, 9 + extra]
    }

    private static func layers(ground: String, casing: String, label: String,
                               halo: String,
                               land: [Any], asphalt: [Any],
                               houses: Bool) -> [[String: Any]] {
        var out: [[String: Any]] = [
            ["id": "ground", "type": "background",
             "paint": ["background-color": ground]],
        ]
        // Местность: костяк района до 14.6, детальная — после. Оба слоя
        // никогда не рисуются разом, поэтому город не двоится на переходе.
        for (id, source, zoom) in [("land-far", "far", false), ("land", "near", true)] {
            var layer: [String: Any] = [
                "id": id, "type": "fill", "source": source, "source-layer": "land",
                "filter": ["==", ["geometry-type"], "Polygon"],
                "paint": ["fill-color": land],
            ]
            if zoom { layer["minzoom"] = detailFromZoom } else { layer["maxzoom"] = detailFromZoom }
            out.append(layer)
        }
        if houses {
            out.append([
                "id": "houses", "type": "fill", "source": "near", "source-layer": "houses",
                "minzoom": detailFromZoom,
                "paint": ["fill-color": SketchPalette.houseTone.hex,
                          "fill-outline-color": SketchPalette.houseEdgeTone.hex],
            ])
        }
        // ДВА ПРОХОДА, и это главное отличие от самописного рендера: сначала
        // ВСЕ каймы, потом ВСЕ полотна. Пока кайма рисовалась вместе со своей
        // дорогой, она ложилась поверх соседней и рассекала перекрёсток швом.
        for (id, source, near) in [("roads-case-far", "far", false),
                                   ("roads-case", "near", true)] {
            var layer: [String: Any] = [
                "id": id, "type": "line", "source": source, "source-layer": "roads",
                "layout": ["line-cap": "round", "line-join": "round",
                           "line-sort-key": ["-", 0, ["get", "cls"]]],
                "paint": ["line-color": casing, "line-width": roadWidth(extra: 1.4)],
            ]
            if near { layer["minzoom"] = detailFromZoom } else { layer["maxzoom"] = detailFromZoom }
            out.append(layer)
        }
        for (id, source, near) in [("roads-far", "far", false), ("roads", "near", true)] {
            var layer: [String: Any] = [
                "id": id, "type": "line", "source": source, "source-layer": "roads",
                "layout": ["line-cap": "round", "line-join": "round",
                           "line-sort-key": ["-", 0, ["get", "cls"]]],
                "paint": ["line-color": asphalt, "line-width": roadWidth()],
            ]
            if near { layer["minzoom"] = detailFromZoom } else { layer["maxzoom"] = detailFromZoom }
            out.append(layer)
        }
        // Synthetic centre dashes used to run through intersections and look
        // like broken road edges. Lane markings require junction-aware data.
        // Маршрут — под подписями и над дорогой.
        out.append([
            "id": "route-case", "type": "line", "source": "route",
            "layout": ["line-cap": "round", "line-join": "round"],
            "paint": ["line-color": "#04160c", "line-width": routeWidth(extra: 3)],
        ])
        out.append([
            "id": "route", "type": "line", "source": "route",
            "layout": ["line-cap": "round", "line-join": "round"],
            "paint": ["line-color": "#22b879", "line-width": routeWidth(extra: 0)],
        ])
        out.append([
            "id": "labels", "type": "symbol", "source": "near", "source-layer": "roads",
            "minzoom": 14.8,
            "filter": ["all", ["has", "name"], ["<=", ["get", "cls"], 6]],
            "layout": ["symbol-placement": "line",
                       "text-field": ["get", "name"],
                       "text-font": ["Noto Sans Regular"],
                       "text-size": ["interpolate", ["linear"], ["zoom"], 15, 11, 18, 14],
                       "text-max-angle": 35, "text-padding": 4,
                       "symbol-spacing": 360,
                       "symbol-sort-key": ["get", "cls"],
                       "text-allow-overlap": false],
            "paint": ["text-color": label, "text-halo-color": halo,
                      "text-halo-width": 1.6],
        ])
        // Only the current alert has a halo; ordinary cameras stay quiet.
        out.append([
            "id": "camera-halo", "type": "circle", "source": "cameras",
            "filter": ["==", ["get", "alert"], true],
            "paint": ["circle-radius": 23, "circle-color": "#f4ae43",
                      "circle-opacity": 0.18],
        ])
        out.append([
            "id": "camera-dot", "type": "circle", "source": "cameras",
            "paint": ["circle-radius": ["interpolate", ["linear"], ["zoom"],
                                        12, 4, 15, 12, 17, 15],
                      "circle-color": ["case", ["get", "alert"], "#80551c", "#243d49"],
                      "circle-opacity": ["case", ["get", "unconfirmed"], 0.55, 1],
                      "circle-stroke-width": ["case", ["get", "alert"], 3, 1.5],
                      "circle-stroke-color": ["case", ["get", "alert"], "#f4ae43", "#a8c8d2"]],
        ])
        out.append([
            "id": "camera-icons", "type": "symbol", "source": "cameras",
            "minzoom": 14.5,
            "layout": ["icon-image": ["get", "icon"],
                       "icon-allow-overlap": true, "icon-ignore-placement": true],
            "paint": ["icon-opacity": ["case", ["get", "unconfirmed"], 0.55, 1]],
        ])
        out.append([
            "id": "camera-limits", "type": "symbol", "source": "cameras",
            "minzoom": 15.5,
            "filter": ["!=", ["get", "limit"], ""],
            "layout": ["text-field": ["get", "limit"],
                       "text-font": ["Noto Sans Regular"], "text-size": 12,
                       "text-offset": [0, 1.8], "text-padding": 5,
                       "symbol-sort-key": ["case", ["get", "alert"], 0, 1]],
            "paint": ["text-color": label, "text-halo-color": halo,
                      "text-halo-width": 2],
        ])
        out.append([
            "id": "user-location", "type": "symbol", "source": "position",
            "layout": ["icon-image": "radar-user", "icon-allow-overlap": true,
                       "icon-ignore-placement": true, "icon-pitch-alignment": "viewport",
                       "icon-rotation-alignment": "viewport"],
        ])
        return out
    }
}
