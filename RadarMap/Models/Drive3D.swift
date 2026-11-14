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
//  Плитка главного экрана машины (48) — тот же облик со своим потолком
//  наклона, бюджетом пересчётов и ступенями TileLevel; ленту второй карты
//  она берёт готовой (EngineRibbonShare), а не считает заново.
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

    /// Где карта: телефон в поездке, экран машины, плитка панели (с 48 — тот
    /// же облик, по своему бюджету и ступеням `TileLevel`).
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

    /// День: синий маршрута (`RouteColors.body`), разметка на нём 5,7:1; кант белый.
    static let day = Ribbon(fill: RouteColors.body.day, edge: 0xFFFFFF, edgeOpacity: 0.7)
    /// Ночь: синяя заливка `accentFill` без засветки, разметка 4:1; кант еле заметный.
    static let night = Ribbon(fill: WidgetPalette.accentFill.dark, edge: 0x9CC3FF, edgeOpacity: 0.3)

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

    /// Сужение к полосам у манёвра — везде, кроме горячего телефона (без
    /// пересчётов к манёвру — только заливка). Плитка (48) сужается тоже: на
    /// 375 точках при 45° полоса у манёвра в 110 м — 7,9 точки, три полосы →
    /// одна читаются; на тёплом телефоне плитка рисует с `.reduced`
    /// (`tilePerformance`) и сужения нет.
    static func narrows(surface: Surface, hot: Bool) -> Bool { !hot }

    /// Лента вообще: везде, кроме плитки на ступени `.flat` (горячий телефон) —
    /// там палитра 3D и прежняя линия маршрута, ни проб тайла, ни расчёта.
    static func ribbon(surface: Surface, tile: TileLevel = .full) -> Bool {
        surface != .dashboard || tile != .flat
    }

    /// Шевроны внутри ленты — не на плитке и не на горячем телефоне (лишняя
    /// раскладка символов, как у шевронов пробок).
    static func chevrons(surface: Surface, hot: Bool = false) -> Bool { surface != .dashboard && !hot }

    // MARK: - Плитка главного экрана машины (48)

    /// Ступень плитки. Плитка — вторая карта рядом с музыкой и смотрится
    /// мельком, поэтому упрощается ПЕРВОЙ, раньше экрана машины:
    /// • `full` — наклон до carPlayDashboard3DMaxPitch, низкие дома, лента с сужением;
    /// • `lite` — телефон тёплый (`.fair`) или режим энергосбережения: карта
    ///   рисует как горячая (`.reduced`: плоские дома, реже кадры, без сужения),
    ///   наклон и лента остаются; экран машины в это время — полный;
    /// • `flat` — горячий телефон (`.serious` и выше): плоско, без ленты — как
    ///   экран машины на горячем, только ещё и без ленты.
    enum TileLevel: Equatable, Sendable { case full, lite, flat }

    static func tileLevel(performance: PerformanceMode, warm: Bool, lowPower: Bool) -> TileLevel {
        if performance != .full { return .flat }
        return warm || lowPower ? .lite : .full
    }

    /// С какой ступенью рисует карта плитки.
    static func tilePerformance(_ level: TileLevel, mode: PerformanceMode) -> PerformanceMode {
        level == .lite && mode == .full ? .reduced : mode
    }

    /// Бюджет пересчётов ленты: экран машины и телефон — `.full`, плитка —
    /// `.tile` (реже по пути, повторы с 3 с, срез крупнее, проб меньше).
    struct Budget: Equatable, Sendable {
        var recomputeMeters: Double
        var tailMarginMeters: Double
        var retrySeconds: Double
        /// Шаг среза под машиной — не меньше стольких секунд пути.
        var cutSeconds: Double
        var probeLimit: Int

        static let full = Budget(recomputeMeters: AppConfig.drive3DRecomputeMeters,
                                 tailMarginMeters: AppConfig.drive3DTailMarginMeters,
                                 retrySeconds: AppConfig.drive3DRetrySeconds,
                                 cutSeconds: AppConfig.drive3DCutStepSeconds,
                                 probeLimit: AppConfig.drive3DProbeLimit)
        /// Экран машины: как телефон, но срез не чаще секунды пути (аудит
        /// 05.11, №3): каждая смена фильтра — перераскладка тайлов источника
        /// ленты на воркерах, а под значком и кольцом компаса шаг не виден.
        static let car = Budget(recomputeMeters: AppConfig.drive3DRecomputeMeters,
                                tailMarginMeters: AppConfig.drive3DTailMarginMeters,
                                retrySeconds: AppConfig.drive3DRetrySeconds,
                                cutSeconds: AppConfig.drive3DCarCutStepSeconds,
                                probeLimit: AppConfig.drive3DProbeLimit)
        static let tile = Budget(recomputeMeters: AppConfig.drive3DTileRecomputeMeters,
                                 tailMarginMeters: AppConfig.drive3DTileTailMarginMeters,
                                 retrySeconds: AppConfig.drive3DTileRetrySeconds,
                                 cutSeconds: AppConfig.drive3DCarCutStepSeconds,
                                 probeLimit: AppConfig.drive3DTileProbeLimit)
    }

    static func budget(surface: Surface) -> Budget {
        switch surface {
        case .phone: .full
        case .car: .car
        case .dashboard: .tile
        }
    }

    /// Кто считает общую ленту (EngineRibbonShare). Телефон и экран машины —
    /// всегда; плитка — только если их карта не применялась `yield` секунд:
    /// иначе она берёт их готовый расчёт, а не щупает тайлы второй раз.
    static func computes(surface: Surface, sincePrimary: TimeInterval,
                         yield: TimeInterval = AppConfig.drive3DShareYieldSeconds) -> Bool {
        surface != .dashboard || sincePrimary >= yield
    }

    /// Умолчание настройки по классу телефона: на A12/A13 (iPhone11,x и
    /// iPhone12,x — XS/XR, 11, SE 2) — выключено, новее и симулятор — включено.
    /// iPad (приложение для iPhone в режиме совместимости) — как старый: выключено.
    static func defaultEnabled(machine: String) -> Bool {
        if machine.hasPrefix("iPad") { return false }
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
    /// борта эстакад — и бледная линия пройденного: это весь
    /// маршрут целиком, вблизи лента её заменяет, а при отдалении карты она
    /// проступала старым маршрутом за машиной. Камеры, разметка, стрелки
    /// полос, светофоры, заправки по пути остаются. Автомобильный тоннель —
    /// тоже (владелец, 14.11): это дорога, по которой ведёт маршрут.
    static let traveledLayer = "route-traveled"
    /// Блик середины и тёмный отрезок манёвра на линии: в 3D линия одного
    /// цвета — как лента, белая жила и две полосы тона читались трубкой.
    static let lineAccentLayers = ["route-core", "route-near-core", "route-maneuver", "route-near-maneuver"]
    static let hiddenLayers: [String] = [
        traveledLayer,
    ] + lineAccentLayers + [
        "radar-roads-gutter", "radar-asphalt-grain", "radar-trunk-glow", "radar-island-hatch",
        "railway-transit-hatching", "railway-service-hatching", "railway-hatching", "radar-oneway",
        "trees", "radar-tree-shadow", "radar-tree", "radar-tree-light", "radar-tree-3d",
        "radar-barrier-3d",
    ]

    // MARK: - Линия за лентой и манёвр (70)

    /// Точка пробы: на экране и в запасе вокруг него. Запрос признаков не
    /// режется кадром — отвечает, сколько загружено тайлов.
    static func probeInReach(x: Double, y: Double, width: Double, height: Double) -> Bool {
        let reach = 2 * max(width, height)
        return x.isFinite && y.isFinite && x >= -reach && x <= width + reach && y >= -reach && y <= height + reach / 2
    }

    /// Белая стрелка манёвра — только где манёвр не показан лентой: на
    /// ленте его показывает её сужение и изгиб, а стрелка лежала посреди неё
    /// белым пятном. Без ленты (`ribbonEnd` nil) — как раньше.
    static func maneuverArrowShown(ribbonEnd: Double?, maneuver: Double?) -> Bool {
        guard let ribbonEnd, let maneuver else { return true }
        return maneuver > ribbonEnd - AppConfig.drive3DEndTaperMeters
    }

    /// Точек на метр на зуме (широта Ташкента: стиль задаёт ширину числами).
    static func pointsPerMeter(zoom: Double, latitude: Double = 41.3) -> Double {
        512 * pow(2, zoom) / (40_075_016.686 * cos(latitude * .pi / 180))
    }

    /// Толщина канта ленты, точки.
    static func edgeWidth(zoom: Double, daylight: Bool) -> Double {
        let far = daylight ? 0.9 : 0.7, near = daylight ? 1.2 : 0.9
        if zoom <= 16 { return 0.5 }
        if zoom <= 18 { return 0.5 + (far - 0.5) * (zoom - 16) / 2 }
        return far + (near - far) * min(1, (zoom - 18) / 2)
    }

    /// Толщина линии за лентой: в метрах полосы (drive3DTailMeters) — та же,
    /// что конец ленты на любом зуме и под любым наклоном, — и не тоньше
    /// жилы дальнего плана. `casing` — с кантом по обе стороны.
    static func tailWidth(casing: Bool = false, daylight: Bool = true) -> [Any] {
        let floor = AppConfig.drive3DSpineFarPoints
        let meters = AppConfig.drive3DTailMeters
        let lock = log2(floor / (meters * pointsPerMeter(zoom: 0)))
        var out: [Any] = ["interpolate", ["exponential", 2], ["zoom"]]
        for zoom in [15, lock, 18, 20].sorted() {
            let body = max(floor, meters * pointsPerMeter(zoom: zoom))
            out += [zoom, body + (casing ? 2 * edgeWidth(zoom: zoom, daylight: daylight) : 0)]
        }
        return out
    }

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
        /// Попыток подряд без готового расчёта — повтор с удвоением задержки.
        var attempts = 1
        /// Конец прощупанного не вырос (тоннель, пробел без лент, финиш): до
        /// проезда за него — ни проб, ни записи источника.
        var stalledEnd: Double?
        /// Начало перестроения, взятое на входе в окно подъезда: торможение к
        /// повороту не сдвигает его в последующих расчётах до манёвра.
        var shiftStart: Double?
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
                               narrowing: Bool, sinceAttempt: TimeInterval = .infinity,
                               budget: Budget = .full) -> Bool {
        guard let last else { return true }
        if last.route != route || last.narrowing != narrowing || last.maneuver != maneuver { return true }
        if let stalled = last.stalledEnd, car < stalled + AppConfig.drive3DStallPassMeters { return false }
        let retry = sinceAttempt >= retryDelay(attempts: last.attempts, base: budget.retrySeconds)
        if !last.complete { return retry }
        if let end = last.verifiedEnd, car >= end - budget.tailMarginMeters { return retry }
        if last.inWindow, let maneuver, car < maneuver { return false }
        if car < last.from - 1 || car - last.from >= budget.recomputeMeters { return true }
        if let maneuver, !last.inWindow, car >= maneuver - window { return true }
        return false
    }

    /// Задержка повтора: 1,5 с, удвоение на каждую неудачу, потолок 12 с.
    static func retryDelay(attempts: Int, base: TimeInterval = AppConfig.drive3DRetrySeconds) -> TimeInterval {
        min(AppConfig.drive3DRetryMaxSeconds, base * pow(2, Double(max(0, attempts - 1))))
    }

    /// Что делать с пришедшим расчётом. Готов и прощупал дальше прежнего (на
    /// шаг станции и больше) — кладём на карту. Не дальше прежнего или не
    /// готов, когда прежняя лента есть, — это тоннель, пробел без лент или
    /// финиш: источник не трогаем, повторов нет до проезда прежнего конца.
    /// Не готов без прежней ленты — неполный, повтор с удвоением задержки.
    enum Settle: Equatable, Sendable { case write, stalled, incomplete }

    static func settle(_ plan: inout Plan, ready: Bool, end: Double, previousEnd: Double?, car: Double,
                       tailMargin: Double = AppConfig.drive3DTailMarginMeters) -> Settle {
        if let previousEnd, !ready || end < previousEnd + AppConfig.drive3DStationMeters {
            plan.complete = true
            plan.verifiedEnd = previousEnd
            // Застой — только у самого конца: вдали (пересчёт раз в 250 м)
            // прежняя лента просто остаётся, а у конца её ещё попробуют нарастить.
            if car >= previousEnd - tailMargin { plan.stalledEnd = previousEnd }
            return .stalled
        }
        guard ready else { plan.complete = false; return .incomplete }
        plan.complete = true
        plan.verifiedEnd = end
        plan.stalledEnd = nil
        return .write
    }

    /// Лента на карте — только пока машина не подъехала к её концу: дальше
    /// начало хвоста оказалось бы за машиной (карта в осмотре, панорама в
    /// машине, тоннель — пересчёта нет), а его источник срезом не режется.
    /// Показывается линия маршрута, её срез идёт под машиной всегда.
    static func showsRibbon(ready: Bool, car: Double, verifiedEnd: Double,
                            overlap: Double = AppConfig.drive3DTailOverlapMeters) -> Bool {
        ready && car < verifiedEnd - overlap
    }

    static func inWindow(car: Double, maneuver: Double?, window: Double) -> Bool {
        maneuver.map { car >= $0 - window } ?? false
    }

    /// Шаг среза под машиной, м: не мельче 8 м и `seconds` пути (телефон —
    /// полсекунды, машина и плитка — секунда, Budget), на горячем — втрое крупнее.
    static func cutStep(speedMps: Double, hot: Bool,
                        seconds: Double = AppConfig.drive3DCutStepSeconds) -> Double {
        let base = max(AppConfig.drive3DCutStepMeters, max(0, speedMps) * seconds)
        return hot ? base * AppConfig.drive3DCutHotFactor : base
    }

    /// Допуск границы ленты от машины, м: полкуска, точки под значком и не чаще шага бюджета (смена фильтра — перераскладка тайлов).
    static func cutTolerance(metersPerPoint: Double, speedMps: Double, hot: Bool,
                             seconds: Double = AppConfig.drive3DCutStepSeconds) -> Double {
        let screen = max(0, metersPerPoint.isFinite ? metersPerPoint : 0) * AppConfig.drive3DCutPoints
        let budget = (cutStep(speedMps: speedMps, hot: false, seconds: seconds) + AppConfig.drive3DCutStepMeters) / 2
        let base = max(AppConfig.drive3DCutStepMeters / 2 + 0.5, screen, budget)
        return hot ? base * AppConfig.drive3DCutHotFactor : base
    }

    /// Новый порог фильтра ленты (прячутся куски с концом ≤ порога), когда граница ушла от машины дальше допуска; nil — оставить.
    static func ribbonCut(applied: Double?, car: Double, ends: [Double], tolerance: Double) -> Double? {
        func lastEnd(atMost value: Double) -> Double? {
            var lo = 0, hi = ends.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if ends[mid] <= value { lo = mid + 1 } else { hi = mid }
            }
            return lo > 0 ? ends[lo - 1] : nil
        }
        let wanted = lastEnd(atMost: car + tolerance) ?? -1
        guard let applied else { return wanted }
        guard wanted != applied else { return nil }
        let boundary = lastEnd(atMost: applied) ?? -.infinity
        return abs(boundary - car) > tolerance ? wanted : nil
    }
}
