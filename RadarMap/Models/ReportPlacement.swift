//
//  ReportPlacement.swift
//  RadarMap
//
//  Куда именно встаёт отметка водителя и что делать с ней без сети.
//
//  Две чистые задачи, обе раньше решались никак.
//
//  1. МЕСТО. Отметка ставилась по координате телефона в момент тапа. На 90 км/ч
//     это 25 метров позади реального радара только на время реакции, а на
//     разделённой трассе точка вообще ложится между полотнами и с равным
//     успехом может «принадлежать» встречной. Дорожные тайлы у приложения уже
//     есть (RoadNetworkService), и снап на ось решает обе беды: точка садится
//     на проезжую часть и получает класс дороги, по которому сервер выбирает
//     радиус слияния.
//
//     Курс — не украшение: на трассе две оси идут в 20 метрах друг от друга, и
//     без проверки направления снап с равной вероятностью выберет встречную.
//     Поэтому дорога, идущая примерно ПО курсу, всегда предпочтительнее более
//     близкой поперечной. Курса нет (стоим, GPS не уверен) — берём ближайшую.
//
//  2. ОЧЕРЕДЬ. `report()` при обрыве сети просто говорил «не отправилось» — и
//     всё, тап пропадал. Треноги стоят ровно там, где связи нет. Но отметка —
//     товар скоропортящийся: через полчаса она вредна, потому что радар уже
//     уехал, а мы предупредим. Отсюда возраст: старше пятнадцати минут не
//     отправляем никогда, и это не «потеря», а единственный честный исход.
//

import CoreLocation

nonisolated enum ReportPlacement {

    // MARK: - Отступ назад на время реакции

    /// Сколько секунд проходит между «увидел» и «нажал».
    ///
    /// Отметку ставят, ПРОЕХАВ объект: треногу за кустом или патруль на
    /// обочине замечают в упор, а палец идёт к экрану ещё секунду-полторы.
    /// Плюс возраст фикса: координата в момент тапа — это место, где телефон
    /// был до секунды назад. На 110 км/ч две секунды — это 61 метр вперёд от
    /// настоящего радара.
    ///
    /// Ошибка несимметрична, и в этом всё дело. Отметка, поставленная РАНЬШЕ
    /// радара, предупредит следующего водителя чуть загодя — он ничего не
    /// заметит. Отметка, поставленная ПОЗЖЕ, сработает, когда он уже проехал,
    /// то есть не сработает вовсе. Поэтому сдвигаем строго назад по курсу.
    static let reactionSeconds: Double = 2
    /// Потолок сдвига: на 130 км/ч формула даёт 72 метра, но на случай
    /// выброса скорости дальше ста двадцати не уходим — иначе отметка уедет
    /// за перекрёсток, которого водитель и не проезжал.
    static let maxBackdateMeters: CLLocationDistance = 120
    /// Медленнее — не сдвигаем: в пробке и на стоянке «две секунды назад» это
    /// то же самое место, а курс на такой скорости недостоверен.
    static let minBackdateSpeedKmh: Double = 20

    /// Где водитель был `seconds` назад — туда и ставим отметку.
    static func backdated(_ coordinate: CLLocationCoordinate2D,
                          course: Double,
                          speedKmh: Double,
                          seconds: Double = reactionSeconds) -> CLLocationCoordinate2D {
        guard course >= 0, speedKmh >= minBackdateSpeedKmh, seconds > 0 else { return coordinate }
        let meters = min(maxBackdateMeters, (speedKmh / 3.6) * seconds)
        let back = (course + 180).truncatingRemainder(dividingBy: 360)
        return GeoMath.destination(from: coordinate, bearing: back, distanceMeters: meters)
    }

    /// Куда встала отметка после снапа.
    struct Placement: Equatable {
        let coordinate: CLLocationCoordinate2D
        let roadClass: RoadClass

        static func == (a: Placement, b: Placement) -> Bool {
            a.roadClass == b.roadClass
                && abs(a.coordinate.latitude - b.coordinate.latitude) < 1e-9
                && abs(a.coordinate.longitude - b.coordinate.longitude) < 1e-9
        }
    }

    /// Снап на ось ближайшей проезжей части.
    ///
    /// - Parameter course: курс движения в градусах или отрицательное значение,
    ///   если ему нельзя верить (см. `LocationFilter`). Недоверенный курс
    ///   отключает выбор по направлению целиком, а не подставляет ноль.
    /// - Returns: `nil`, когда дороги рядом нет вовсе. Это не ошибка: отметка
    ///   уходит с сырой координатой, потому что промолчать о радаре хуже, чем
    ///   поставить его на десять метров мимо.
    static func snapped(_ coordinate: CLLocationCoordinate2D,
                        course: Double,
                        roads: [RoadLine],
                        maxMeters: CLLocationDistance) -> Placement? {
        var best: (distance: CLLocationDistance, point: CLLocationCoordinate2D,
                   kind: RoadClass, alongCourse: Bool)?
        for road in roads where road.kind.isVehicleRoad && road.points.count >= 2 {
            for index in 0..<(road.points.count - 1) {
                let a = road.points[index], b = road.points[index + 1]
                let point = nearestPoint(to: coordinate, a: a, b: b)
                let distance = GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                                    point.latitude, point.longitude)
                guard distance <= maxMeters else { continue }
                // Ось сегмента ненаправленная: «по курсу» значит и туда, и
                // обратно — сторону дороги мы всё равно не знаем.
                let alongCourse = course >= 0
                    && GeoMath.axisDifference(course: course,
                                              axis: GeoMath.bearing(from: a, to: b))
                        <= maxAxisAngle
                guard let current = best else {
                    best = (distance, point, road.kind, alongCourse)
                    continue
                }
                // Дорога по курсу бьёт более близкую поперечную: на развязке и
                // на разделённой трассе именно это отличает своё полотно от
                // чужого.
                if alongCourse && !current.alongCourse {
                    best = (distance, point, road.kind, alongCourse)
                } else if alongCourse == current.alongCourse, distance < current.distance {
                    best = (distance, point, road.kind, alongCourse)
                }
            }
        }
        guard let best else { return nil }
        return Placement(coordinate: best.point, roadClass: best.kind)
    }

    /// Курс и ось расходятся больше — дорога считается поперечной. Порог тот
    /// же, что у гейта оси камеры: шум курса плюс кривые подъезды.
    static let maxAxisAngle: Double = 55

    /// Ближайшая точка отрезка к заданной. Плоская геометрия: на сотне метров
    /// кривизна Земли не важна, а долгота сжимается по широте точки.
    private static func nearestPoint(to p: CLLocationCoordinate2D,
                                     a: CLLocationCoordinate2D,
                                     b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let scale = cos(p.latitude * .pi / 180)
        let ax = a.longitude * scale, ay = a.latitude
        let bx = b.longitude * scale, by = b.latitude
        let px = p.longitude * scale, py = p.latitude
        let dx = bx - ax, dy = by - ay
        let length = dx * dx + dy * dy
        guard length > 0 else { return a }
        let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / length))
        return CLLocationCoordinate2D(latitude: ay + t * dy,
                                      longitude: (ax + t * dx) / scale)
    }
}

/// Отметка, ждущая связи.
nonisolated struct PendingReport: Codable, Equatable {
    let kind: String
    let lat: Double
    let lon: Double
    let cls: String
    let at: Date
}

/// Политика очереди — чистая, вся в тестах: сервису остаётся только сеть.
nonisolated enum ReportQueue {

    /// Максимум в очереди. Больше трёх ждущих отметок — это не «связь пропала»,
    /// а тап по кнопке от скуки; храним свежие.
    static let limit = 3

    /// Отметка старше этого не отправляется никогда: радар уехал, а мы бы
    /// предупредили. Молчание тут честнее доставки.
    static let maxAge: TimeInterval = 15 * 60

    /// Поставить в очередь. Повтор того же типа рядом и недавно не копится:
    /// без сети человек жмёт ещё раз именно потому, что не понял, ушло ли.
    static func enqueued(_ item: PendingReport, into queue: [PendingReport]) -> [PendingReport] {
        let isRepeat = queue.contains { existing in
            existing.kind == item.kind
                && item.at.timeIntervalSince(existing.at) < ReportGuard.duplicateWindowSeconds
                && GeoMath.fastDistance(existing.lat, existing.lon, item.lat, item.lon)
                    < ReportGuard.duplicateRadiusMeters
        }
        guard !isRepeat else { return queue }
        return (queue + [item]).suffix(limit).map { $0 }
    }

    /// Что делать с очередью прямо сейчас.
    /// - Returns: `send` — отправлять, `expired` — выбросить как протухшее.
    static func split(_ queue: [PendingReport], now: Date)
        -> (send: [PendingReport], expired: [PendingReport]) {
        var send: [PendingReport] = []
        var expired: [PendingReport] = []
        for item in queue {
            if now.timeIntervalSince(item.at) > maxAge {
                expired.append(item)
            } else {
                send.append(item)
            }
        }
        return (send, expired)
    }
}
