//
//  CarMapStyle.swift
//  RadarMap
//
//  Стиль карты в машине (40J, исследование 40F: «карта максимально красиво,
//  приятно на глаз на CarPlay»). Экран машины и плитка панели кладут вместо
//  разницы поездки свою — `map_car_<тема>.json` (make_style.py --app,
//  CAR_FILES), тем же механизмом без перезагрузки стиля (DriveAsphalt,
//  EngineDriveAsphalt). Телефон и приборка не меняются.
//
//  • A «Amap, доведённый» — по умолчанию: днём тёмный асфальт с 15-го зума
//    (окно 14→15 — трасса больше не серая), земля и дворы спокойнее, дома
//    светлее, ниже и без оттенков назначения, магистраль — тёплый графит.
//  • B «Светлая» — только DEBUG-ключом `-carMapStyle B`, для листа
//    сравнения: днём без тёмного асфальта, линия маршрута и пробки дневные.
//  • Ночь у обоих — N1 «без засветки»: серебристые имена, без свечения
//    магистрали, слабее свечение маршрута и пятно под машиной.
//
//  Цвета карты и их контраст — server/omt/palette_check.measure_car; цвета
//  поверх карты отсюда — CarMapStyleTests.
//

import Foundation

nonisolated enum CarMapStyle: String, CaseIterable, Sendable {
    case a = "A"
    case b = "B"

    /// Вариант этого запуска: в релизе — всегда A.
    static let current: CarMapStyle = {
        #if DEBUG
        launchChoice(arguments: ProcessInfo.processInfo.arguments)
        #else
        .a
        #endif
    }()

    /// `-carMapStyle B` — светлый вариант для снимков; иначе A.
    static func launchChoice(arguments: [String]) -> CarMapStyle {
        guard let index = arguments.firstIndex(of: "-carMapStyle"), index + 1 < arguments.count,
              let style = CarMapStyle(rawValue: arguments[index + 1].uppercased()) else { return .a }
        return style
    }

    /// Стиль машины — на экране машины и плитке; приборка остаётся картой
    /// поездки (вторая карта на движке, её облик здесь не решается).
    static func style(for surface: CarPlaySurface) -> CarMapStyle? {
        surface == .cluster ? nil : current
    }

    /// Имя ресурса разницы (как CAR_FILES генератора). Ночь у вариантов общая.
    func resource(daylight: Bool) -> String {
        guard daylight else { return "map_car_dark" }
        return self == .a ? "map_car_light" : "map_car_b_light"
    }

    /// Тёмный асфальт днём — у A; B днём светлый.
    var darkAsphaltByDay: Bool { self == .a }

    /// Тема линии маршрута, пробок и стрелок: на тёмном асфальте — ночная.
    func routeDaylight(daylight: Bool, active: Bool) -> Bool {
        daylight && !(active && darkAsphaltByDay)
    }

    /// Сила свечения под линией маршрута (N1: прожектор 0,55 ночью слепил).
    func glowOpacity(daylight: Bool) -> Double {
        guard daylight else { return AppConfig.carPlayRouteGlow.night }
        return self == .a ? AppConfig.carPlayRouteGlow.day : 0
    }

    /// Кольцо компаса у машины: у A — без букв (10 pt на экране машины не
    /// читались, но вертелись в центре внимания), у B — нет кольца.
    func compass(daylight: Bool) -> CompassRing.Look? {
        guard self == .a else { return nil }
        return CompassRing.Look(letters: false,
                                poolAlpha: daylight ? Double(AppConfig.compassPoolAlpha) : AppConfig.carPlayPoolAlphaNight)
    }

    /// Подпись «400 м» у камеры: днём на тёмном асфальте A — светлая с
    /// ореолом асфальта (белая наклейка на тёмной дороге резала глаз).
    /// nil — как в стиле.
    func cameraLabel(daylight: Bool, active: Bool) -> (text: UInt32, halo: UInt32)? {
        guard daylight, active, darkAsphaltByDay else { return nil }
        return (AppConfig.carPlayCameraLabelDay.text, AppConfig.carPlayCameraLabelDay.halo)
    }

    /// Множители размеров стиля: подписи улиц, мелкие подписи (щиты трасс,
    /// места, заправки) и линия маршрута.
    struct Scale: Equatable, Sendable {
        var streets: Double
        var small: Double
        var route: Double
    }

    /// Экран машины — крупнее телефона, плитка — чуть крупнее; приборка — как в стиле.
    static func scale(for surface: CarPlaySurface) -> Scale? {
        switch surface {
        case .car:
            Scale(streets: AppConfig.carPlayLabelScale, small: AppConfig.carPlaySmallLabelScale,
                  route: AppConfig.carPlayRouteWidthScale)
        case .dashboard:
            Scale(streets: AppConfig.carPlayDashboardLabelScale, small: AppConfig.carPlayDashboardLabelScale, route: 1)
        case .cluster:
            nil
        }
    }
}
