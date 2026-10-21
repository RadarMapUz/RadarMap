//
//  CarPlayManeuverLimit.swift
//  RadarMap
//
//  Знак ограничения в тексте манёвра на экране машины (25.H1, iOS 27):
//  «Поверните направо на ул. Лабзак (60)».
//
//  У CPManeuver есть `attributedInstructionVariants` — фраза с картинками-
//  вложениями до 64×25 pt (CPManeuver.h), система предпочитает их простым
//  вариантам. Знак говорит о том, чего не скажет ни стрелка, ни улица:
//  после поворота другое ограничение. Поэтому он стоит, только когда это
//  правда и это новость:
//    • лимит участка после манёвра известен — две пробы по линии маршрута
//      (`carPlayManeuverLimitProbesAfter`) сходятся на одном числе: первая
//      проба у самого перекрёстка могла лечь на поперечную улицу;
//    • он отличается от лимита до манёвра (проба перед поворотом, а нет её —
//      текущий лимит дороги) — «60» на каждой карточке по городу, где везде
//      60, было бы шумом и отучило бы смотреть на знак;
//    • манёвр — не прибытие.
//  Лимит до манёвра неизвестен — знака нет: «отличается» не доказано.
//
//  Чистая логика (поиск лимита — замыканием); CarPlayManeuverLimitTests.
//

import CoreLocation

nonisolated enum CarPlayManeuverLimit {

    /// Знак для карточки или nil.
    ///
    /// - Parameters:
    ///   - along: где манёвр, метры от старта маршрута (`RouteStep.distanceAlong`).
    ///   - path: линия выбранного маршрута.
    ///   - current: лимит дороги под машиной — запасной «до манёвра».
    ///   - limit: лимит дороги в точке при курсе (`LimitIndex.match`).
    static func sign(along: Double, kind: ManeuverKind?, path: [CLLocationCoordinate2D],
                     current: Int?,
                     before: Double = AppConfig.carPlayManeuverLimitProbeBefore,
                     after: [Double] = AppConfig.carPlayManeuverLimitProbesAfter,
                     limit: (CLLocationCoordinate2D, Double) -> Int?) -> Int? {
        guard kind != .arrive, path.count >= 2, !after.isEmpty else { return nil }
        let probes = after.map { offset in
            point(along: along + offset, path: path).flatMap { limit($0.coordinate, $0.bearing) }
        }
        guard let next = probes.first ?? nil, probes.allSatisfy({ $0 == next }) else { return nil }
        let previous = point(along: along - before, path: path).flatMap { limit($0.coordinate, $0.bearing) }
            ?? current
        guard let previous, previous != next else { return nil }
        return next
    }

    /// Точка на линии через `along` метров от начала и направление линии там.
    /// За концом линии — nil: проба за целью ничего не говорит о дороге.
    static func point(along: Double, path: [CLLocationCoordinate2D])
        -> (coordinate: CLLocationCoordinate2D, bearing: Double)? {
        guard along >= 0, path.count >= 2 else { return nil }
        var travelled: Double = 0
        for (p, q) in zip(path, path.dropFirst()) {
            let length = GeoMath.fastDistance(p.latitude, p.longitude, q.latitude, q.longitude)
            guard length > 0 else { continue }
            if along <= travelled + length {
                let t = (along - travelled) / length
                let point = CLLocationCoordinate2D(latitude: p.latitude + (q.latitude - p.latitude) * t,
                                                   longitude: p.longitude + (q.longitude - p.longitude) * t)
                return (point, GeoMath.bearing(from: p, to: q))
            }
            travelled += length
        }
        return nil
    }
}
