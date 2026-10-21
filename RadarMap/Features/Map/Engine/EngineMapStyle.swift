//
//  EngineMapStyle.swift
//  RadarMap
//
//  Стиль карты для движка — тот же язык, что у панели модератора.
//
//  Почему стиль собирается КОДОМ, а не лежит файлом на сервере. Во-первых,
//  палитра одна на всё приложение (MapPalette), и держать её копию в JSON
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
import os

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
        let was = MapPalette.daylight
        MapPalette.daylight = daylight
        defer { MapPalette.daylight = was }

        let ground = MapPalette.groundTone.hex
        let casing = MapPalette.casingTone.hex
        let label = MapPalette.labelTone.hex
        let halo = MapPalette.groundTone.hex

        let landColour: [Any] = ["match", ["get", "kind"],
                                 1, MapPalette.waterTone.hex,
                                 2, MapPalette.greenTone.hex,
                                 3, MapPalette.railTone.hex,
                                 4, MapPalette.blockTone.hex,
                                 5, MapPalette.sidewalkTone.hex,
                                 6, MapPalette.houseTone.hex,
                                 MapPalette.blockTone.hex]
        let asphaltColour: [Any] = ["match", ["get", "cls"],
                                    1, MapPalette.asphaltTone(.motorway).hex,
                                    2, MapPalette.asphaltTone(.trunk).hex,
                                    3, MapPalette.asphaltTone(.primary).hex,
                                    4, MapPalette.asphaltTone(.secondary).hex,
                                    5, MapPalette.asphaltTone(.tertiary).hex,
                                    6, MapPalette.asphaltTone(.residential).hex,
                                    7, MapPalette.asphaltTone(.service).hex,
                                    MapPalette.asphaltUnknownTone.hex]

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
                "traveled": ["type": "geojson", "data": emptyCollection],
                "maneuver": ["type": "geojson", "data": emptyCollection],
                "traffic": ["type": "geojson", "data": emptyCollection],
                "route-traffic": ["type": "geojson", "data": emptyCollection],
                "position": ["type": "geojson", "data": emptyCollection],
                "marks": ["type": "geojson", "data": emptyCollection],
                "road-events": ["type": "geojson", "data": emptyCollection],
                "cng-status": ["type": "geojson", "data": emptyCollection],
                "hotspots": ["type": "geojson", "data": emptyCollection],
            ],
            "layers": layers(ground: ground, casing: casing, label: label,
                             halo: halo,
                             land: landColour, asphalt: asphaltColour,
                             houses: houses, daylight: daylight),
        ]
        // Do not let Native cache authentication failures while the signed
        // index is still loading. Local overlays work without vector sources.
        if !tilesReady {
            style["sources"] = [
                "cameras": ["type": "geojson", "data": emptyCollection],
                "route": ["type": "geojson", "data": emptyCollection],
                "traveled": ["type": "geojson", "data": emptyCollection],
                "maneuver": ["type": "geojson", "data": emptyCollection],
                "traffic": ["type": "geojson", "data": emptyCollection],
                "route-traffic": ["type": "geojson", "data": emptyCollection],
                "position": ["type": "geojson", "data": emptyCollection],
                "marks": ["type": "geojson", "data": emptyCollection],
                "road-events": ["type": "geojson", "data": emptyCollection],
                "cng-status": ["type": "geojson", "data": emptyCollection],
                "hotspots": ["type": "geojson", "data": emptyCollection],
            ]
            let all = style["layers"] as? [[String: Any]] ?? []
            style["layers"] = all.filter {
                let source = $0["source"] as? String
                return source != "near" && source != "far"
            }
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: style)
        } catch {
            Log.app.error("стиль карты не сериализовался: \(error.localizedDescription, privacy: .public)")
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
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

    /// Ширина линии маршрута, точки: тело `body`, плюс `extra` (кайма).
    ///
    /// Нижняя граница — 6 точек на ЛЮБОМ масштабе (25.D, 21.10): прежние
    /// 2,5–3 на z11–14 в машине на отъезде линию почти теряли, а у Яндекса в
    /// той же машине линия — главный предмет кадра. Вблизи (z17–19) — 9–13:
    /// шире полосы, но уже проезжей части.
    private static func routeWidth(extra: Double, share: Double = 1) -> [Any] {
        ["interpolate", ["linear"], ["zoom"],
         11, 6 * share + extra, 15, 6.5 * share + extra, 17, 9 * share + extra,
         19, 13 * share + extra, 20, 15 * share + extra]
    }

    /// Стрелка направления вдоль линии маршрута (EngineMapView.routeArrowIcon):
    /// белый шеврон с каймой линии — своей у каждой темы.
    static func routeArrowImage(daylight: Bool) -> String {
        daylight ? "radar-route-arrow-d" : "radar-route-arrow-n"
    }

    private static func layers(ground: String, casing: String, label: String,
                               halo: String,
                               land: [Any], asphalt: [Any],
                               houses: Bool, daylight: Bool) -> [[String: Any]] {
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
                "paint": ["fill-color": MapPalette.houseTone.hex,
                          "fill-outline-color": MapPalette.houseEdgeTone.hex],
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
        // Геометрия полос подготовлена сборщиком: обрезана по границам узлов.
        // Старые тайлы без этого слоя остаются читаемыми, догадок о полосах нет.
        out.append([
            "id": "lane-markings", "type": "line", "source": "near", "source-layer": "markings",
            // С 16.5: охват машины у перекрёстков — z16.5–17, и с прежних 17
            // разметка полос там не появлялась вовсе.
            "minzoom": 16.5,
            "layout": ["line-cap": "butt", "line-join": "round"],
            "paint": ["line-color": daylight ? "#99a99c" : "#b5c5b5",
                      "line-width": ["interpolate", ["exponential", 2], ["zoom"], 16.5, 0.5, 17, 0.65, 20, 2.5],
                      "line-dasharray": [5, 7], "line-opacity": 0.7],
        ])
        // Полигон узла закрывает внутренние швы и пунктир, который иначе
        // пересекал бы косой или широкий перекрёсток. Островки лежат сверху.
        out.append([
            "id": "junction-surface", "type": "fill", "source": "near", "source-layer": "surface",
            "minzoom": 16, "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["==", ["get", "kind"], 8]],
            "paint": ["fill-color": MapPalette.asphaltTone(.primary).hex,
                      "fill-antialias": false],
        ])
        out.append([
            "id": "median-surface", "type": "fill", "source": "near", "source-layer": "surface",
            "minzoom": 16, "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["==", ["get", "kind"], 9]],
            "paint": ["fill-color": MapPalette.sidewalkTone.hex,
                      "fill-outline-color": casing],
        ])
        // Мост не должен исчезать под заливкой нижнего перекрёстка.
        for edge in [true, false] {
            out.append([
                "id": edge ? "bridge-case" : "bridge-deck", "type": "line", "source": "near", "source-layer": "roads",
                "minzoom": 16, "filter": ["==", ["get", "bridge"], true],
                "layout": ["line-cap": "round", "line-join": "round"],
                "paint": ["line-color": edge ? casing : MapPalette.asphaltTone(.primary).hex,
                          "line-width": roadWidth(extra: edge ? 1.4 : 0)],
            ])
        }
        out.append([
            "id": "crossing-paint", "type": "line", "source": "near", "source-layer": "paint",
            "minzoom": 18, "layout": ["line-cap": "butt"],
            "paint": ["line-color": daylight ? "#d0c8aa" : "#e2e7db",
                      "line-width": ["interpolate", ["exponential", 2], ["zoom"], 18, 2.2, 20, 8.8]],
        ])
        out += routeLayers(daylight: daylight)
        out.append([
            "id": "traffic-signals", "type": "symbol", "source": "near", "source-layer": "points",
            "minzoom": 16.2, "filter": ["==", ["get", "kind"], 1],
            "layout": ["icon-image": "radar-signal", "icon-allow-overlap": false,
                       "icon-ignore-placement": true,
                       "icon-padding": 2, "icon-anchor": "bottom",
                       "icon-size": ["interpolate", ["linear"], ["zoom"], 16.2, 0.75, 18, 1],
                       "icon-pitch-alignment": "viewport", "icon-rotation-alignment": "viewport"],
        ])
        out.append([
            "id": "stop-controls", "type": "symbol", "source": "near", "source-layer": "points",
            "minzoom": 17, "filter": ["==", ["get", "kind"], 7],
            "layout": ["icon-image": "radar-stop", "icon-allow-overlap": false,
                       "icon-padding": 8, "icon-anchor": "bottom",
                       "icon-pitch-alignment": "viewport"],
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
        out += markerLayers(label: label, halo: halo)
        return out
    }

    /// Маршрут (25.D, «линия красивее», 21.10): пройденное бледнее, кайма,
    /// тело, пробки НА линии, манёвр, светлая середина и стрелки направления.
    /// Цвета — числа `RouteColors` (те же, что у `Theme.route…`), строкой:
    /// стиль движка — JSON. Общие для обоих стилей — в новом
    /// (EngineModernStyle) ложатся над основой и под подписями; дома в
    /// объёме нарисованы раньше и линию не закрывают.
    static func routeLayers(daylight: Bool) -> [[String: Any]] {
        func colour(_ pair: RouteColors.Pair) -> String { RouteColors.pick(pair, daylight: daylight) }
        let round: [String: Any] = ["line-cap": "round", "line-join": "round"]
        var out: [[String: Any]] = []
        // Пробки по городу — ПОД линией маршрута: на самом маршруте пробку
        // показывает его собственный цвет (route-traffic), а тонкая нитка
        // рядом с ним только двоила бы её. На остальных дорогах видны тонкие
        // цветные линии, каждое направление — справа по ходу (движение
        // правостороннее): у двусторонней улицы видны обе стороны.
        out.append([
            "id": "traffic", "type": "line", "source": "traffic",
            "layout": round,
            "paint": ["line-color": ["match", ["get", "level"],
                                     3, colour(RouteColors.jam),
                                     2, colour(RouteColors.slow),
                                     colour(RouteColors.free)],
                      "line-width": ["interpolate", ["linear"], ["zoom"],
                                     11, 1.2, 14, 2, 16, 3, 19, 5],
                      "line-offset": ["interpolate", ["linear"], ["zoom"],
                                      11, 0.9, 14, 1.3, 16, 1.8, 19, 2.8],
                      "line-opacity": ["match", ["get", "level"], 1, 0.7, 0.95]],
        ])
        // Пройденное — той же ширины, без каймы и бледное: уже не решение.
        out.append([
            "id": "route-traveled", "type": "line", "source": "traveled",
            "layout": round,
            "paint": ["line-color": colour(RouteColors.traveled),
                      "line-width": routeWidth(extra: 0), "line-opacity": 0.85],
        ])
        out.append([
            "id": "route-case", "type": "line", "source": "route",
            "layout": round,
            "paint": ["line-color": colour(RouteColors.casing), "line-width": routeWidth(extra: 3)],
        ])
        out.append([
            "id": "route", "type": "line", "source": "route",
            "layout": round,
            "paint": ["line-color": colour(RouteColors.body), "line-width": routeWidth(extra: 0)],
        ])
        // Пробка на нашей стороне — цветом самой линии (RouteTraffic: место и
        // направление, как у времени в пути). Свободно — линия синяя.
        out.append([
            "id": "route-traffic", "type": "line", "source": "route-traffic",
            "layout": round,
            "paint": ["line-color": ["match", ["get", "level"], 3, colour(RouteColors.jam),
                                     colour(RouteColors.slow)],
                      "line-width": routeWidth(extra: 0)],
        ])
        out.append([
            "id": "route-maneuver", "type": "line", "source": "maneuver",
            "layout": round,
            "paint": ["line-color": daylight ? "#123a8f" : "#d6e6ff", "line-width": routeWidth(extra: 1)],
        ])
        // Светлая середина — белым поверх любого цвета линии (синего, янтаря,
        // красного): объём ленты, а не второй цвет.
        out.append([
            "id": "route-core", "type": "line", "source": "route",
            "layout": round,
            "paint": ["line-color": RouteColors.core(daylight: daylight),
                      "line-width": routeWidth(extra: 0, share: 0.34)],
        ])
        // Стрелки направления вдоль линии. Вне раскладки (ignore-placement):
        // стрелка не вытесняет ни подпись, ни камеру — камеры нарисованы
        // позже и лежат сверху.
        out.append([
            "id": "route-arrows", "type": "symbol", "source": "route", "minzoom": 13,
            "layout": ["symbol-placement": "line",
                       "symbol-spacing": ["interpolate", ["linear"], ["zoom"], 13, 70, 17, 110, 19, 160],
                       "icon-image": routeArrowImage(daylight: daylight),
                       // Картинка 14×12 pt; высота стрелки — ~0,8 тела линии.
                       "icon-size": ["interpolate", ["linear"], ["zoom"],
                                     13, 0.42, 15, 0.45, 17, 0.6, 19, 0.87, 20, 1.0],
                       "icon-rotation-alignment": "map", "icon-pitch-alignment": "map",
                       "icon-allow-overlap": true, "icon-ignore-placement": true,
                       "icon-padding": 0],
        ])
        return out
    }

    /// Цвет типа камеры для слоёв движка — те же значения, что Theme.Types
    /// (движок принимает только строку цвета).
    static func typeHex(_ kind: CameraType) -> String {
        switch kind {
        case .stationaryCamera:        return "#D93025"
        case .stationaryRadar, .tripod: return "#F2B200"
        case .intelligentRadar:        return "#6A3FD6"
        case .mobileRadar:             return "#C2409E"
        case .dpsPost:                 return "#46525E"
        case .accident:                return "#D93025"
        case .other:                   return "#6B6B70"
        }
    }

    /// Камеры и «я» — над всем, в обоих стилях.
    static func markerLayers(label: String, halo: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        // Память о треногах — НЕ камеры и рисуются не как камеры: мягкая зона
        // без значка и без клина. Только на близком зуме: на обзорном это шум
        // поверх настоящих точек, а решение сбросить скорость принимают вблизи.
        out.append([
            "id": "hotspot-zone", "type": "fill", "source": "hotspots", "minzoom": 13,
            "paint": ["fill-color": typeHex(.tripod), "fill-opacity": 0.10],
        ])
        out.append([
            "id": "hotspot-edge", "type": "line", "source": "hotspots", "minzoom": 13,
            "paint": ["line-color": typeHex(.tripod), "line-opacity": 0.5,
                      "line-width": 1.5, "line-dasharray": [3, 3]],
        ])
        // Перекрытия и ремонт (12б.5) — ПОД камерами и без права занимать
        // их место: ремонт у радара не закрывает радар («камера не исчезает
        // никогда»). Неподтверждённые — полупрозрачными, как призрак радара.
        // Метан на АГНКС (12б.4): пилюля «● 15 мин» над значком станции —
        // тоже под камерами и без права занимать их место. Только у машины
        // на метане (источник пуст у остальных).
        out.append([
            "id": "cng-status", "type": "symbol", "source": "cng-status", "minzoom": 12,
            "layout": ["icon-image": ["get", "icon"], "icon-allow-overlap": true,
                       "icon-ignore-placement": false, "icon-anchor": "bottom",
                       "icon-offset": [0, -10], "icon-pitch-alignment": "viewport"],
            // Неподтверждённый статус — слабее: слух виден, но не как факт.
            "paint": ["icon-opacity": ["case", ["==", ["get", "confirmed"], true], 1.0, 0.6]],
        ])
        out.append([
            "id": "road-events", "type": "symbol", "source": "road-events",
            "layout": ["icon-image": ["get", "icon"], "icon-allow-overlap": true,
                       "icon-ignore-placement": false, "icon-pitch-alignment": "viewport"],
            "paint": ["icon-opacity": ["case", ["==", ["get", "confirmed"], true], 1.0, 0.55]],
        ])
        // Ореол только у текущей тревоги; обычные камеры молчат.
        out.append([
            "id": "camera-halo", "type": "circle", "source": "cameras",
            "filter": ["==", ["get", "alert"], true],
            "paint": ["circle-radius": 26, "circle-color": "#D93025",
                      "circle-opacity": 0.18],
        ])
        // Точка мелкого масштаба — тот же язык, что значок (вариант B,
        // CameraMarkerLook): цвет типа у камер на пути, графит у спокойных,
        // и спокойная мельче. Цвет приходит свойством точки.
        let calm: [Any] = ["==", ["get", "tier"], "calm"]
        out.append([
            "id": "camera-dot", "type": "circle", "source": "cameras",
            "maxzoom": 14.5,
            "paint": ["circle-radius": ["interpolate", ["linear"], ["zoom"],
                                        12, ["case", calm, 3, 4],
                                        15, ["case", calm, 7, 10],
                                        17, ["case", calm, 9, 13]],
                      "circle-color": ["coalesce", ["get", "color"], "#D93025"],
                      // Спокойная камера на виде района — без белого кольца и
                      // полупрозрачная (25.D, аудит 21.10): с кольцом 1,8 она
                      // весила, как камера на пути. Не скрыта — правило
                      // «камера не исчезает»; на пути и тревога — как были.
                      "circle-opacity": ["case", ["get", "unconfirmed"], 0.55, calm, 0.6, 1],
                      "circle-stroke-width": ["case", ["get", "alert"], 3, calm, 0, 1.8],
                      "circle-stroke-color": "#FFFFFF"],
        ])
        // Камера рисуется ВСЕГДА. Раньше значок участвовал в раскладке
        // подписей (icon-allow-overlap=false): подпись улицы или заведения,
        // поставленная раньше, вытесняла его — и при приближении карты радар
        // исчезал ровно там, где на него смотрят (владелец, 11.10). Промолчать
        // о камере хуже лишней подписи, и правило то же, что у оповещений.
        // И занимает своё место: с 12.10 значок камеры участвует в раскладке
        // (icon-ignore-placement=false) — светофоры, подписи и заведения его
        // обходят, а не ложатся поверх («задевает иконки камеры», владелец).
        // Сама камера по-прежнему рисуется всегда (icon-allow-overlap).
        out.append([
            "id": "camera-icons", "type": "symbol", "source": "cameras",
            "minzoom": 14.5,
            "layout": ["icon-image": ["get", "icon"],
                       "icon-allow-overlap": true, "icon-ignore-placement": false,
                       // При allow-overlap больший ключ лежит СВЕРХУ: тревога
                       // поверх «на пути», те — поверх спокойных. До 12.10
                       // ключ был 0 у тревоги — она пряталась под соседями.
                       "symbol-sort-key": ["coalesce", ["get", "sort"], 0]],
            "paint": ["icon-opacity": ["case", ["get", "unconfirmed"], 0.55, 1]],
        ])
        // Пометки поверх значка: «?» у отметки водителей, галочка у своей
        // камеры. Отдельным слоем — иначе каждая пометка удваивала бы набор
        // картинок, — и вне раскладки: пометка ничего не вытесняет.
        out.append([
            "id": "camera-badges", "type": "symbol", "source": "cameras",
            "minzoom": 14.5,
            "filter": ["!=", ["coalesce", ["get", "badge"], ""], ""],
            "layout": ["icon-image": ["get", "badge"],
                       "icon-allow-overlap": true, "icon-ignore-placement": true,
                       "icon-offset": ["match", ["get", "tier"],
                                       "alert", ["literal", [13, -13]],
                                       "path", ["literal", [11, -11]],
                                       ["literal", [9, -9]]],
                       "symbol-sort-key": ["coalesce", ["get", "sort"], 0]],
        ])
        // Лимит под значком камеры убран (владелец, 12.10): цифра «60» у
        // каждой камеры дублировала знак у скорости и загромождала карту.
        // Флаг цели и точка долгого тапа — поверх камер, но под «я».
        out.append([
            "id": "marks", "type": "symbol", "source": "marks",
            "layout": ["icon-image": ["get", "icon"], "icon-allow-overlap": true,
                       "icon-ignore-placement": true, "icon-pitch-alignment": "viewport"],
        ])
        // Пустой с 11.10: стрелка «я» — вид поверх карты (EngineMapView,
        // «Стрелка»), запись в этот источник на каждом кадре стоила движку
        // полной расстановки символов. Слой оставлен: его ждёт шаблон выпуска.
        out.append([
            "id": "user-location", "type": "symbol", "source": "position",
            "layout": ["icon-image": "radar-user", "icon-allow-overlap": true,
                       "icon-rotate": ["get", "rotation"],
                       "icon-ignore-placement": true, "icon-pitch-alignment": "viewport",
                       "icon-rotation-alignment": "map"],
        ])
        return out
    }
}
