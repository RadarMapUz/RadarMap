//
//  EngineDriveAsphalt.swift
//  RadarMap
//
//  Асфальт поездки на живом стиле (29.B): разница `map_drive_<тема>.json`
//  кладётся свойствами слоёв на старте поездки и снимается на остановке —
//  стиль не перезагружается. Прежние значения запоминаются при первой
//  правке и возвращаются как были. Тут же — тема линии маршрута: в поездке
//  её постоянные слои (остаток линии, кайма, пройденное, середина, стрелки)
//  берут ночной набор и днём (DriveAsphalt.routeDaylight); с 33H3 — и слой
//  пробок на улицах. Экран машины и плитка (40J) кладут вместо разницы
//  поездки разницу машины (CarMapStyle) — тем же путём.
//
//  Пишется только на смене режима или стиля — на тике ничего.
//

#if canImport(MapLibre)
import MapLibre
import UIKit
import os

@MainActor
final class EngineDriveAsphalt {

    /// Разобранная разница: правки слоёв и свет на объём.
    private struct Difference {
        var overrides: [DriveAsphalt.Override] = []
        var light: Double?
    }

    /// Разобранные разницы по имени ресурса: файл читается один раз на процесс.
    private static var cache: [String: Difference] = [:]

    /// Какая разница лежит на стиле (nil — никакая).
    private var appliedResource: String?
    /// Прежние выражения: слой, ключ KVC, значение.
    private var originals: [(layer: String, key: String, value: NSExpression?)] = []
    /// Прежняя сила света на объём (nil — свет не трогали).
    private var originalLight: NSExpression?
    /// Как покрашены постоянные слои линии маршрута: тема и сила свечения
    /// (nil — как в стиле).
    private var routePainted: (daylight: Bool, glow: Double)?

    /// Новый стиль: в нём всё обычное, запомненное — от прежнего.
    func styleLoaded() {
        appliedResource = nil
        originals = []
        originalLight = nil
        routePainted = nil
    }

    /// `car` — стиль машины (экран машины, плитка): своя разница вместо
    /// разницы поездки, свои линия маршрута и подпись камеры. nil — телефон.
    func update(active: Bool, daylight: Bool, car: CarMapStyle? = nil, in style: MLNStyle) {
        let wanted = active ? (car?.resource(daylight: daylight) ?? DriveAsphalt.resource(daylight: daylight)) : nil
        if wanted != appliedResource {
            restore(in: style)
            appliedResource = wanted
            if let wanted { apply(resource: wanted, cameraLabel: car?.cameraLabel(daylight: daylight, active: active), in: style) }
        }
        let routeDaylight = car?.routeDaylight(daylight: daylight, active: active)
            ?? DriveAsphalt.routeDaylight(daylight: daylight, active: active)
        let glow = car?.glowOpacity(daylight: daylight)
            ?? (routeDaylight ? RouteColors.glowOpacity.day : RouteColors.glowOpacity.night)
        // Стиль собран с линией темы дня; перекрашивать — только если нужна другая.
        let painted = routePainted ?? (daylight, daylight ? RouteColors.glowOpacity.day : RouteColors.glowOpacity.night)
        if painted.daylight != routeDaylight || painted.glow != glow {
            routePainted = (routeDaylight, glow)
            paintRoute(daylight: routeDaylight, glow: glow, in: style)
        }
    }

    private static func difference(_ name: String) -> Difference {
        if let hit = cache[name] { return hit }
        var parsed = Difference()
        if let url = Bundle.main.url(forResource: name, withExtension: "json")
            ?? Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "MapStyle") {
            do {
                let data = try Data(contentsOf: url)
                parsed = Difference(overrides: try DriveAsphalt.overrides(from: data),
                                    light: try DriveAsphalt.lightIntensity(from: data))
            } catch {
                Log.app.error("разница стиля \(name, privacy: .public) не разобрана: \(String(describing: error), privacy: .public)")
            }
        } else {
            Log.app.error("разницы стиля \(name, privacy: .public) нет в бандле")
        }
        cache[name] = parsed
        return parsed
    }

    private func apply(resource: String, cameraLabel: (text: UInt32, halo: UInt32)?, in style: MLNStyle) {
        originals = []
        let transition = NSValue(mlnTransition: MLNTransition(duration: AppConfig.driveAsphaltTransitionSeconds,
                                                              delay: 0))
        let difference = Self.difference(resource)
        var items = difference.overrides.map { ($0.layer, $0.key, Self.expression($0.value)) }
        if let cameraLabel {
            items.append(("camera-label", "textColor", NSExpression(forConstantValue: Theme.rgb(cameraLabel.text))))
            items.append(("camera-label", "textHaloColor", NSExpression(forConstantValue: Theme.rgb(cameraLabel.halo))))
        }
        for (id, key, value) in items {
            // Слоя нет в стиле (выключены дома, места) — пропуск.
            guard let layer = style.layer(withIdentifier: id),
                  layer.responds(to: NSSelectorFromString(key)) else { continue }
            originals.append((id, key, layer.value(forKey: key) as? NSExpression))
            let transitionKey = key + "Transition"
            if layer.responds(to: NSSelectorFromString(transitionKey)) {
                layer.setValue(transition, forKey: transitionKey)
            }
            layer.setValue(value, forKey: key)
        }
        if let intensity = difference.light {
            let light = style.light
            originalLight = light.intensity
            light.intensity = NSExpression(forConstantValue: intensity)
            style.light = light
        }
    }

    /// Выражение правки: голый «#rrggbb» — цветом (DriveAsphalt.colourHex).
    private static func expression(_ value: Any) -> NSExpression {
        if let hex = DriveAsphalt.colourHex(value) { return NSExpression(forConstantValue: Theme.rgb(hex)) }
        return NSExpression(mglJSONObject: value)
    }

    private func restore(in style: MLNStyle) {
        for item in originals {
            guard let layer = style.layer(withIdentifier: item.layer) else { continue }
            layer.setValue(item.value, forKey: item.key)
        }
        originals = []
        if let originalLight {
            let light = style.light
            light.intensity = originalLight
            style.light = light
            self.originalLight = nil
        }
    }

    /// Постоянные слои линии маршрута — цветами темы. Окно у машины
    /// (route-near-*) красит EngineRouteLine своей краской по той же теме.
    private func paintRoute(daylight: Bool, glow glowOpacity: Double, in style: MLNStyle) {
        func colour(_ pair: RouteColors.Pair) -> NSExpression {
            NSExpression(forConstantValue: Theme.rgb(daylight ? pair.day : pair.night))
        }
        let lines: [(String, NSExpression)] = [
            ("route-traveled", colour(RouteColors.traveled)),
            ("route-case", colour(RouteColors.casing)),
            ("route", colour(RouteColors.body)),
            ("route-maneuver", colour(RouteColors.maneuver)),
            ("route-core", NSExpression(forConstantValue: UIColor.white.withAlphaComponent(
                daylight ? RouteColors.coreAlpha.day : RouteColors.coreAlpha.night))),
            ("route-traffic", NSExpression(mglJSONObject: [
                "match", ["get", "level"], 3, RouteColors.pick(RouteColors.jam, daylight: daylight),
                RouteColors.pick(RouteColors.slow, daylight: daylight)])),
        ]
        for (id, value) in lines {
            (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineColor = value
        }
        // Свечение (29.F): цвет — тела, сила — по теме линии. Окно у машины
        // (route-near-glow) берёт цвет из своей краски, силу — отсюда.
        (style.layer(withIdentifier: "route-glow") as? MLNLineStyleLayer)?.lineColor = colour(RouteColors.body)
        let glow = NSExpression(forConstantValue: glowOpacity)
        for id in ["route-glow", EngineMapStyle.routeNearLayers.glow] {
            (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineOpacity = glow
        }
        (style.layer(withIdentifier: "route-arrows") as? MLNSymbolStyleLayer)?.iconImageName =
            NSExpression(forConstantValue: EngineMapStyle.routeArrowImage(daylight: daylight))
        paintTraffic(daylight: daylight, in: style)
    }

    /// Пробки на улицах (33H3) — той же темой, что линия маршрута: на тёмном
    /// асфальте поездки дневные гранат и баклажан с тёмной каймой не держали
    /// и 1,5:1, ночной набор с ночной каймой держит ≥ 3:1 (PaletteTests).
    /// Выражения — те же, что стиль собирает в EngineMapStyle.trafficLayers:
    /// второго списка цветов нет. Растры шевронов обеих тем уже в стиле.
    /// Цвет из JSON стиля в выражение. Голая строка «#rrggbb» через
    /// mglJSONObject становится СТРОКОЙ, и движок падает на `mgl_color`
    /// (снимок 28.10); строки внутри match/case он разбирает сам.
    private static func colourExpression(_ json: Any) -> NSExpression {
        if let hex = json as? String, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) {
            return NSExpression(forConstantValue: Theme.rgb(value))
        }
        return NSExpression(mglJSONObject: json)
    }

    private func paintTraffic(daylight: Bool, in style: MLNStyle) {
        let ids = EngineMapStyle.trafficLayerIDs
        for layer in EngineMapStyle.trafficLayers(daylight: daylight) {
            guard let id = layer["id"] as? String else { continue }
            let paint = layer["paint"] as? [String: Any] ?? [:]
            let layout = layer["layout"] as? [String: Any] ?? [:]
            if id == ids.casing || id == ids.line, let line = style.layer(withIdentifier: id) as? MLNLineStyleLayer {
                if let colour = paint["line-color"] { line.lineColor = Self.colourExpression(colour) }
                if let opacity = paint["line-opacity"] { line.lineOpacity = NSExpression(mglJSONObject: opacity) }
            } else if id == ids.chevrons, let symbols = style.layer(withIdentifier: id) as? MLNSymbolStyleLayer,
                      let image = layout["icon-image"] {
                symbols.iconImageName = NSExpression(mglJSONObject: image)
            }
        }
    }
}
#endif
