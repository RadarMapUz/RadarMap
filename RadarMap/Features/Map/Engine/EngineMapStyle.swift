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
            "sources": ([
                "far": ["type": "vector", "tiles": [tiles],
                        "minzoom": farZoom, "maxzoom": farZoom],
                "near": ["type": "vector", "tiles": [tiles],
                         "minzoom": detailZoom, "maxzoom": detailZoom],
            ] as [String: [String: Any]]).merging(liveSources()) { _, own in own },
            "layers": layers(ground: ground, casing: casing, label: label,
                             halo: halo,
                             land: landColour, asphalt: asphaltColour,
                             houses: houses, daylight: daylight),
        ]
        // Do not let Native cache authentication failures while the signed
        // index is still loading. Local overlays work without vector sources.
        if !tilesReady {
            style["sources"] = liveSources()
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

    /// Свои источники приложения: камеры, маршрут и прочее. Пустые при
    /// сборке стиля — наполняются на тике. Один список на оба стиля
    /// (EngineModernStyle.liveSources).
    static func liveSources() -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for name in EngineModernStyle.liveSources {
            var source: [String: Any] = ["type": "geojson", "data": emptyCollection]
            // Окно линии у машины красится по line-progress (27.A): без
            // lineMetrics движок line-gradient не рисует.
            if name == routeNearSource { source["lineMetrics"] = true }
            out[name] = source
        }
        return out
    }

    // MARK: - Пробки на улицах (33H)

    /// Слои пробок: кайма, линия, шевроны направления.
    static let trafficLayerIDs = (casing: "traffic-case", line: "traffic", chevrons: "traffic-arrows")
    /// Имя растра шеврона уровня 1…4 в теме (EngineMapView кладёт обе темы:
    /// цвет шеврона — от цвета линии, а он у темы свой).
    static func trafficChevronImage(level: Int, daylight: Bool, usual: Bool = false) -> String {
        "traffic-chevron-\(level)-\(daylight ? "day" : "night")\(usual ? "-usual" : "")"
    }

    /// Толщина линии пробок, точки, по классу дороги (магистраль / улица /
    /// второстепенная) на ступенях масштаба — одна таблица для линии, каймы,
    /// сдвига и шевронов. У Яндекса на z14 магистраль ~3 pt: линия читается
    /// цветом, а шеврон внутри неё различим.
    static let trafficWidthStops: [(zoom: Double, widths: [Double])] = [
        (11, [1.8, 1.2, 0.7]), (13, [3.0, 2.2, 1.4]), (15, [5.0, 3.8, 2.6]),
        (17, [7.5, 5.8, 4.2]), (19, [10.0, 8.0, 6.0]),
    ]
    /// Сдвиг вправо по ходу — доля толщины: половина толщины плюс зазор в
    /// четверть её — две встречные линии лежат рядом с видимым просветом и
    /// не наезжают друг на друга ни на каком масштабе.
    static let trafficOffsetShare = 0.75
    /// Кайма шире линии на столько точек (по 0,6 с каждой стороны).
    static let trafficCasingExtra = 1.2
    /// Указатель — наконечник в квадрате этой стороны, точки; на карте он
    /// масштабируется до `trafficArrowScale` толщин линии.
    static let trafficChevronSide = 16.0
    /// Наконечник шире линии в 2,4 раза — как у Яндекса: знак внутри линии
    /// толщиной 4–5 pt не читался (снимки 27.10, первая проба).
    static let trafficArrowScale = 2.4
    /// Указатели: с какого масштаба у класса (магистраль / улица /
    /// второстепенная); у «обычно» — на `trafficUsualArrowDelay` позже: оно
    /// покрывает весь город, и знаки на каждом переулке — шум.
    static let trafficChevronFromZoom: [Double] = [13.5, 14.5, 16]
    static let trafficUsualArrowDelay = 1.5

    /// interpolate по zoom с match по классу на каждой ступени: движок
    /// принимает zoom только на верхнем уровне выражения.
    static func trafficWidth(scale: Double = 1, extra: Double = 0, usualShare: Double? = nil) -> [Any] {
        var out: [Any] = ["interpolate", ["linear"], ["zoom"]]
        for stop in trafficWidthStops {
            let byTier: [Any] = ["match", ["get", "tier"], 0, stop.widths[0] * scale,
                                 1, stop.widths[1] * scale, stop.widths[2] * scale]
            let value: [Any] = usualShare.map { ["*", byTier, ["case", ["==", ["get", "src"], 1], $0, 1]] } ?? byTier
            out += [stop.zoom, extra == 0 ? value : ["+", value, extra]]
        }
        return out
    }

    /// На этих зумах в «Вождении 3D» спокойные линии гаснут (70): та же
    /// полоса 14,5–15,5, где лента сменяет линию маршрута.
    static let trafficQuietZooms = (from: 14.5, to: 15.5)

    /// `quiet` — «Вождение 3D»: вблизи только живые заторы. «Обычно в это
    /// время» (профиль недели, не факт) и «свободно» лежат посреди полос
    /// зелёной и оранжевой лентой со стрелками поверх разметки, а действия от
    /// водителя не требуют; пробку на маршруте показывает его собственный цвет.
    static func trafficLayers(daylight: Bool, quiet: Bool = false) -> [[String: Any]] {
        func hex(_ pair: RouteColors.Pair) -> String { RouteColors.pick(pair, daylight: daylight) }
        let colours = TrafficPalette.active
        func byLevel(_ transform: (RouteColors.Pair) -> RouteColors.Pair) -> [Any] {
            ["match", ["get", "level"],
             4, hex(transform(TrafficPalette.level(4, in: colours))),
             3, hex(transform(TrafficPalette.level(3, in: colours))),
             2, hex(transform(TrafficPalette.level(2, in: colours))),
             hex(transform(TrafficPalette.level(1, in: colours)))]
        }
        let isUsual: [Any] = ["==", ["get", "src"], 1]
        let calm: [Any] = ["any", isUsual, ["<=", ["get", "level"], 1]]
        func quieted(_ value: Any) -> [Any] {
            ["interpolate", ["linear"], ["zoom"], trafficQuietZooms.from, value,
             trafficQuietZooms.to, ["case", calm, 0, value]]
        }
        let offset = trafficWidth(scale: trafficOffsetShare)
        let round: [String: Any] = ["line-cap": "round", "line-join": "round"]
        let casingOpacity = daylight ? TrafficPalette.casingOpacity.day : TrafficPalette.casingOpacity.night
        // Указатели видны с масштаба своего класса; «обычно» — позже.
        var thresholds: [(zoom: Double, tier: Int, usual: Bool)] = []
        for (tier, zoom) in trafficChevronFromZoom.enumerated() {
            thresholds.append((zoom, tier, false))
            thresholds.append((zoom + trafficUsualArrowDelay, tier, true))
        }
        thresholds.sort { $0.zoom < $1.zoom }
        // Ступени step — строго по возрастанию: совпавшие пороги (улица и
        // «обычно» магистрали — оба на 15) — одной ступенью, иначе движок молча
        // отбрасывает весь слой.
        var chevronOpacity: [Any] = ["step", ["zoom"], 0]
        var shown: [(tier: Int, usual: Bool)] = []
        for (index, threshold) in thresholds.enumerated() {
            shown.append((threshold.tier, threshold.usual))
            if index + 1 < thresholds.count, thresholds[index + 1].zoom == threshold.zoom { continue }
            var visible: [Any] = ["any"]
            for item in shown {
                visible.append(["all", ["==", ["get", "tier"], item.tier],
                                [item.usual ? "==" : "!=", ["get", "src"], 1]])
            }
            chevronOpacity += [threshold.zoom, ["case", quiet ? ["all", visible, ["!", calm]] : visible, 1, 0]]
        }
        // Высота наконечника = trafficArrowScale толщин своей линии.
        let chevronSize = trafficWidth(scale: trafficArrowScale / trafficChevronSide,
                                       usualShare: TrafficPalette.usualWidthShare)
        func chevronImage(usual: Bool) -> [Any] {
            ["match", ["get", "level"],
             4, trafficChevronImage(level: 4, daylight: daylight, usual: usual),
             3, trafficChevronImage(level: 3, daylight: daylight, usual: usual),
             2, trafficChevronImage(level: 2, daylight: daylight, usual: usual),
             trafficChevronImage(level: 1, daylight: daylight, usual: usual)]
        }
        let casingFade: Any = ["case", isUsual, casingOpacity * 0.4, casingOpacity]
        var lineLayer: [String: Any] = ["line-color": ["case", isUsual, byLevel(TrafficPalette.usual), byLevel { $0 }],
                                        "line-width": trafficWidth(scale: 1, usualShare: TrafficPalette.usualWidthShare),
                                        "line-offset": offset]
        if quiet { lineLayer["line-opacity"] = quieted(1) }
        return [
            ["id": trafficLayerIDs.casing, "type": "line", "source": "traffic", "layout": round,
             "paint": ["line-color": hex(TrafficPalette.casing),
                       "line-width": trafficWidth(extra: trafficCasingExtra, usualShare: TrafficPalette.usualWidthShare),
                       "line-offset": offset,
                       "line-opacity": quiet ? quieted(casingFade) : casingFade]],
            ["id": trafficLayerIDs.line, "type": "line", "source": "traffic", "layout": round, "paint": lineLayer],
            ["id": trafficLayerIDs.chevrons, "type": "symbol", "source": "traffic",
             "minzoom": trafficChevronFromZoom[0],
             "layout": ["symbol-placement": "line",
                        "symbol-spacing": ["interpolate", ["linear"], ["zoom"], 12, 48, 15, 80, 18, 120],
                        "icon-image": ["case", isUsual, chevronImage(usual: true), chevronImage(usual: false)],
                        "icon-size": chevronSize,
                        // Сдвиг к правой стороне — в самом растре (trafficChevronIcon).
                        "icon-anchor": "center",
                        "icon-rotation-alignment": "map",
                        "icon-pitch-alignment": "map",
                        "icon-keep-upright": false,
                        "icon-allow-overlap": true,
                        "icon-ignore-placement": true],
             "paint": ["icon-opacity": chevronOpacity]],
        ]
    }

    /// Окно линии маршрута у машины (RouteCut): срез краской каждый кадр.
    static let routeNearSource = "route-near"
    /// Стрелки направления — точками с местом на линии (RouteCut.arrows).
    static let routeArrowsSource = "route-arrows"
    /// Слои окна у машины: кайма, тело, манёвр, середина — режутся одинаково.
    static let routeNearLayers = (glow: "route-near-glow", casing: "route-near-case", body: "route-near",
                                  maneuver: "route-near-maneuver", core: "route-near-core")

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
    /// той же машине линия — главный предмет кадра. Вблизи (z17–19) — 11–16:
    /// около полосы (у Яндекса линия — в полосу шириной), но уже проезжей части.
    static func routeWidth(extra: Double, share: Double = 1) -> [Any] {
        ["interpolate", ["linear"], ["zoom"],
         11, 6 * share + extra, 15, 7 * share + extra, 17, 11 * share + extra,
         19, 16 * share + extra, 20, 19 * share + extra]
    }

    /// Свечение линии: насколько шире тела (точек, на обе стороны вместе) и
    /// размытие края, точек (29.F).
    static let routeGlowExtra: Double = 16
    static let routeGlowBlur: Double = 9
    /// Светлая середина — размытой жилой, а не резкой белой полосой поверх
    /// тела: блик объёма, а не «пластиковая трубка» (29.F).
    static let routeCoreBlur: [Any] = ["interpolate", ["linear"], ["zoom"], 11, 1.2, 17, 2.4, 20, 4]

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
        // показывает его собственный цвет (route-traffic), а линия рядом с ним
        // только двоила бы её. Слои — trafficLayers (33H).
        out += trafficLayers(daylight: daylight)
        // Пройденное — той же ширины, без каймы и бледное: уже не решение.
        // Источник — ВЕСЬ маршрут, один раз на маршрут (27.A): граница
        // пройденного — это срез окна у машины поверх, а не конец этой линии.
        out.append([
            "id": "route-traveled", "type": "line", "source": "traveled",
            "layout": round,
            "paint": ["line-color": colour(RouteColors.traveled),
                      "line-width": routeWidth(extra: 0), "line-opacity": 0.85],
        ])
        // Каждая роль — парой: остаток линии за окном и окно у машины
        // (RouteCut). Окно красится line-gradient: до среза под значком
        // прозрачно — видно пройденное снизу, — дальше цвет. Пара стоит
        // рядом, чтобы стык окна и остатка был одним слоем цвета.
        let near = routeNearLayers
        let nearSource = routeNearSource
        func nearLayer(_ id: String, width: [Any]) -> [String: Any] {
            ["id": id, "type": "line", "source": nearSource, "layout": round,
             "paint": ["line-gradient": RouteCut.gradient(RouteCut.Paint.clear.body), "line-width": width]]
        }
        // Пунктир от машины до начала линии (RouteConnector).
        out.append([
            "id": "route-connector", "type": "line", "source": "route-connector",
            "layout": round,
            "paint": ["line-color": colour(RouteColors.body),
                      "line-width": ["interpolate", ["linear"], ["zoom"], 13, 2.5, 17, 4, 20, 7],
                      "line-dasharray": [0.01, 2.2]],
        ])
        // Мягкое свечение под каймой (29.F, «линия как у Amap»): широкая
        // размытая полоса цвета тела. На тёмном асфальте поездки линия
        // светится, а не лежит пластиковой трубкой; днём на светлой земле —
        // лёгкий ореол. Пробки на нём тем же цветом, что тело (краска окна).
        out.append([
            "id": "route-glow", "type": "line", "source": "route",
            "layout": round,
            "paint": ["line-color": colour(RouteColors.body), "line-width": routeWidth(extra: Self.routeGlowExtra),
                      "line-blur": Self.routeGlowBlur,
                      "line-opacity": daylight ? RouteColors.glowOpacity.day : RouteColors.glowOpacity.night],
        ])
        var nearGlow = nearLayer(near.glow, width: routeWidth(extra: Self.routeGlowExtra))
        if var paint = nearGlow["paint"] as? [String: Any] {
            paint["line-blur"] = Self.routeGlowBlur
            paint["line-opacity"] = daylight ? RouteColors.glowOpacity.day : RouteColors.glowOpacity.night
            nearGlow["paint"] = paint
        }
        out.append(nearGlow)
        out.append([
            "id": "route-case", "type": "line", "source": "route",
            "layout": round,
            "paint": ["line-color": colour(RouteColors.casing), "line-width": routeWidth(extra: 3)],
        ])
        out.append(nearLayer(near.casing, width: routeWidth(extra: 3)))
        out.append([
            "id": "route", "type": "line", "source": "route",
            "layout": round,
            "paint": ["line-color": colour(RouteColors.body), "line-width": routeWidth(extra: 0)],
        ])
        // В окне пробки — частью краски тела (те же уровни, та же мера места).
        out.append(nearLayer(near.body, width: routeWidth(extra: 0)))
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
            "paint": ["line-color": colour(RouteColors.maneuver), "line-width": routeWidth(extra: 1)],
        ])
        out.append(nearLayer(near.maneuver, width: routeWidth(extra: 1)))
        // Светлая середина — белым поверх любого цвета линии (синего, янтаря,
        // красного): объём ленты, а не второй цвет.
        out.append([
            "id": "route-core", "type": "line", "source": "route",
            "layout": round,
            "paint": ["line-color": RouteColors.core(daylight: daylight),
                      "line-width": routeWidth(extra: 0, share: 0.34),
                      "line-blur": Self.routeCoreBlur],
        ])
        var nearCore = nearLayer(near.core, width: routeWidth(extra: 0, share: 0.34))
        if var paint = nearCore["paint"] as? [String: Any] {
            paint["line-blur"] = Self.routeCoreBlur
            nearCore["paint"] = paint
        }
        out.append(nearCore)
        // Стрелки направления — точками с местом на линии (RouteCut.arrows):
        // фильтр прячет всё позади среза, порог переходит, когда срез
        // проходит стрелку, — она в этот момент под значком. Ранг редеет на
        // обзоре (шаг как у прежнего symbol-spacing). Вне раскладки
        // (ignore-placement): стрелка не вытесняет ни подпись, ни камеру —
        // камеры нарисованы позже и лежат сверху.
        var opacity: [Any] = ["step", ["zoom"],
                              ["case", [">=", ["get", "r"], RouteCut.arrowMaxRank], 1, 0]]
        for (k, zoom) in RouteCut.arrowRankZooms.enumerated() {
            opacity += [zoom, ["case", [">=", ["get", "r"], RouteCut.arrowMaxRank - k - 1], 1, 0]]
        }
        out.append([
            "id": "route-arrows", "type": "symbol", "source": routeArrowsSource, "minzoom": 13,
            "filter": [">=", ["get", "a"], 0],
            "layout": ["icon-image": routeArrowImage(daylight: daylight),
                       // Картинка 16×14 pt, шеврон 9 pt — ~0,7 тела линии.
                       // Шеврон в картинке смотрит вправо: поворот — курс − 90°.
                       "icon-rotate": ["get", "b"],
                       "icon-size": ["interpolate", ["linear"], ["zoom"],
                                     13, 0.5, 15, 0.6, 17, 0.85, 19, 1.2, 20, 1.4],
                       "icon-rotation-alignment": "map", "icon-pitch-alignment": "map",
                       "icon-allow-overlap": true, "icon-ignore-placement": true,
                       "icon-padding": 0],
            "paint": ["icon-opacity": opacity],
        ])
        return out
    }

    /// Цвет типа камеры для слоёв движка — те же значения, что Theme.Types
    /// (движок принимает только строку цвета).
    /// Зона «здесь часто ставят треногу» — янтарь, не красный камеры: это
    /// догадка о прошлом, а не камера (HotspotAlert). До 29.C2 брался цвет
    /// треноги, теперь у треноги красный камеры. С 10.11 — ночной `warning`:
    /// свой #F2B200 был почти-дублем и его, и жёлтого главного действия.
    static let hotspotHex = RouteColors.hex(WidgetPalette.warning.dark)

    static func typeHex(_ kind: CameraType) -> String {
        String(format: "#%06X", kind.markerRGB)
    }

    /// С этого масштаба камера — значок, ниже — точка (camera-dot).
    static let cameraIconMinZoom = 14.5

    /// Камеры и «я» — над всем, в обоих стилях.
    static func markerLayers(label: String, halo: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        // Память о треногах — НЕ камеры и рисуются не как камеры: мягкая зона
        // без значка и без клина. Только на близком зуме: на обзорном это шум
        // поверх настоящих точек, а решение сбросить скорость принимают вблизи.
        out.append([
            "id": "hotspot-zone", "type": "fill", "source": "hotspots", "minzoom": 13,
            "paint": ["fill-color": hotspotHex, "fill-opacity": 0.10],
        ])
        out.append([
            "id": "hotspot-edge", "type": "line", "source": "hotspots", "minzoom": 13,
            "paint": ["line-color": hotspotHex, "line-opacity": 0.5,
                      "line-width": 1.5, "line-dasharray": [3, 3]],
        ])
        // «чаще вечером» (82) — подпись зоны вблизи; уступает всему.
        out.append([
            "id": "hotspot-label", "type": "symbol", "source": "hotspots", "minzoom": 15,
            "filter": ["!=", ["coalesce", ["get", "label"], ""], ""],
            "layout": ["text-field": ["get", "label"], "text-font": ["Noto Sans Regular"],
                       "text-size": 12, "text-optional": true,
                       "text-pitch-alignment": "viewport", "text-rotation-alignment": "viewport"],
            "paint": ["text-color": label, "text-halo-color": halo, "text-halo-width": 1.6],
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
        // Ореол только у текущей тревоги; обычные камеры молчат. У ромба и
        // треугольника — вокруг точки, у булавки (вариант C, 13.11) — вокруг
        // головы: булавка стоит остриём на точке камеры, голова выше на
        // pinHeadLift. Сдвиг — в точках экрана: булавка не ложится с наклоном.
        let alertOn: [Any] = ["==", ["get", "alert"], true]
        let pinned: [Any] = ["==", ["coalesce", ["get", "anchor"], "center"], "bottom"]
        let haloPaint: [String: Any] = ["circle-radius": 26,
                                        "circle-color": RouteColors.hex(CameraMarkerLook.alertRGB),
                                        "circle-opacity": 0.18,
                                        "circle-pitch-alignment": "viewport"]
        out.append([
            "id": "camera-halo", "type": "circle", "source": "cameras",
            "filter": ["all", alertOn, ["!", pinned]],
            "paint": haloPaint,
        ])
        // Ниже z14.5 вместо булавки — точка (camera-dot): ореол — на ней.
        var pinHalo = haloPaint
        pinHalo["circle-translate"] = ["step", ["zoom"], ["literal", [0, 0]], cameraIconMinZoom,
                                       ["literal", [0, -CameraMarkerLook.pinHeadLift(side: CameraMarkerLook.pinAlertSide)]]]
        pinHalo["circle-translate-anchor"] = "viewport"
        out.append([
            "id": "camera-halo-pin", "type": "circle", "source": "cameras",
            "filter": ["all", alertOn, pinned],
            "paint": pinHalo,
        ])
        // Точка мелкого масштаба — тот же язык, что значок (вариант C,
        // CameraMarkerLook.dotColor): графит у камер, янтарь у отметок
        // водителей, красный только у тревоги и ДТП; спокойная мельче.
        // Цвет приходит свойством точки.
        let calm: [Any] = ["==", ["get", "tier"], "calm"]
        out.append([
            "id": "camera-dot", "type": "circle", "source": "cameras",
            "maxzoom": cameraIconMinZoom,
            "paint": ["circle-radius": ["interpolate", ["linear"], ["zoom"],
                                        12, ["case", calm, 3, 4],
                                        15, ["case", calm, 7, 10],
                                        17, ["case", calm, 9, 13]],
                      // Без цвета у точки — графит спокойной камеры, не красный:
                      // красный значит «тревога» (90, вариант C).
                      "circle-color": ["coalesce", ["get", "color"], CameraMarkerLook.neutralDay],
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
            "minzoom": cameraIconMinZoom,
            "layout": ["icon-image": ["get", "icon"],
                       "icon-allow-overlap": true, "icon-ignore-placement": false,
                       // Булавка — остриём на точке камеры (CameraMarkerLook.anchor).
                       "icon-anchor": ["coalesce", ["get", "anchor"], "center"],
                       // При allow-overlap больший ключ лежит СВЕРХУ: тревога,
                       // затем тренога, затем «на пути», внизу спокойные. До
                       // 12.10 ключ был 0 у тревоги — она пряталась под соседями.
                       "symbol-sort-key": ["coalesce", ["get", "sort"], 0]],
            "paint": ["icon-opacity": ["case", ["get", "unconfirmed"], 0.55, 1]],
        ])
        var badgeOffset: [Any] = ["match", ["coalesce", ["get", "place"], ""]]
        for place in CameraMarkerLook.badgePlaces {
            badgeOffset += [place.key, ["literal", [place.offset.x, place.offset.y]]]
        }
        badgeOffset.append(["literal", [9.0, -9.0]])
        // Пометки поверх значка: «?» у отметки водителей, галочка у своей
        // камеры. Отдельным слоем — иначе каждая пометка удваивала бы набор
        // картинок, — и вне раскладки: пометка ничего не вытесняет.
        out.append([
            "id": "camera-badges", "type": "symbol", "source": "cameras",
            "minzoom": 14.5,
            "filter": ["!=", ["coalesce", ["get", "badge"], ""], ""],
            "layout": ["icon-image": ["get", "badge"],
                       "icon-allow-overlap": true, "icon-ignore-placement": true,
                       // Правый верх головы булавки или фигуры (CameraMarkerLook.badgeOffset).
                       "icon-offset": badgeOffset,
                       "symbol-sort-key": ["coalesce", ["get", "sort"], 0]],
        ])
        // Свежесть отметки водителей (82): «✓ 14:05» — последнее «Стоит»,
        // «14:05?» — только сообщили. Вблизи, не у тревожной (там расстояние).
        out.append([
            "id": "camera-fresh", "type": "symbol", "source": "cameras", "minzoom": 16,
            "filter": ["all", ["!=", ["coalesce", ["get", "fresh"], ""], ""], ["!", ["get", "alert"]]],
            "layout": ["text-field": ["get", "fresh"], "text-font": ["Noto Sans Bold"],
                       "text-size": 11, "text-anchor": "top", "text-offset": [0, 1.4],
                       "text-optional": true,
                       "text-pitch-alignment": "viewport", "text-rotation-alignment": "viewport"],
            "paint": ["text-color": label, "text-halo-color": halo, "text-halo-width": 1.8],
        ])
        // Расстояние до камеры, о которой идёт тревога («400 м»), — у её
        // значка, в машине (CarPlayCameraCue, 25.F): камера ушла из дока,
        // и цифра живёт там, куда водитель и так смотрит. Одна точка в своём
        // источнике: переписывать раз в секунду весь источник камер значило
        // бы расставлять заново все символы. Вне раскладки — подпись не
        // вытесняет ничего и не вытесняется ничем.
        out.append([
            "id": "camera-label", "type": "symbol", "source": "camera-label",
            "layout": ["text-field": ["get", "text"],
                       "text-font": ["Noto Sans Bold"],
                       "text-size": 15,
                       "text-anchor": "top",
                       "text-offset": [0, 1.3],
                       "text-allow-overlap": true, "text-ignore-placement": true,
                       "text-pitch-alignment": "viewport", "text-rotation-alignment": "viewport"],
            "paint": ["text-color": label, "text-halo-color": halo, "text-halo-width": 2.2],
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
