//
//  CameraMarkerLook.swift
//  RadarMap
//
//  Облик камеры на карте — вариант B «Спокойная карта» (владелец, 12.10).
//
//  До 12.10 каждая камера была одинаковым кругом цвета своего типа: полсотни
//  красных, жёлтых и фиолетовых точек читались сыпью, и камера впереди
//  выглядела так же, как камера в соседнем квартале («текущие иконки мне не
//  понравились»). Теперь цвет значит «на вашем пути», а не «какого типа»:
//    * спокойная — небольшой графитовый круг; тип читается по глифу;
//    * на пути — круг цвета типа: впереди по маршруту, а без маршрута —
//      ближайшая на нашей дороге (та же, что в HUD);
//    * тревога — крупный круг цвета типа с ореолом.
//  Пометки поверх — отдельным слоем: «?» у неподтверждённой отметки
//  водителей, галочка у своей камеры (голос молчит, см. CameraFamiliarity).
//  Тревога старше пометки своей камеры: идёт предупреждение — галочка лишняя.
//
//  Ни одна камера не пропадает: спокойная — тот же значок, только тише.
//  Правило то же, что у тиров на карте: понижение — по пути и расстоянию,
//  никогда по направлению.
//
//  Чистая логика; CameraMarkerLookTests.
//

import Foundation

nonisolated enum CameraMarkerLook {

    enum Tier: String, Equatable, Sendable {
        case calm, path, alert
    }

    /// Графит спокойной камеры — днём тёмный на светлой карте, ночью светлый
    /// на тёмной. Глиф — наоборот.
    static let neutralDay = "#3D4652"
    static let neutralNight = "#AEB6C2"
    static let neutralDayRGB: UInt32 = 0x3D4652
    static let neutralNightRGB: UInt32 = 0xAEB6C2
    /// Глиф и кант спокойной ночью: белый кант на тёмной карте горел бы
    /// ярче самой тревоги.
    static let calmNightInkRGB: UInt32 = 0x14181D

    /// Растр значка в стиле движка — значок «Монета» (CameraCoin, 29.C) одного
    /// из обликов. `fill`/`ink` nil — цвет типа и его глиф.
    struct Raster: Equatable, Sendable {
        let suffix: String
        let side: Double
        let fill: UInt32?
        let ink: UInt32?
        let rim: UInt32
    }

    /// Все облики значка на карте (имя картинки = символ типа + suffix).
    static let rasters: [Raster] = [
        // На пути — круг цвета типа.
        Raster(suffix: "", side: 30, fill: nil, ink: nil, rim: 0xFFFFFF),
        // Тревога — крупнее; ореол — слой camera-halo.
        Raster(suffix: "-alert", side: 38, fill: nil, ink: nil, rim: 0xFFFFFF),
        // Спокойная днём — графит, белый кант и глиф.
        Raster(suffix: "-calm-d", side: 24, fill: neutralDayRGB, ink: 0xFFFFFF, rim: 0xFFFFFF),
        // Ночью — светлый графит, тёмный кант и глиф.
        Raster(suffix: "-calm-n", side: 24, fill: neutralNightRGB, ink: calmNightInkRGB, rim: calmNightInkRGB),
    ]

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

    /// Имя картинки в стиле. Спокойная — своя на день и ночь: графит разный.
    /// Суффиксы — те же, что у `rasters`.
    static func icon(symbol: String, tier: Tier, daylight: Bool) -> String {
        switch tier {
        case .alert: return symbol + "-alert"
        case .path:  return symbol
        case .calm:  return symbol + (daylight ? "-calm-d" : "-calm-n")
        }
    }

    /// Пометка поверх значка или пусто.
    static func badge(tier: Tier, unconfirmed: Bool, familiar: Bool) -> String {
        if unconfirmed { return ghostBadge }
        if familiar, tier != .alert { return ownBadge }
        return ""
    }

    /// Цвет точки мелкого масштаба: тот же язык, что значок.
    static func dotColor(typeHex: String, tier: Tier, daylight: Bool) -> String {
        tier == .calm ? (daylight ? neutralDay : neutralNight) : typeHex
    }

    /// Порядок рисования: тревога поверх «на пути», те — поверх спокойных
    /// (symbol-sort-key при allow-overlap: больший ключ лежит сверху).
    static func sortKey(_ tier: Tier) -> Int {
        switch tier {
        case .calm:  return 0
        case .path:  return 1
        case .alert: return 2
        }
    }
}
