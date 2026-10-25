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

    /// Ключ KVC слоя MapLibre для свойства цвета стиля. Только известные
    /// свойства: неизвестный ключ KVC уронил бы приложение исключением.
    static func key(for property: String) -> String? {
        switch property {
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
