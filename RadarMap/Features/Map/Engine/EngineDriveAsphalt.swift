//
//  EngineDriveAsphalt.swift
//  RadarMap
//
//  Асфальт поездки на живом стиле (29.B): разница `map_drive_<тема>.json`
//  кладётся свойствами слоёв на старте поездки и снимается на остановке —
//  стиль не перезагружается. Прежние значения запоминаются при первой
//  правке и возвращаются как были. Тут же — тема линии маршрута: в поездке
//  её постоянные слои (остаток линии, кайма, пройденное, середина, стрелки)
//  берут ночной набор и днём (DriveAsphalt.routeDaylight).
//
//  Пишется только на смене режима или стиля — на тике ничего.
//

#if canImport(MapLibre)
import MapLibre
import UIKit
import os

@MainActor
final class EngineDriveAsphalt {

    /// Разобранные разницы по теме: файл читается один раз на процесс.
    private static var cache: [Bool: [DriveAsphalt.Override]] = [:]

    private var asphaltOn = false
    /// Прежние выражения: слой, ключ KVC, значение.
    private var originals: [(layer: String, key: String, value: NSExpression?)] = []
    /// Тема, в которой покрашены постоянные слои линии маршрута (nil — как в стиле).
    private var routePainted: Bool?

    /// Новый стиль: в нём всё обычное, запомненное — от прежнего.
    func styleLoaded() {
        asphaltOn = false
        originals = []
        routePainted = nil
    }

    func update(active: Bool, daylight: Bool, in style: MLNStyle) {
        if active != asphaltOn {
            asphaltOn = active
            if active { apply(daylight: daylight, in: style) } else { restore(in: style) }
        }
        let routeDaylight = DriveAsphalt.routeDaylight(daylight: daylight, active: active)
        // Стиль собран с линией темы дня; перекрашивать — только если нужна другая.
        if routePainted ?? daylight != routeDaylight {
            routePainted = routeDaylight
            paintRoute(daylight: routeDaylight, in: style)
        }
    }

    private static func overrides(daylight: Bool) -> [DriveAsphalt.Override] {
        if let hit = cache[daylight] { return hit }
        let name = DriveAsphalt.resource(daylight: daylight)
        var parsed: [DriveAsphalt.Override] = []
        if let url = Bundle.main.url(forResource: name, withExtension: "json")
            ?? Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "MapStyle") {
            do {
                parsed = try DriveAsphalt.overrides(from: Data(contentsOf: url))
            } catch {
                Log.app.error("асфальт поездки \(name, privacy: .public) не разобран: \(String(describing: error), privacy: .public)")
            }
        } else {
            Log.app.error("асфальта поездки \(name, privacy: .public) нет в бандле")
        }
        cache[daylight] = parsed
        return parsed
    }

    private func apply(daylight: Bool, in style: MLNStyle) {
        originals = []
        let transition = NSValue(mlnTransition: MLNTransition(duration: AppConfig.driveAsphaltTransitionSeconds,
                                                              delay: 0))
        for item in Self.overrides(daylight: daylight) {
            // Слоя нет в стиле (выключены дома, места) — пропуск.
            guard let layer = style.layer(withIdentifier: item.layer),
                  layer.responds(to: NSSelectorFromString(item.key)) else { continue }
            originals.append((item.layer, item.key, layer.value(forKey: item.key) as? NSExpression))
            let transitionKey = item.key + "Transition"
            if layer.responds(to: NSSelectorFromString(transitionKey)) {
                layer.setValue(transition, forKey: transitionKey)
            }
            layer.setValue(NSExpression(mglJSONObject: item.value), forKey: item.key)
        }
    }

    private func restore(in style: MLNStyle) {
        for item in originals {
            guard let layer = style.layer(withIdentifier: item.layer) else { continue }
            layer.setValue(item.value, forKey: item.key)
        }
        originals = []
    }

    /// Постоянные слои линии маршрута — цветами темы. Окно у машины
    /// (route-near-*) красит EngineRouteLine своей краской по той же теме.
    private func paintRoute(daylight: Bool, in style: MLNStyle) {
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
        (style.layer(withIdentifier: "route-arrows") as? MLNSymbolStyleLayer)?.iconImageName =
            NSExpression(forConstantValue: EngineMapStyle.routeArrowImage(daylight: daylight))
    }
}
#endif
