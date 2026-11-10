//
//  OSRMQuery.swift
//  RadarMap
//
//  Параметры запроса к своему OSRM (29.E, «умный маршрут»).
//
//  Аудит 25.10 (docs/route_audit_2026-10-25.md) нашёл в запросе две вещи,
//  которые стоили водителю маршрута:
//    * `alternatives=true` у OSRM значит ОДНА альтернатива: из 20 пар ни одна
//      не дала три плашки, и выбор («Проще», «Меньше камер»…) сводился к двум.
//      Просим числом (`AppConfig.osrmAlternatives`): CH на сервере всё равно
//      вернёт не больше одной альтернативы, MLD — до трёх;
//    * прибытие «с любой стороны»: цель на той стороне проспекта — это
//      разворот, который водитель делает сам, уже приехав. `approaches=curb`
//      у последней точки (и у остановки по пути) — подъезд с её стороны.
//
//  Новые параметры обязаны не ломать маршрут: сервер, который их не примет
//  (4xx — старый OSRM, чужой прокси), получает прежний запрос
//  (`retriesLegacy`). Прод на CH v26.7.3 принимает оба (проверено 25.10).
//
//  Чистая логика — покрыта OSRMQueryTests.
//

import CoreLocation
import Foundation

nonisolated enum OSRMQuery {

    /// Запрос маршрута: старт, (остановка), цель. С курсом — `bearings` и
    /// `radiuses` для первой точки (маршрут начинается туда, куда машина
    /// едет); остальным точкам — без ограничений. `legacy` — запрос до 29.E.
    static func items(alternatives: Bool, heading: CLLocationDirection?,
                      waypoints: Int, legacy: Bool = false) -> [URLQueryItem] {
        let count = max(waypoints, 2)
        var items = [
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "geometries", value: "geojson"),
            URLQueryItem(name: "alternatives", value: alternativesValue(alternatives, legacy: legacy)),
            URLQueryItem(name: "steps", value: "true"),
        ]
        if let heading, heading.isFinite, heading >= 0, waypoints >= 2 {
            let degrees = Int(heading.rounded()) % 360
            let rest = Array(repeating: "", count: count - 1)
            items.append(URLQueryItem(name: "bearings", value: (
                ["\(degrees),\(AppConfig.rerouteBearingRangeDegrees)"] + rest).joined(separator: ";")))
            items.append(URLQueryItem(name: "radiuses", value: (
                ["\(AppConfig.rerouteBearingRadiusMeters)"] + rest.map { _ in "unlimited" }).joined(separator: ";")))
        }
        if let approaches = approaches(count: count, passThrough: 0, legacy: legacy) {
            items.append(URLQueryItem(name: "approaches", value: approaches))
        }
        return items
    }

    /// Запрос своей дороги (24.4): опорные точки проходные (`waypoints` —
    /// только старт и цель), с курсом линии и радиусом поиска дороги —
    /// точка берёт свою проезжую часть, а не встречную; разворот у точки
    /// запрещён (`continue_straight`). Опорным точкам сторона не нужна —
    /// у них нет прибытия; цели — та же, что у обычного маршрута.
    static func viaItems(heading: CLLocationDirection?, via: [MyRoad.Via],
                         legacy: Bool = false) -> [URLQueryItem] {
        let count = via.count + 2
        var bearings = [""], radiuses = ["unlimited"]
        if let heading, heading.isFinite, heading >= 0 {
            bearings = ["\(Int(heading.rounded()) % 360),\(AppConfig.rerouteBearingRangeDegrees)"]
            radiuses = ["\(AppConfig.rerouteBearingRadiusMeters)"]
        }
        bearings += via.map { "\($0.bearing),\(AppConfig.myRoadViaBearingRange)" } + [""]
        radiuses += via.map { _ in "\(AppConfig.myRoadViaRadiusMeters)" } + ["unlimited"]
        var items = [
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "geometries", value: "geojson"),
            URLQueryItem(name: "alternatives", value: "false"),
            URLQueryItem(name: "steps", value: "true"),
            URLQueryItem(name: "continue_straight", value: "true"),
            URLQueryItem(name: "waypoints", value: "0;\(count - 1)"),
            URLQueryItem(name: "bearings", value: bearings.joined(separator: ";")),
            URLQueryItem(name: "radiuses", value: radiuses.joined(separator: ";")),
        ]
        if let approaches = approaches(count: count, passThrough: via.count, legacy: legacy) {
            items.append(URLQueryItem(name: "approaches", value: approaches))
        }
        return items
    }

    /// Повторить ли прежним запросом: сервер ОТВЕТИЛ отказом (4xx — не принял
    /// параметр, не нашёл подъезд с нужной стороны). 5xx и обрыв связи — нет:
    /// прежний запрос упал бы так же, а ждать второй раз незачем.
    static func retriesLegacy(status: Int) -> Bool {
        (400..<500).contains(status)
    }

    /// Отказ сервера (код не 2xx): «пути нет» или сбой самого сервера.
    enum Refusal: Equatable, Sendable { case noRoute, server }

    /// OSRM отвечает на «пути нет» кодом 400 с телом `{"code":"NoRoute"}`
    /// (или NoSegment — дороги у точки нет): это «маршрут не найден», а не
    /// сбой сервера. Прочие отказы и тело не JSON (5xx прокси) — сбой.
    /// nil — ответ успешный.
    static func refusal(status: Int, data: Data) -> Refusal? {
        guard !(200..<300).contains(status) else { return nil }
        struct Body: Decodable { let code: String }
        do {
            let code = try JSONDecoder().decode(Body.self, from: data).code
            return code == "NoRoute" || code == "NoSegment" ? .noRoute : .server
        } catch {
            return .server
        }
    }

    /// `true` до 29.E (одна альтернатива), с 29.E — число.
    private static func alternativesValue(_ wanted: Bool, legacy: Bool) -> String {
        guard wanted else { return "false" }
        return legacy ? "true" : String(AppConfig.osrmAlternatives)
    }

    /// Старт — откуда угодно (машина уже стоит, где стоит); проходные точки
    /// своей дороги — откуда угодно; остановка и цель — со своей стороны.
    /// nil — параметр не нужен (прежний запрос или выключено).
    private static func approaches(count: Int, passThrough: Int, legacy: Bool) -> String? {
        guard !legacy, AppConfig.osrmArriveCurbSide, count >= 2 else { return nil }
        let middle = max(0, count - 2)
        let stops = max(0, middle - passThrough)
        let parts = ["unrestricted"] + Array(repeating: "curb", count: stops)
            + Array(repeating: "unrestricted", count: middle - stops) + ["curb"]
        return parts.joined(separator: ";")
    }
}

extension OSRMQuery {

    /// Ответ сервера: статус, тело и каким запросом получен.
    struct Answer: Sendable {
        let status: Int
        let data: Data
        var legacy = false
    }

    /// Запрос с новыми параметрами, а при отказе сервера (`retriesLegacy`) —
    /// ровно один повтор прежним. `attempt(legacy)` делает сам запрос; его
    /// ошибка (обрыв связи) уходит наружу без повтора: прежний запрос упал бы
    /// так же, а второй таймаут — это ещё 12 с без маршрута.
    static func send(_ attempt: (_ legacy: Bool) async throws -> Answer) async throws -> Answer {
        let first = try await attempt(false)
        guard retriesLegacy(status: first.status) else { return first }
        var second = try await attempt(true)
        second.legacy = true
        return second
    }
}
