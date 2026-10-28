//
//  RoadEvent.swift
//  RadarMap
//
//  Перекрытие и ремонт дороги (план 19.10, 12б.5) — отметки водителей о
//  самой дороге, а не о камерах. Приходят своим списком (GET /api/road):
//  старые сборки читают незнакомый тип в общем списке как «радар», и
//  ремонт стал бы для них передвижным радаром со звуком.
//
//  Правила здесь, чистые и с тестами (RoadEventTests):
//    * маршрут: вариант, идущий ≤ 30 м от перекрытия с ДВУМЯ независимыми
//      подтверждениями в ту же сторону, — «на пути перекрытие», первым не
//      предлагается. Порог тот же, что у маршрутизатора сервера
//      (CLOSURE_MIN_CONFIRMERS, 33D; решение 28.10): одно подтверждение —
//      отметка и голос, но не выбор пути, иначе телефон и OSRM расходились
//      (сервер строил через перекрытие, телефон вешал на этот путь ярлык).
//      Старый сервер числа не шлёт — путь не трогаем. Сторона —
//      курс отметившего: перекрыта может быть одна половина проспекта, и
//      отметка на встречке не мешает. Курс неизвестен — считаем, что
//      перекрыто всё: цена ошибки — вариант чуть медленнее, а не тупик;
//    * голос: один раз за поездку, спокойно — «Впереди ремонт дороги». В
//      узком коридоре по курсу и в ту же сторону; ремонт — только на
//      подтверждённом, перекрытие — и на неподтверждённом («отметка
//      водителей»), потому что упереться в него дороже лишней фразы.
//
//  Оповещения о камерах это не трогает никак: события дороги не становятся
//  камерами, не идут в AlertEngine и не пишут проездов (правило 20).
//

import Foundation
import CoreLocation

nonisolated struct RoadEvent: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case closure, roadwork
    }

    let id: Int
    let kind: Kind
    let lat: Double
    let lon: Double
    /// Курс отметившего, 0…360; < 0 — неизвестен.
    let course: Double
    let expires: Date
    let confirmed: Bool
    /// Число независимых подтверждений (разное устройство И адрес) из
    /// `/api/road`, 28.10. nil — старый сервер: на путь такое не влияет.
    var confirmers: Int? = nil

    /// Влияет ли на выбор пути: перекрытие с `roadClosureRouteConfirmers`
    /// независимыми подтверждениями. `confirmed` (одно) — только отметка и голос.
    var affectsRoute: Bool {
        kind == .closure && (confirmers ?? 0) >= AppConfig.roadClosureRouteConfirmers
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

nonisolated enum RoadEventRules {
    /// Перекрытий на пути варианта (годных для выбора пути — `affectsRoute`,
    /// в нашу сторону).
    static func closures(on path: [CLLocationCoordinate2D], events: [RoadEvent], now: Date) -> Int {
        events.filter { $0.affectsRoute && $0.expires > now && blocks(path: path, event: $0) }
            .count
    }

    /// Путь проходит через перекрытие: ≤ 30 м от точки, и направление пути
    /// там — в ту же сторону, что ехал отметивший (если его курс известен).
    static func blocks(path: [CLLocationCoordinate2D], event: RoadEvent) -> Bool {
        guard path.count >= 2 else { return false }
        let point = event.coordinate
        for index in 0..<(path.count - 1) {
            let a = path[index], b = path[index + 1]
            guard distanceToSegment(point, a, b) <= AppConfig.roadEventRouteMeters else { continue }
            guard event.course >= 0 else { return true }
            let heading = GeoMath.bearing(from: a, to: b)
            if GeoMath.angleDifference(heading, event.course) <= AppConfig.roadEventSameSideDegrees {
                return true
            }
        }
        return false
    }

    /// Что сказать сейчас: ближайшее событие впереди в узком коридоре по
    /// курсу, ещё не сказанное в этой поездке. nil — молчим (курса нет,
    /// событие сбоку, на встречке, далеко или уже сказано).
    static func ahead(of here: CLLocationCoordinate2D, course: Double, events: [RoadEvent],
                      voiced: Set<Int>, now: Date) -> RoadEvent? {
        guard course >= 0 else { return nil }
        var best: (event: RoadEvent, along: Double)?
        for event in events where !voiced.contains(event.id) && event.expires > now {
            guard event.kind == .closure || event.confirmed else { continue }
            if event.course >= 0,
               GeoMath.angleDifference(course, event.course) > AppConfig.roadEventSameSideDegrees { continue }
            let fix = RoadCorridor.fix(from: here, course: course, to: event.coordinate)
            guard fix.along > 0, fix.along <= AppConfig.roadEventVoiceMeters,
                  fix.across <= AppConfig.roadEventCorridorMeters else { continue }
            if best == nil || fix.along < best!.along { best = (event, fix.along) }
        }
        return best?.event
    }

    /// Фраза голоса — спокойная, без расстояния до метра.
    static func phrase(for event: RoadEvent) -> String {
        switch event.kind {
        case .closure:
            return event.confirmed ? String(localized: "Впереди перекрытие дороги")
                                   : String(localized: "Отметка водителей: впереди перекрытие")
        case .roadwork:
            return String(localized: "Впереди ремонт дороги")
        }
    }

    /// Расстояние от точки до отрезка, м (локальная проекция — отрезки маршрута короткие).
    static func distanceToSegment(_ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D,
                                  _ b: CLLocationCoordinate2D) -> Double {
        let kx = 111_320 * cos(p.latitude * .pi / 180), ky = 110_540.0
        let ax = (a.longitude - p.longitude) * kx, ay = (a.latitude - p.latitude) * ky
        let bx = (b.longitude - p.longitude) * kx, by = (b.latitude - p.latitude) * ky
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? max(0, min(1, -(ax * dx + ay * dy) / lengthSquared)) : 0
        let x = ax + t * dx, y = ay + t * dy
        return (x * x + y * y).squareRoot()
    }
}
