//
//  DriveAsphalt.swift
//  RadarMap
//
//  Асфальт поездки (29.B, как у Amap): в поездке на крупных зумах полотно
//  тёмное серо-синее, разметка белая, кромки светлые — и днём тоже.
//
//  Стиль ради этого НЕ перезагружается (правило аудита 11.10: перезагрузка —
//  сама по себе пик и сброс тайлов ровно на старте поездки). Генератор стиля
//  (server/omt/make_style.py --app) пишет рядом с каждым стилем разницу
//  поездки — `map_drive_<тема>.json`: {слой: {свойство цвета: выражение}}.
//  Выражения сами плавные по зуму: до 16-го цвет обычный, к 17-му — цвет
//  поездки. Приложение кладёт их свойствами слоёв на старте поездки и
//  возвращает прежние на остановке (EngineDriveAsphalt).
//
//  Линия маршрута в поездке — ночным набором RouteColors и днём: светлое
//  тело держит 3:1 на тёмном полотне, тёмная кайма — на светлом асфальте
//  обзора и на земле (palette_check.measure_drive). Дневное синее тело на
//  тёмном асфальте давало 1,8:1.
//
//  Экран машины и плитка панели кладут свою разницу того же вида —
//  `map_car_<тема>.json` (CarMapStyle, 40J): кроме цветов в ней высота
//  домов, сила свечения магистрали, земля и свет на объём.
//
//  Чистая логика — покрыто DriveAsphaltTests.
//

import Foundation

nonisolated enum DriveAsphalt {

    /// Одна правка: свойство цвета слоя и его выражение поездки (JSON стиля).
    struct Override: @unchecked Sendable {
        let layer: String
        /// Свойство стиля («line-color»).
        let property: String
        /// Ключ KVC слоя MapLibre («lineColor»).
        let key: String
        /// Выражение в JSON стиля — для NSExpression(mglJSONObject:).
        let value: Any
    }

    enum Failure: Error, Equatable {
        case notAnObject
        case unknownProperty(String)
    }

    /// Имя ресурса разницы для темы.
    static func resource(daylight: Bool) -> String {
        daylight ? "map_drive_light" : "map_drive_dark"
    }

    /// Ключ KVC слоя MapLibre для свойства стиля. Только известные
    /// свойства: неизвестный ключ KVC уронил бы приложение исключением.
    /// Цвета — у поездки и машины; земля, высота домов и прозрачность линии —
    /// только у машины (map_car_*).
    static func key(for property: String) -> String? {
        switch property {
        case "background-color":      return "backgroundColor"
        case "fill-extrusion-height": return "fillExtrusionHeight"
        case "line-opacity":          return "lineOpacity"
        case "line-color":           return "lineColor"
        case "fill-color":           return "fillColor"
        case "fill-outline-color":   return "fillOutlineColor"
        case "text-color":           return "textColor"
        case "text-halo-color":      return "textHaloColor"
        case "circle-color":         return "circleColor"
        case "icon-color":           return "iconColor"
        case "fill-extrusion-color": return "fillExtrusionColor"
        default:                     return nil
        }
    }

    /// Разбор ресурса. Неизвестное свойство — ошибка всего файла: генератор и
    /// приложение разошлись, и половина перекраски хуже, чем никакой.
    static func overrides(from data: Data) throws -> [Override] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layers = root["layers"] as? [String: Any] else { throw Failure.notAnObject }
        var out: [Override] = []
        for (layer, raw) in layers.sorted(by: { $0.key < $1.key }) {
            guard let props = raw as? [String: Any] else { throw Failure.notAnObject }
            for (property, value) in props.sorted(by: { $0.key < $1.key }) {
                guard let key = key(for: property) else { throw Failure.unknownProperty(property) }
                out.append(Override(layer: layer, property: property, key: key, value: value))
            }
        }
        return out
    }

    /// Сила света на объём из разницы («light»: {"intensity": …}); nil — свет
    /// стиля как есть. Другие ключи света не поддержаны — ошибка файла.
    static func lightIntensity(from data: Data) throws -> Double? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.notAnObject
        }
        guard let light = root["light"] else { return nil }
        guard let props = light as? [String: Any] else { throw Failure.notAnObject }
        for key in props.keys where key != "intensity" { throw Failure.unknownProperty("light." + key) }
        guard let raw = props["intensity"] else { return nil }
        guard let number = raw as? NSNumber else { throw Failure.unknownProperty("light.intensity") }
        return number.doubleValue
    }

    /// Переход при наложении разницы, с. Первое наложение после загрузки
    /// стиля — сразу: в машине разница кладётся на каждую загрузку (машина
    /// подключилась, день сменился ночью, пришёл подписанный набор), и 0,6 с
    /// телефонной палитры перетекали в машинную на глазах. Анимация — только
    /// для настоящего переключения на показанной карте (старт поездки).
    static func transitionSeconds(firstAfterStyleLoad: Bool) -> TimeInterval {
        firstAfterStyleLoad ? 0 : AppConfig.driveAsphaltTransitionSeconds
    }

    /// Голый цвет «#rrggbb» в разнице — число: строку движок принял бы
    /// за строку, а не цвет, и упал бы на `mgl_color` (снимок 28.10).
    /// Внутри выражений (match, step, interpolate) он разбирает строки сам.
    static func colourHex(_ value: Any) -> UInt32? {
        guard let text = value as? String, text.count == 7, text.hasPrefix("#") else { return nil }
        return UInt32(text.dropFirst(), radix: 16)
    }

    /// Включён ли асфальт поездки: поездка и новая карта (у прежнего стиля
    /// своих слоёв асфальта нет).
    static func isActive(driving: Bool, modernStyle: Bool) -> Bool {
        driving && modernStyle
    }

    /// Тема линии маршрута: в поездке — ночная и днём (см. шапку).
    static func routeDaylight(daylight: Bool, active: Bool) -> Bool {
        daylight && !active
    }
}
