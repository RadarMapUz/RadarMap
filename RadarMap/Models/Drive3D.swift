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

    /// Лента вообще: на плитке её нет — там палитра 3D и прежняя линия
    /// маршрута (упрощённо: ни проб тайла, ни расчёта).
    static func ribbon(surface: Surface) -> Bool { surface != .dashboard }

    /// Шевроны внутри ленты — не на плитке и не на горячем телефоне (лишняя
    /// раскладка символов, как у шевронов пробок).
    static func chevrons(surface: Surface, hot: Bool = false) -> Bool { surface != .dashboard && !hot }

    /// Умолчание настройки по классу телефона: на A12/A13 (iPhone11,x и
    /// iPhone12,x — XS/XR, 11, SE 2) — выключено, новее и симулятор — включено.
    static func defaultEnabled(machine: String) -> Bool {
        guard machine.hasPrefix("iPhone"),
              let major = Int(machine.dropFirst("iPhone".count).prefix { $0.isNumber }) else { return true }
        return major >= 13
    }

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
        /// Тот же маршрут (счётчик смен линии).
        var route: Int
        /// Откуда участок, м от старта маршрута.
        var from: Double
        /// Ближайший манёвр, м от старта; nil — нет.
        var maneuver: Double?
        var narrowing: Bool
        /// Машина была в окне подъезда к манёвру.
        var inWindow: Bool
        /// Расчёт пришёл и годен (LanePath.Ribbon.isReady); false — ждём или
        /// карта была без лент тайла: повтор на ближайшем годном кадре.
        var complete = false
        /// Докуда прощупано (м); nil — ещё неизвестно.
        var verifiedEnd: Double?
    }

    /// Считать по карте можно только при слежении (не осмотр и не панорама),
    /// с зума, на котором видны ленты наших дорог, и на дорисованном кадре:
    /// иначе пробы видят обзор без тайлов или чужое место, и лента ложится
    /// запасной шириной по оси — наполовину на встречку.
    static func canCompute(following: Bool, zoom: Double, tilesComplete: Bool) -> Bool {
        following && zoom >= AppConfig.drive3DMinProbeZoom && tilesComplete
    }

    /// Пересчёт — на смене маршрута, манёвра, разрешения сужения, на входе в
    /// окно подъезда, у конца прощупанного и раз в drive3DRecomputeMeters
    /// пути; на тике — нет. В окне подъезда до манёвра по пути не
    /// пересчитываем: лента считана на 1,5 км, а пересчёт посреди
    /// перестроения перекраивал бы его под машиной. Неполный расчёт —
    /// повтор не чаще drive3DRetrySeconds.
    static func needsRecompute(last: Plan?, route: Int, car: Double, maneuver: Double?, window: Double,
                               narrowing: Bool, sinceAttempt: TimeInterval = .infinity) -> Bool {
        guard let last else { return true }
        if last.route != route || last.narrowing != narrowing || last.maneuver != maneuver { return true }
        let retry = sinceAttempt >= AppConfig.drive3DRetrySeconds
        if !last.complete { return retry }
        if let end = last.verifiedEnd, car >= end - AppConfig.drive3DTailMarginMeters { return retry }
        if last.inWindow, let maneuver, car < maneuver { return false }
        if car < last.from - 1 || car - last.from >= AppConfig.drive3DRecomputeMeters { return true }
        if let maneuver, !last.inWindow, car >= maneuver - window { return true }
        return false
    }

    static func inWindow(car: Double, maneuver: Double?, window: Double) -> Bool {
        maneuver.map { car >= $0 - window } ?? false
    }

    /// Шаг среза под машиной, м: не мельче 8 м и полсекунды пути, на горячем
    /// телефоне — втрое крупнее.
    static func cutStep(speedMps: Double, hot: Bool) -> Double {
        let base = max(AppConfig.drive3DCutStepMeters, max(0, speedMps) * AppConfig.drive3DCutStepSeconds)
        return hot ? base * AppConfig.drive3DCutHotFactor : base
    }

    /// Срез (фильтр слоя по концу куска) переставляется шагом, а не на каждом
    /// применении; назад (новый маршрут, откат прогресса) — сразу.
    static func cutDue(last: Double?, now: Double, step: Double = AppConfig.drive3DCutStepMeters) -> Bool {
        guard let last else { return true }
        return now - last >= step || now < last - 1
    }
}
