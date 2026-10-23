//
//  CameraZone.swift
//  RadarMap
//
//  Зона камеры на асфальте (28.B, 23.10): у камеры, к которой едем, —
//  подкрашенный участок её собственной проезжей части перед ней, где будут
//  мерить скорость.
//
//  Какая камера. На маршруте — первая впереди на линии из тех, что рисуются
//  «на пути» (CameraOnLine: встречный близнец не наш); без маршрута — та же
//  ближайшая, что в HUD. Это тот же выбор, что даёт ей цветной значок
//  (CameraMarkerLook), только из всех камер пути — одна.
//
//  Где. Кусок дороги камеры в базе (`Camera.road`, снят снапом с её
//  проезжей части) — от точки камеры назад по ходу движения на длину зоны
//  замера (`cameraZoneMeters` = `passZoneMeters`: ровно там приложение само
//  пишет «скорость проезда»). Дальше конца куска не продолжаем: зона не
//  выдумывается.
//
//  Когда — только с доказательством. Картинка «здесь мерят» сильнее голоса
//  «впереди камера»: голос предупреждает на подозрении, а лента на асфальте
//  показывает место. Поэтому, в отличие от оповещений, неизвестность значит
//  «не рисовать»:
//    • профиль дороги доверенный (`Camera.profileMayMute`: снап сел на
//      проезжую часть, не на проезд и не у камеры с неточной координатой);
//    • кусок дороги есть (RoadShape);
//    • камера меряет скорость (`recordsPasses`: не пост ДПС, не ДТП);
//    • наш курс известен и идёт ВДОЛЬ её дороги (поперечная улица, мост —
//      ничего);
//    • у односторонней проезжей части (`dir`) курс с ней согласен: обратная
//      сторона разделённой дороги — не наша полоса, и рисовать там «замер»
//      было бы картинкой чужой дороги.
//  У двусторонней дороги (направления нет — дорога одна на оба потока)
//  сторону выбирает наш курс, и лента ложится на нашу половину.
//
//  Лента кончается под значком камеры: если значок перенесён на линию
//  маршрута или на ось нашей дороги (CameraOnLine.Display.points), кусок
//  дороги сдвигается туда же — та же дорога, на несколько метров в сторону.
//
//  ТОЛЬКО КАРТИНКА. Ни оповещения, ни гейты, ни проезды это не читают
//  (CameraZoneTests сверяет исходники). Источник движка пишется только при
//  смене камеры, стороны или заметном сдвиге значка (`needsRewrite`), а не
//  на тике.
//
//  Чистая логика; CameraZoneTests.
//

import CoreLocation
import MapKit

nonisolated enum CameraZone {

    /// Лента зоны для источника движка.
    struct Band: Equatable, Sendable {
        let cameraID: Int
        /// Точки по ходу движения: от начала зоны к камере (последняя — под значком).
        let points: [CameraOnLine.Point]
        /// Ширина ленты, м (уже проезжей части — на асфальте, не на бордюре).
        let widthMeters: Double
        /// Сдвиг середины ленты вправо по ходу, м: у двусторонней дороги лента
        /// лежит на нашей половине; у односторонней — 0.
        let offsetMeters: Double

        var latitude: Double { points.last?.latitude ?? 0 }
    }

    // MARK: - Какая камера

    /// Камера, к которой едем.
    /// - Parameters:
    ///   - route: камеры маршрута и метры от старта по линии.
    ///   - spots: точки маршрута (`CameraOnLine.routeSpots`): доказанно не
    ///     наша (`notOurs`) не цель.
    ///   - progress: где мы на линии; nil — маршрута нет.
    ///   - passedSlack: сколько метров позади камера ещё цель (GPS отстаёт
    ///     от значка; зона позади нас уже не нужна — запас короче, чем у цвета).
    ///   - nearest: ближайшая наша камера HUD (без маршрута).
    static func target(route: [(id: Int, along: Double)], spots: [Int: CameraOnLine.Spot],
                       progress: Double?, passedSlack: Double = AppConfig.cameraZonePassedMeters,
                       nearest: Int?) -> Int? {
        guard let progress else { return nearest }
        var best: (id: Int, along: Double)?
        for camera in route where camera.along >= progress - passedSlack
            && spots[camera.id]?.verdict != .notOurs {
            if best.map({ camera.along < $0.along }) ?? true { best = camera }
        }
        return best?.id
    }

    // MARK: - Курс маршрута у камеры

    /// Курс подъезда по линии маршрута к месту `along`: от точки `back` метров
    /// раньше до самого места (поворот прямо у камеры даёт курс подъезда, а не
    /// выезда). nil — линии нет или место за её концами.
    static func routeHeading(points: [MKMapPoint], along: Double,
                             back: Double = AppConfig.cameraZoneHeadingMeters) -> Double? {
        guard points.count >= 2, along > 0 else { return nil }
        func point(at target: Double) -> MKMapPoint? {
            var walked = 0.0
            for index in 1..<points.count {
                let a = points[index - 1], b = points[index]
                let length = a.distance(to: b)
                if walked + length >= target, length > 0 {
                    let t = (target - walked) / length
                    return MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                }
                walked += length
            }
            return nil
        }
        guard let end = point(at: along), let start = point(at: max(0, along - back)),
              start.distance(to: end) > 1 else { return nil }
        return GeoMath.bearing(from: start.coordinate, to: end.coordinate)
    }

    // MARK: - Лента

    /// Лента зоны или nil — доказательства нет (см. шапку файла).
    /// - Parameters:
    ///   - heading: наш курс подъезда к камере (по маршруту — у камеры; без
    ///     маршрута — по дороге под машиной); < 0 — неизвестен.
    ///   - anchor: где нарисован значок, если не на своей координате.
    static func band(camera: Camera, heading: Double, anchor: CLLocationCoordinate2D? = nil,
                     length: Double = AppConfig.cameraZoneMeters,
                     minLength: Double = AppConfig.cameraZoneMinMeters) -> Band? {
        guard heading >= 0, camera.kind.recordsPasses, camera.profileMayMute,
              let shape = RoadShape(camera: camera) else { return nil }
        // Плоские метры вокруг камеры: кусок дороги — сотни метров.
        let origin = camera.coordinate
        let metersPerLon = 111_320.0 * cos(origin.latitude * .pi / 180)
        let flat = shape.points.map { point -> (x: Double, y: Double) in
            ((point.longitude - origin.longitude) * metersPerLon, (point.latitude - origin.latitude) * 111_320.0)
        }
        // Проекция камеры на свой кусок дороги и пройденное до неё.
        var cumulative = [0.0]
        for index in 1..<flat.count {
            cumulative.append(cumulative[index - 1]
                              + hypot(flat[index].x - flat[index - 1].x, flat[index].y - flat[index - 1].y))
        }
        var best = Double.greatestFiniteMagnitude
        var cameraAlong = 0.0
        var segment = -1
        for index in 1..<flat.count {
            let a = flat[index - 1], b = flat[index]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            guard len2 > 0 else { continue }
            let t = max(0, min(1, (-a.x * dx - a.y * dy) / len2))
            let distance = hypot(a.x + t * dx, a.y + t * dy)
            if distance < best {
                best = distance
                segment = index - 1
                cameraAlong = cumulative[index - 1] + t * len2.squareRoot()
            }
        }
        guard segment >= 0 else { return nil }
        // Курс дороги у камеры (по порядку точек куска).
        let roadBearing = GeoMath.bearing(from: shape.points[segment], to: shape.points[segment + 1])
        // Едем вдоль её дороги, а не поперёк (мост, поперечная улица развязки).
        guard GeoMath.axisDifference(course: heading, axis: roadBearing.truncatingRemainder(dividingBy: 180))
                <= AppConfig.cameraZoneMaxAxisDegrees else { return nil }
        // Односторонняя проезжая часть — только по ходу её движения.
        if let direction = camera.dir,
           GeoMath.angleDifference(heading, Double(direction)) > AppConfig.cameraZoneMaxAxisDegrees {
            return nil
        }
        // Сторона подъезда: едем по порядку точек — зона раньше камеры по
        // куску, против — позже.
        let forward = GeoMath.angleDifference(heading, roadBearing) <= 90
        let total = cumulative[cumulative.count - 1]
        let available = forward ? cameraAlong : total - cameraAlong
        let span = min(length, available)
        guard span >= minLength else { return nil }
        let from = forward ? cameraAlong - span : cameraAlong + span
        let pieces = slice(flat, cumulative: cumulative, from: from, to: cameraAlong)
        guard pieces.count >= 2 else { return nil }
        // Конец ленты — под значком: кусок сдвигается туда, где тот нарисован.
        let end = pieces[pieces.count - 1]
        let target = anchor ?? origin
        let shiftX = (target.longitude - origin.longitude) * metersPerLon - end.x
        let shiftY = (target.latitude - origin.latitude) * 111_320.0 - end.y
        let points = pieces.map { piece in
            CameraOnLine.Point(latitude: origin.latitude + (piece.y + shiftY) / 111_320.0,
                               longitude: origin.longitude + (piece.x + shiftX) / metersPerLon)
        }
        // Ширина: проезжая часть камеры (та же мера, что у «я на этой дороге»,
        // без запаса на неточность координаты). Двусторонняя — наша половина.
        let carriageway = 2 * (RoadGeometry.halfWidth(lanes: camera.lanes, roadClass: camera.roadClass)
                               - AppConfig.roadPositionSlackMeters)
        let oneWay = camera.dir != nil
        let ours = oneWay ? carriageway : carriageway / 2
        return Band(cameraID: camera.id, points: points,
                    widthMeters: ours * AppConfig.cameraZoneWidthShare,
                    offsetMeters: oneWay ? 0 : carriageway / 4)
    }

    /// Участок ломаной между местами `from` и `to` (в любом порядке, точки —
    /// в порядке от `from` к `to`).
    static func slice(_ flat: [(x: Double, y: Double)], cumulative: [Double],
                      from: Double, to: Double) -> [(x: Double, y: Double)] {
        guard flat.count >= 2 else { return [] }
        func point(at along: Double) -> (x: Double, y: Double) {
            let clamped = min(max(0, along), cumulative[cumulative.count - 1])
            var index = 1
            while index < cumulative.count - 1, cumulative[index] < clamped { index += 1 }
            let a = flat[index - 1], b = flat[index]
            let length = cumulative[index] - cumulative[index - 1]
            let t = length > 0 ? (clamped - cumulative[index - 1]) / length : 0
            return (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
        }
        let lo = min(from, to), hi = max(from, to)
        var out = [point(at: lo)]
        for index in cumulative.indices where cumulative[index] > lo && cumulative[index] < hi {
            out.append(flat[index])
        }
        out.append(point(at: hi))
        return from <= to ? out : out.reversed()
    }

    // MARK: - Когда переписывать источник

    /// Источник переписывается при смене камеры, стороны или ширины и при
    /// сдвиге ленты заметнее `cameraZoneRewriteMeters` (значок без маршрута
    /// ездит за осью нашей дороги на доли метра каждый фикс — каждый такой
    /// сдвиг будил бы перетайливание).
    static func needsRewrite(_ old: Band?, _ new: Band?,
                             tolerance: Double = AppConfig.cameraZoneRewriteMeters) -> Bool {
        guard let old, let new else { return (old == nil) != (new == nil) }
        guard old.cameraID == new.cameraID, old.points.count == new.points.count,
              old.widthMeters == new.widthMeters, old.offsetMeters == new.offsetMeters else { return true }
        for (a, b) in zip(old.points, new.points)
        where GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude) > tolerance {
            return true
        }
        return false
    }

    // MARK: - Цвет

    /// Один спокойный красный на все типы, а не цвет типа: радар — янтарь, и
    /// янтарная лента на жёлто-оранжевой магистрали (палитра 28.A) пропала бы
    /// ровно там, где радаров больше всего; красный читается на белой улице,
    /// на магистрали и на графите ночи. Тип и так виден по значку на конце
    /// ленты. Полупрозрачно: разметка и стрелки полос под лентой видны.
    /// Проверено CameraZoneTests (ΔE ленты поверх полотна всех классов в
    /// обеих темах; лента ≠ линия маршрута).
    enum Colors {
        static let day: (hex: UInt32, alpha: Double) = (0xE5372B, 0.30)
        static let night: (hex: UInt32, alpha: Double) = (0xFF5A4E, 0.40)

        static func pick(daylight: Bool) -> (hex: UInt32, alpha: Double) { daylight ? day : night }
    }

    // MARK: - Ширина на экране

    /// Метров на точку экрана на масштабе 0 у этой широты (мир движка — 512 точек).
    static func metersPerPointAtZoomZero(latitude: Double) -> Double {
        40_075_016.686 / 512 * cos(latitude * .pi / 180)
    }
}
