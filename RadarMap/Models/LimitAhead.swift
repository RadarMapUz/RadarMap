//
//  LimitAhead.swift
//  RadarMap
//
//  «Ограничение 40 через 200 метров» — смена лимита впереди.
//
//  Голос «Превышение скорости» звучит, когда лимит уже сменился и машина
//  уже едет быстрее, — то есть ровно тогда, когда камера на въезде в
//  сороковую зону уже щёлкнула. Здесь предупреждение заранее: на дороге
//  впереди лимит НИЖЕ текущего, и с нашей скоростью мы его превысим.
//
//  Правила — чтобы не ворчать и не врать:
//    * только снижение лимита: о повышении говорить незачем;
//    * только если мы едем быстрее нового лимита с допуском — едущему 35 в
//      сороковую зону сказать нечего;
//    * лимит подтверждают две пробы подряд (≥ 50 м новой дороги): одна точка
//      на перекрёстке со съездом — шум данных;
//    * одна фраза на одну смену (место и значение), не чаще раза в минуту.
//  Пробы берёт SpeedLimitService: по линии маршрута или — без маршрута —
//  прямо по оси текущей дороги, и тогда только пока ось рядом (на изгибе
//  молчим: проба ушла бы на соседнюю улицу).
//
//  Чистая логика, время — параметром; покрыто LimitAheadTests.
//

import CoreLocation
import Foundation

nonisolated enum LimitAhead {

    struct Probe: Equatable, Sendable {
        /// Метров впереди по пути.
        let along: CLLocationDistance
        /// Лимит дороги в этой точке; nil — дорога не найдена.
        let limit: Int?
        let coordinate: CLLocationCoordinate2D

        static func == (a: Probe, b: Probe) -> Bool {
            a.along == b.along && a.limit == b.limit
                && a.coordinate.latitude == b.coordinate.latitude
                && a.coordinate.longitude == b.coordinate.longitude
        }
    }

    struct Notice: Equatable, Sendable {
        let limit: Int
        /// Метров до смены.
        let distance: CLLocationDistance
        let at: CLLocationCoordinate2D

        static func == (a: Notice, b: Notice) -> Bool {
            a.limit == b.limit && a.distance == b.distance
                && a.at.latitude == b.at.latitude && a.at.longitude == b.at.longitude
        }
    }

    /// Смена лимита впереди, о которой стоит сказать, или nil.
    static func notice(current: Int?, speedKmh: Double, tolerance: Double,
                       probes: [Probe]) -> Notice? {
        guard let current, speedKmh.isFinite else { return nil }
        for (index, probe) in probes.enumerated() {
            guard let limit = probe.limit else { continue }
            if limit >= current {
                // Дорога впереди с тем же или большим лимитом — смена, если
                // будет, дальше; ищем следующую.
                continue
            }
            guard index + 1 < probes.count, probes[index + 1].limit == limit,
                  probe.along >= AppConfig.limitAheadMinMeters,
                  probe.along <= AppConfig.limitAheadMaxMeters,
                  speedKmh > Double(limit) + tolerance else { return nil }
            return Notice(limit: limit, distance: probe.along, at: probe.coordinate)
        }
        return nil
    }

    /// Смена лимита впереди для знака у машины на карте (29.B): то же
    /// снижение, подтверждённое двумя пробами, но без условия скорости — знак
    /// не упрёк, а сведение, и едущему 35 в сороковую зону он тоже честен.
    /// Повышение лимита знаком не показываем: текущий лимит и так в HUD.
    static func visual(current: Int?, probes: [Probe]) -> Notice? {
        guard let current else { return nil }
        for (index, probe) in probes.enumerated() {
            guard let limit = probe.limit, limit < current else { continue }
            guard index + 1 < probes.count, probes[index + 1].limit == limit,
                  probe.along <= AppConfig.limitAheadMaxMeters else { return nil }
            return Notice(limit: limit, distance: probe.along, at: probe.coordinate)
        }
        return nil
    }

    /// Расстояние на знаке у машины: до 100 м — десятками, дальше — по 50:
    /// цифра, прыгающая на каждом метре, читается хуже, чем шаг.
    static func badgeMeters(_ distance: Double) -> Int {
        guard distance.isFinite, distance > 0 else { return 0 }
        let step = distance < 100 ? 10.0 : 50.0
        return Int((distance / step).rounded() * step)
    }

    /// Знак у машины между проверками лимита (раз в limitAheadCheckSeconds):
    /// расстояние — живое, до точки смены; проехали точку (ближе
    /// `limitBadgeGoneMeters` или удаляемся от неё) — знака нет, даже если
    /// служба ещё не пересчитала смену.
    struct Badge: Equatable, Sendable {
        private var shown: Notice?
        private var closest = Double.infinity

        /// Метры на знаке или nil — знак не показываем.
        mutating func meters(for notice: Notice?, distance: Double) -> Int? {
            guard let notice, distance.isFinite else {
                shown = nil
                closest = .infinity
                return nil
            }
            if shown?.limit != notice.limit || shown.map({
                GeoMath.fastDistance($0.at.latitude, $0.at.longitude, notice.at.latitude, notice.at.longitude)
                    > AppConfig.limitAheadSameMeters
            }) ?? true {
                shown = notice
                closest = .infinity
            }
            if distance > closest + AppConfig.limitBadgePassedSlackMeters { return nil }
            closest = min(closest, distance)
            guard distance >= AppConfig.limitBadgeGoneMeters else { return nil }
            return LimitAhead.badgeMeters(distance)
        }
    }

    /// Одна фраза на одну смену лимита.
    struct Announcer: Equatable, Sendable {
        private var last: Notice?
        private var lastAt: Date?

        mutating func shouldAnnounce(_ notice: Notice, at now: Date) -> Bool {
            if let lastAt, now.timeIntervalSince(lastAt) < AppConfig.limitAheadGapSeconds { return false }
            if let last, last.limit == notice.limit,
               GeoMath.fastDistance(last.at.latitude, last.at.longitude,
                                    notice.at.latitude, notice.at.longitude) < AppConfig.limitAheadSameMeters {
                return false
            }
            last = notice
            lastAt = now
            return true
        }
    }
}

/// Фраза — на главном потоке: Formatting знает язык приложения.
extension LimitAhead.Notice {
    /// «Ограничение 40 через 200 м».
    var spoken: String {
        String(format: String(localized: "Ограничение %1$lld через %2$@"),
               limit, Formatting.distance((distance / 50).rounded() * 50))
    }
}
