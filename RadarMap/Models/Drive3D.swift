//
//  Drive3D.swift
//  RadarMap
//
//  «Вождение 3D» (43, решение владельца по исследованию 42): в поездке на
//  телефоне и в машине — светлый тихий мир, серый асфальт с белой разметкой
//  и белыми кромками, низкие белые дома с мягким светом, дымка у горизонта;
//  ночью — тёмный графит без засветки. Маршрут — синей лентой во всю нашу
//  сторону проезжей части под разметкой, у манёвра — сужение к нужным
//  полосам (LanePath). Наклон — прежний (AppConfig.engineMapPitchDegrees).
//
//  Стиль не перезагружается: разница `map_drive3d_<тема>.json`
//  (make_style.py --app, D3_FILES) кладётся вместо разницы поездки или
//  машины тем же механизмом (EngineDriveAsphalt), украшения гасятся
//  видимостью слоёв. Горячий телефон: без сужения, без домов, теней и дымки.
//
//  Красный — только камера; пробки и Theme.route — прежние по смыслу.
//  Только картинка: оповещения, гейты и голос этого не читают.
//
//  Цвета ленты и их контраст — server/omt/palette_check.measure_drive3d
//  (test_palette_check сверяет копию), здесь — PaletteTests; логика —
//  Drive3DTests.
//

import Foundation

nonisolated enum Drive3D {

    /// Где карта: телефон в поездке, экран машины, плитка панели (упрощённо).
    /// Приборка — карта поездки, как была.
    enum Surface: Equatable, Sendable {
        case phone, car, dashboard
    }

    /// Лента маршрута: заливка (Theme.route поверх асфальта), кант и его
    /// непрозрачность. Непрозрачная заливка: полупрозрачные куски на стыке
    /// моста складывались в тёмные полосы (42).
    struct Ribbon: Equatable, Sendable {
        let fill: UInt32
        let edge: UInt32
        let edgeOpacity: Double
    }

    /// День: Theme.route #0B62D0 на 80 % поверх асфальта #848E9B; кант белый.
    static let day = Ribbon(fill: 0x236BC5, edge: 0xFFFFFF, edgeOpacity: 0.7)
    /// Ночь: #66A3FF на 47 % поверх #363D48; кант еле заметный, без свечения.
    static let night = Ribbon(fill: 0x4D6D9E, edge: 0x9CC3FF, edgeOpacity: 0.3)

    static func ribbon(daylight: Bool) -> Ribbon { daylight ? day : night }

    /// Имя ресурса разницы (как D3_FILES генератора).
    static func resource(daylight: Bool) -> String {
        daylight ? "map_drive3d_light" : "map_drive3d_dark"
    }

    /// Поверхность режима для настройки, поездки и экрана: телефон — только в
    /// поездке, машина и плитка — всегда (машина подключена — едем),
    /// приборка — нет.
    static func surface(enabled: Bool, phoneTrip: Bool) -> Surface? {
        enabled && phoneTrip ? .phone : nil
    }

    static func surface(enabled: Bool, car: CarPlaySurface) -> Surface? {
        guard enabled else { return nil }
        switch car {
        case .car: return .car
        case .dashboard: return .dashboard
        case .cluster: return nil
        }
    }

    /// Включён ли режим на карте: есть поверхность, едем и новая карта (у
    /// прежнего стиля нет наших слоёв).
    static func isActive(surface: Surface?, driving: Bool, modernStyle: Bool) -> Bool {
        surface != nil && driving && modernStyle
    }

    /// Сужение к полосам у манёвра: не на плитке (мала, полос не видно) и не
    /// на горячем телефоне (без пересчётов к манёвру — только заливка).
    static func narrows(surface: Surface, hot: Bool) -> Bool {
        surface != .dashboard && !hot
    }

    /// Шевроны внутри ленты — не на плитке.
    static func chevrons(surface: Surface) -> Bool { surface != .dashboard }

    /// Дымка у горизонта: на горячем телефоне гаснет вместе с домами и тенями.
    static func hazeShown(hot: Bool) -> Bool { !hot }

    /// Тема линии маршрута и пробок: асфальт днём светлый — дневной набор.
    static func routeDaylight(daylight: Bool) -> Bool { daylight }

    /// Свечение под линией — нет: ни днём, ни «прожектором» ночью.
    static let glowOpacity: Double = 0

    /// Украшения, которых нет в «тихом мире» на ходу: жёлоб, зерно асфальта,
    /// свечение магистрали, штриховки, стрелки одностороннего, деревья,
    /// тоннели поверх, борта эстакад. Камеры, разметка, стрелки полос,
    /// светофоры, заправки по пути остаются.
    static let hiddenLayers: [String] = [
        "radar-roads-gutter", "radar-asphalt-grain", "radar-trunk-glow", "radar-island-hatch",
        "railway-transit-hatching", "railway-service-hatching", "railway-hatching", "radar-oneway",
        "trees", "radar-tree-shadow", "radar-tree", "radar-tree-light", "radar-tree-3d",
        "radar-tunnel-case", "radar-tunnel", "radar-barrier-3d",
    ]

    // MARK: - Шевроны

    /// Шевроны только медленнее 60 км/ч, с памятью: на 57–60 они не мигают.
    struct ChevronGate: Equatable, Sendable {
        private(set) var shown = true

        mutating func update(speedKmh: Double) -> Bool {
            let limits = AppConfig.drive3DChevronMaxKmh
            if shown, speedKmh >= limits.hide { shown = false }
            else if !shown, speedKmh <= limits.show { shown = true }
            return shown
        }
    }

    // MARK: - Когда пересчитывать ленту

    /// Что лента учла при последнем расчёте.
    struct Plan: Equatable, Sendable {
        /// Тот же маршрут (ObjectIdentifier линии или счётчик).
        var route: Int
        /// Откуда участок, м от старта маршрута.
        var from: Double
        /// Ближайший манёвр, м от старта; nil — нет.
        var maneuver: Double?
        var narrowing: Bool
        /// Машина была в окне подъезда к манёвру.
        var inWindow: Bool
    }

    /// Пересчёт — на смене маршрута, манёвра, разрешения сужения, на входе в
    /// окно подъезда и раз в drive3DRecomputeMeters пути; на тике — нет.
    static func needsRecompute(last: Plan?, route: Int, car: Double, maneuver: Double?, window: Double,
                               narrowing: Bool) -> Bool {
        guard let last else { return true }
        if last.route != route || last.narrowing != narrowing || last.maneuver != maneuver { return true }
        if car < last.from - 1 || car - last.from >= AppConfig.drive3DRecomputeMeters { return true }
        if let maneuver, !last.inWindow, car >= maneuver - window { return true }
        return false
    }

    static func inWindow(car: Double, maneuver: Double?, window: Double) -> Bool {
        maneuver.map { car >= $0 - window } ?? false
    }

    /// Срез под машиной переписывается шагом, а не на каждом кадре; назад
    /// (новый маршрут, откат прогресса) — сразу.
    static func cutDue(last: Double?, now: Double) -> Bool {
        guard let last else { return true }
        return now - last >= AppConfig.drive3DCutStepMeters || now < last - 1
    }

    /// Срез, кратный шагу: лента начинается у машины, хвост — под значком.
    static func quantizedCut(_ along: Double) -> Double {
        let step = AppConfig.drive3DCutStepMeters
        return (max(0, along) / step).rounded(.down) * step
    }
}
