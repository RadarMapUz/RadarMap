//
//  RouteLineEnds.swift
//  RadarMap
//
//  Камера за концом линии маршрута — не камера маршрута (снимок владельца
//  05.11, плитка машины: «камера 0 м» рядом с машиной; ревью этапа 48).
//
//  Коридор `RouteService.camerasAlong` — 90 м от ломаной, а у ломаной есть
//  концы. Камера позади старта ложилась проекцией на первую точку (t прижат
//  к нулю), получала «0 м от старта» и дальше шла как настоящая камера
//  маршрута: кандидат с нулём (`LocationGates.candidateDistance`), «маршрут
//  сильнее геометрии», сразу третья ступень. Водитель получал тревогу о
//  камере за спиной — и пока машина не отъезжала на 60 м, она заслоняла
//  настоящую камеру впереди. То же после каждого перестроения: новая линия
//  начинается у машины, и только что проеханная камера снова становилась
//  «0 м».
//
//  Решение — не тишина, а честность: такая камера просто не лежит на нашем
//  пути и судится как любая камера вне маршрута, по прямой и через гейты по
//  живому фиксу. Камера в 91 м за стартом уже так и жила, шов был только на
//  границе коридора. Заглушит её лишь то, что заглушило бы любую другую, —
//  и только при годном курсе; стоя, без курса, она предупреждает. Если старт
//  снапнут вперёд от машины, и камера на самом деле впереди, гейты это видят:
//  они смотрят от машины, а не от линии.
//
//  Чистая логика — RouteLineEndsTests.
//

import CoreLocation
import MapKit

nonisolated enum RouteLineEnds {

    /// Камера за концом линии: проекция легла на крайнюю вершину (`along`,
    /// `length` — как считает camerasAlong) и ушла за неё дальше допуска.
    /// В сомнении — false, то есть прежнее поведение: камера остаётся на
    /// маршруте и предупреждает.
    static func isBeyond(_ camera: Camera, along: CLLocationDistance, points: [MKMapPoint],
                         length: CLLocationDistance) -> Bool {
        guard coordinateProves(camera) else { return false }
        let target = MKMapPoint(camera.coordinate)
        let overshoot: CLLocationDistance
        if along <= 0 {
            overshoot = self.overshoot(target, from: points)
        } else if along >= length {
            overshoot = self.overshoot(target, from: points.reversed())
        } else {
            return false
        }
        return overshoot > AppConfig.routeLineEndToleranceMeters
    }

    /// Координата камеры вправе доказывать «она за концом линии»: снап посадил
    /// её на ось настоящей дороги. Доверие то же, что у гейтов для тишины
    /// (`profileMayMute`: не needsReview, не снап на тротуар или проезд). Метки
    /// водителей и свои точки ставил человек, кусок дороги у них не снят, а
    /// настоящая тренога от места нажатия стоит в любую сторону — такие
    /// предупреждают как раньше, на цену лишнего сигнала.
    static func coordinateProves(_ camera: Camera) -> Bool {
        camera.profileMayMute && camera.road != nil && !camera.kind.isSudden
    }

    /// На сколько метров цель ушла за первую точку `line` против её хода; ≤ 0 —
    /// не ушла. Ход берём до первой вершины дальше `routeHeadingReliableMeters`:
    /// огрызки OSRM и повторённые точки в начале линии дают случайный азимут.
    /// Линия короче этого — хода нет, доказывать нечем (0).
    static func overshoot(_ target: MKMapPoint, from line: some Sequence<MKMapPoint>) -> CLLocationDistance {
        var iterator = line.makeIterator()
        guard let end = iterator.next() else { return 0 }
        while let next = iterator.next() {
            guard end.distance(to: next) >= AppConfig.routeHeadingReliableMeters else { continue }
            let dx = next.x - end.x, dy = next.y - end.y
            let along = ((target.x - end.x) * dx + (target.y - end.y) * dy) / (dx * dx + dy * dy).squareRoot()
            return -along * MKMetersPerMapPointAtLatitude(end.coordinate.latitude)
        }
        return 0
    }
}
