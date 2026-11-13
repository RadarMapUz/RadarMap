//
//  CameraMarkerLook.swift
//  RadarMap
//
//  Облик камеры на карте — вариант C «Точка» (владелец, 13.11, задача 90).
//
//  Владелец о прежнем облике: «один красный, все радары одинаковые, только
//  треногу по-другому нужно отмечать». До 13.11 у всех камер, треноги и
//  передвижного радара был один значок «Монета», а камера на пути краснела —
//  маршрут по проспекту становился красной цепочкой. Теперь:
//    * стационарные (камера, радар, интеллектуальная) — один облик:
//      вне пути — точка 11 pt без глифа, на пути — графитовая булавка с
//      глифом камеры, тревога — красная булавка с ореолом;
//    * тренога и передвижной радар — янтарный ромб в полный размер всегда:
//      точка возникла только что, и правила у неё другие (`isSudden`);
//    * пост ДПС — та же точка и булавка цвета поста, ДТП — красный треугольник;
//    * своя камера вне пути — зелёная точка, на пути — галочка поверх.
//  Красный — только у тревоги (и у ДТП).
//
//  Ни одна камера не пропадает: точка видна на любом полотне в обе темы
//  (заливка или кант ≥ 3:1, тест), значок рисуется поверх подписей.
//  Понижение — по пути и расстоянию, никогда по направлению.
//
//  Булавка стоит остриём на точке камеры (`anchor` = bottom): ореол
//  тревоги и пометки сдвинуты к её голове.
//
//  Чистая логика; CameraMarkerLookTests.
//

import Foundation

nonisolated enum CameraMarkerLook {

    enum Tier: String, Equatable, Sendable {
        case calm, path, alert
    }

    /// Форма значка на карте.
    enum Figure: String, Equatable, Sendable {
        /// Точка вне пути, булавка на пути и в тревоге.
        case pin
        /// Тренога и передвижной радар.
        case diamond
        /// ДТП.
        case triangle
    }

    static func figure(_ glyph: CameraGlyph) -> Figure {
        switch glyph {
        case .tripod, .mobileRadar: return .diamond
        case .accident:             return .triangle
        case .camera, .post, .other: return .pin
        }
    }

    // MARK: - Цвета

    /// Графит спокойной камеры — днём тёмный на светлой карте, ночью светлый
    /// на тёмной. Кант — наоборот.
    static let neutralDay = "#3D4652"
    static let neutralNight = "#AEB6C2"
    static let neutralDayRGB: UInt32 = 0x3D4652
    static let neutralNightRGB: UInt32 = 0xAEB6C2
    /// Кант точки ночью: белый кант на тёмной карте горел бы ярче тревоги.
    static let calmNightInkRGB: UInt32 = WidgetPalette.alertSurface
    /// Булавка камеры на пути ночью — тёмный графит с белым кантом.
    static let pathNightRGB: UInt32 = 0x2B323B
    /// Тревога — красный камеры.
    static let alertRGB: UInt32 = CameraGlyph.camera.fillRGB
    /// Своя камера вне пути: днём — заливка «нормы», ночью — её светлая пара.
    static let ownDayRGB: UInt32 = WidgetPalette.successFill.light
    static let ownNightRGB: UInt32 = WidgetPalette.success.dark
    /// Кант ромба днём — тёмный (янтарь на светлой карте без него тонет),
    /// снаружи ещё белая кромка.
    static let liveRimDayRGB: UInt32 = 0x1C1C1E

    // MARK: - Растры

    /// Облик значка: рисует CameraIconArt.marker (CameraMarkerArt).
    struct Raster: Equatable, Sendable {
        enum Shape: Equatable, Sendable { case dot, pin, diamond, triangle }
        let suffix: String
        let shape: Shape
        /// Сторона (pt): диаметр точки, головы булавки, ромба, треугольника.
        let side: Double
        let fill: UInt32
        let ink: UInt32
        let rim: UInt32
        /// Внешняя белая кромка (ромб днём).
        var outer: UInt32?
        /// Пунктирный кант — неподтверждённая отметка водителей.
        var dashed = false
    }

    static let dotSide: Double = 11
    static let pinSide: Double = 28
    static let pinAlertSide: Double = 36
    static let diamondSide: Double = 30
    static let diamondAlertSide: Double = 38
    static let triangleSide: Double = 28
    static let triangleCalmSide: Double = 24
    static let triangleAlertSide: Double = 36

    /// Голова булавки над остриём: остриё — на 0.32 стороны ниже головы.
    static let pinTipShare: Double = 0.32

    /// Центр головы булавки над точкой камеры (pt).
    static func pinHeadLift(side: Double) -> Double { side * (0.5 + pinTipShare) }

    /// Все облики значка глифа на карте (имя картинки = основа + suffix).
    static func rasters(_ glyph: CameraGlyph) -> [Raster] {
        let white: UInt32 = 0xFFFFFF
        switch figure(glyph) {
        case .pin:
            let calmDay = glyph == .camera ? neutralDayRGB : glyph.fillRGB
            let calmNight = glyph == .camera ? neutralNightRGB : 0x8A96A3
            let pathDay = glyph == .camera ? neutralDayRGB : glyph.fillRGB
            let pathNight = glyph == .camera ? pathNightRGB : glyph.fillRGB
            return [
                Raster(suffix: "-calm-d", shape: .dot, side: dotSide, fill: calmDay, ink: white, rim: white),
                Raster(suffix: "-calm-n", shape: .dot, side: dotSide, fill: calmNight, ink: calmNightInkRGB,
                       rim: calmNightInkRGB),
                Raster(suffix: "-own-d", shape: .dot, side: dotSide, fill: ownDayRGB, ink: white, rim: white),
                Raster(suffix: "-own-n", shape: .dot, side: dotSide, fill: ownNightRGB, ink: calmNightInkRGB,
                       rim: calmNightInkRGB),
                Raster(suffix: "-d", shape: .pin, side: pinSide, fill: pathDay, ink: white, rim: white),
                Raster(suffix: "-n", shape: .pin, side: pinSide, fill: pathNight, ink: white, rim: white),
                Raster(suffix: "-alert", shape: .pin, side: pinAlertSide, fill: alertRGB, ink: white, rim: white),
            ]
        case .diamond:
            let fill = glyph.fillRGB, ink = glyph.inkRGB
            return [
                Raster(suffix: "-d", shape: .diamond, side: diamondSide, fill: fill, ink: ink, rim: liveRimDayRGB,
                       outer: white),
                Raster(suffix: "-n", shape: .diamond, side: diamondSide, fill: fill, ink: ink, rim: white),
                Raster(suffix: "-ghost-d", shape: .diamond, side: diamondSide, fill: fill, ink: ink,
                       rim: liveRimDayRGB, dashed: true),
                Raster(suffix: "-ghost-n", shape: .diamond, side: diamondSide, fill: fill, ink: ink,
                       rim: white, dashed: true),
                Raster(suffix: "-alert", shape: .diamond, side: diamondAlertSide, fill: alertRGB, ink: white,
                       rim: white),
            ]
        case .triangle:
            let fill = glyph.fillRGB, ink = glyph.inkRGB
            return [
                Raster(suffix: "-calm", shape: .triangle, side: triangleCalmSide, fill: fill, ink: ink, rim: white),
                Raster(suffix: "", shape: .triangle, side: triangleSide, fill: fill, ink: ink, rim: white),
                Raster(suffix: "-alert", shape: .triangle, side: triangleAlertSide, fill: fill, ink: ink, rim: white),
            ]
        }
    }

    static let ghostBadge = "radar-badge-ghost"
    static let ownBadge = "radar-badge-own"

    /// Камеры на нашем пути. По маршруту — впереди по линии (проехавшие
    /// позади больше не наши); без маршрута или сверх него — ближайшая на
    /// нашей дороге.
    /// - Parameters:
    ///   - route: камеры маршрута и метры от старта по линии.
    ///   - progress: где мы на линии; nil — маршрута нет.
    ///   - passedTolerance: сколько метров позади камера ещё «наша» (GPS).
    static func pathIDs(route: [(id: Int, along: Double)], progress: Double?,
                        passedTolerance: Double, nearest: Int?) -> Set<Int> {
        var ids = Set<Int>()
        if let progress {
            for camera in route where camera.along >= progress - passedTolerance {
                ids.insert(camera.id)
            }
        }
        if let nearest { ids.insert(nearest) }
        return ids
    }

    static func tier(id: Int, alert: Int?, path: Set<Int>) -> Tier {
        if id == alert { return .alert }
        return path.contains(id) ? .path : .calm
    }

    /// Основа имени картинки в стиле: одна на глиф.
    static func imageBase(_ glyph: CameraGlyph) -> String {
        "radar-camera-" + glyph.rawValue
    }

    /// Имя картинки в стиле: основа + облик из `rasters`.
    /// - Parameters:
    ///   - own: своя камера (CameraFamiliarity) — у точки вне пути она зелёная.
    ///   - ghost: неподтверждённая отметка водителей — пунктир у ромба.
    static func icon(glyph: CameraGlyph, tier: Tier, daylight: Bool, own: Bool = false, ghost: Bool = false) -> String {
        imageBase(glyph) + suffix(figure(glyph), tier: tier, daylight: daylight, own: own, ghost: ghost)
    }

    static func suffix(_ figure: Figure, tier: Tier, daylight: Bool, own: Bool, ghost: Bool) -> String {
        let theme = daylight ? "-d" : "-n"
        switch (figure, tier) {
        case (_, .alert):         return "-alert"
        case (.pin, .calm):       return (own ? "-own" : "-calm") + theme
        case (.pin, .path):       return theme
        case (.diamond, _):       return (ghost ? "-ghost" : "") + theme
        case (.triangle, .calm):  return "-calm"
        case (.triangle, .path):  return ""
        }
    }

    /// Якорь значка: булавка стоит остриём на точке камеры, остальное — центром.
    static func anchor(_ figure: Figure, tier: Tier) -> String {
        figure == .pin && tier != .calm ? "bottom" : "center"
    }

    /// Рисовать ли отметку водителей «призраком» (полупрозрачной, с «?»).
    /// Своя свежая — нет (02.11): водитель только что видел треногу сам, а
    /// карта рисовала её сомнением, как чужой слух. Голос и запись проездов
    /// это не трогает — только картинка.
    static func isGhost(unconfirmed: Bool, own: Bool) -> Bool {
        unconfirmed && !own
    }

    /// Пометка поверх значка или пусто. У точки вне пути пометок нет: «?» и
    /// галочка 16 pt закрыли бы точку 11 pt; своя точка зелёная сама.
    static func badge(figure: Figure = .pin, tier: Tier, unconfirmed: Bool, familiar: Bool) -> String {
        if figure == .pin, tier == .calm { return "" }
        if unconfirmed { return ghostBadge }
        if familiar, tier != .alert { return ownBadge }
        return ""
    }

    /// Где пометка: правый верхний край головы булавки или фигуры (pt от точки).
    static func badgeOffset(_ figure: Figure, tier: Tier) -> (x: Double, y: Double) {
        switch figure {
        case .pin:
            let side = tier == .alert ? pinAlertSide : pinSide
            return (side * 0.42, -(pinHeadLift(side: side) + side * 0.42))
        case .diamond:
            let side = tier == .alert ? diamondAlertSide : diamondSide
            return (side * 0.42, -side * 0.42)
        case .triangle:
            let side = tier == .alert ? triangleAlertSide : tier == .calm ? triangleCalmSide : triangleSide
            return (side * 0.42, -side * 0.42)
        }
    }

    /// Ключ места пометки в стиле (`camera-badges`, `icon-offset` по match).
    static func badgePlace(_ figure: Figure, tier: Tier) -> String {
        figure.rawValue + "-" + tier.rawValue
    }

    static var badgePlaces: [(key: String, offset: (x: Double, y: Double))] {
        [Figure.pin, .diamond, .triangle].flatMap { figure in
            [Tier.calm, .path, .alert].map { (badgePlace(figure, tier: $0), badgeOffset(figure, tier: $0)) }
        }
    }

    /// Цвет точки мелкого масштаба — тот же язык, что значок: красный только
    /// у тревоги и ДТП, янтарь у отметок водителей, графит у остальных.
    static func dotColor(glyph: CameraGlyph, tier: Tier, daylight: Bool, own: Bool = false) -> String {
        if tier == .alert { return hex(alertRGB) }
        switch figure(glyph) {
        case .diamond, .triangle:
            return hex(glyph.fillRGB)
        case .pin:
            if tier == .calm, own { return hex(daylight ? ownDayRGB : ownNightRGB) }
            if glyph == .camera {
                if tier == .calm { return daylight ? neutralDay : neutralNight }
                return hex(daylight ? neutralDayRGB : pathNightRGB)
            }
            return hex(glyph.fillRGB)
        }
    }

    static func hex(_ rgb: UInt32) -> String { String(format: "#%06X", rgb) }

    /// Порядок рисования: тревога поверх всего, отметки водителей — поверх
    /// камер на пути, те — поверх спокойных (symbol-sort-key при
    /// allow-overlap: больший ключ лежит сверху).
    static func sortKey(_ tier: Tier, figure: Figure = .pin) -> Int {
        switch tier {
        case .alert: return 3
        case .path:  return figure == .diamond ? 2 : 1
        case .calm:  return figure == .diamond ? 2 : 0
        }
    }
}
