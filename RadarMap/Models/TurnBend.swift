//
//  TurnBend.swift
//  RadarMap
//
//  Голос на изломе «прямо» (29.E, «умный маршрут»).
//
//  OSRM называет `continue` шаг, на котором мы остаёмся на своей дороге, а
//  `new name` — смену названия. Приложение на таких шагах молчит (с 20.x:
//  «дорога уходит правее» звучало как «поверните направо» на изгибе
//  проспекта). Но аудит 25.10 (docs/route_audit_2026-10-25.md) нашёл и
//  обратное: 7 шагов `continue left/right` на 30 вариантах, где улица на
//  перекрёстке ломается на 60–88° (Sharq Tongi, Seul ko'chasi), — водитель
//  доезжал до развилки трёх улиц и не слышал ничего.
//
//  Решение — по геометрии самой линии маршрута, а не по слову движка:
//  излом за `turnBendBeforeMeters` до точки против `turnBendAfterMeters`
//  после. Окна короткие намеренно — угол перекрёстка набирает все свои
//  градусы на десятке метров, а плавный изгиб проспекта (радиус ≥ 150 м)
//  на 70 м линии даёт меньше 30°. Широкое окно (150 м в обе стороны)
//  подтверждает, что дорога и правда ушла в сторону: «ступенька» через
//  развязку — налево и сразу направо на той же улице — в нём почти прямая.
//  И только там, где сходятся 3+ дороги: излом без развилки — это просто
//  дорога, повернуть с неё некуда.
//
//  Чистая логика — покрыта TurnBendTests.
//

import CoreLocation

nonisolated enum TurnBend {

    /// Излом в точке манёвра: в узком окне (угол перекрёстка) и в широком
    /// (подтверждение: дорога действительно ушла в сторону).
    struct Measure: Equatable, Sendable {
        let near: Double
        let wide: Double
    }

    /// Излом линии в точке `along`: узкое окно — строго внутри линии (nil у
    /// самых краёв маршрута), широкое — сколько есть, но не меньше 20 м.
    static func measure(path: [CLLocationCoordinate2D], cumulative: [Double],
                        at along: Double) -> Measure? {
        guard let near = bend(path: path, cumulative: cumulative, at: along),
              let total = cumulative.last else { return nil }
        let before = min(AppConfig.turnBendWideMeters, along)
        let after = min(AppConfig.turnBendWideMeters, total - along)
        guard before >= 20, after >= 20,
              let wide = bend(path: path, cumulative: cumulative, at: along, before: before, after: after)
        else { return nil }
        return Measure(near: near, wide: wide)
    }

    /// Излом линии в точке `along` (м от начала): курс за `before` м до
    /// против курса за `after` м после, градусы, плюс — вправо. nil — линия
    /// не дотягивается до окна (начало или конец маршрута).
    static func bend(path: [CLLocationCoordinate2D], cumulative: [Double], at along: Double,
                     before: Double = AppConfig.turnBendBeforeMeters,
                     after: Double = AppConfig.turnBendAfterMeters) -> Double? {
        guard path.count >= 2, cumulative.count == path.count,
              along - before >= 0, along + after <= cumulative[cumulative.count - 1] + 0.001,
              let a = point(path, cumulative, along - before),
              let b = point(path, cumulative, along),
              let c = point(path, cumulative, along + after) else { return nil }
        guard GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude) > 1,
              GeoMath.fastDistance(b.latitude, b.longitude, c.latitude, c.longitude) > 1 else { return nil }
        let into = GeoMath.bearing(from: a, to: b)
        let out = GeoMath.bearing(from: b, to: c)
        return (out - into + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    /// Говорить ли шаг «остаёмся на дороге» как поворот: движок назвал
    /// сторону поворота (не «чуть», не «прямо»), линия ломается в ту же
    /// сторону не меньше `turnBendMinDegrees` у самой точки и не меньше
    /// `turnBendWideMinDegrees` в широком окне, и на узле 3+ дороги.
    static func voices(type: String, modifier: String?, bend: Measure?, roads: Int) -> Bool {
        guard type == "continue" || type == "new name", roads >= 3, let bend else { return false }
        let side: Double
        switch modifier {
        case "left", "sharp left":   side = -1
        case "right", "sharp right": side = 1
        default: return false
        }
        return bend.near * side >= AppConfig.turnBendMinDegrees
            && bend.wide * side >= AppConfig.turnBendWideMinDegrees
    }
    /// Кумулятивная длина линии, м.
    static func cumulative(_ path: [CLLocationCoordinate2D]) -> [Double] {
        var out = [0.0]
        out.reserveCapacity(path.count)
        for (p, q) in zip(path, path.dropFirst()) {
            out.append(out[out.count - 1] + GeoMath.fastDistance(p.latitude, p.longitude, q.latitude, q.longitude))
        }
        return out
    }

    /// Точка линии через `along` м — интерполяцией внутри отрезка.
    private static func point(_ path: [CLLocationCoordinate2D], _ cum: [Double],
                              _ along: Double) -> CLLocationCoordinate2D? {
        var lo = 0, hi = cum.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cum[mid] < along { lo = mid + 1 } else { hi = mid }
        }
        let j = max(1, lo), i = j - 1
        let span = cum[j] - cum[i]
        let t = span > 0 ? min(1, max(0, (along - cum[i]) / span)) : 0
        return CLLocationCoordinate2D(latitude: path[i].latitude + (path[j].latitude - path[i].latitude) * t,
                                      longitude: path[i].longitude + (path[j].longitude - path[i].longitude) * t)
    }
}
