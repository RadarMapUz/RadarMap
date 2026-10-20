//
//  CngStatus.swift
//  RadarMap
//
//  Метан: газ есть / нет / очередь (план 19.10, 12б.4). Большинство машин в
//  Узбекистане на метане, и главный вопрос на дороге — не «где АГНКС», а
//  «есть ли там газ и сколько стоять». Ответ знают только водители, которые
//  там прямо сейчас.
//
//  Правила — здесь, чистые и с тестами (CngStatusTests):
//    * отметка привязана к станции из своего файла заведений (вид 12,
//      ≤ 60 м — у колонок, а не на проспекте перед станцией), а не к свободной точке: «нет газа» посреди улицы ничего
//      не значит;
//    * спрашиваем только машину на метане, которая встала у АГНКС: вопрос
//      ставится системным уведомлением через 3 минуты стоянки и снимается,
//      если машина тронулась раньше. За рулём — никогда; без ответа — не
//      уходит ничего;
//    * в поиске «Метан» — сначала где газ есть, потом неизвестно, «нет газа»
//      в конце; внутри — по расстоянию.
//

import Foundation
import CoreLocation

/// Ответ водителя — контракт с сервером (`kind` в POST /api/cng).
nonisolated enum CngAnswer: String, CaseIterable, Sendable {
    case gas, nogas, queue15, queue30, queue60
}

/// Станция глазами сервера: последний статус и последняя очередь, у каждого
/// свой возраст (ступенью 5 мин) — свежая очередь не освежает старый статус.
nonisolated struct CngStation: Equatable, Sendable, Decodable {
    enum Status: String, Sendable, Decodable {
        case gas, nogas
    }

    let lat: Double
    let lon: Double
    var status: Status?
    /// Сколько минут назад сказали о статусе.
    var statusAge: Int?
    /// Очередь, мин (15/30; 60 — «30+»); nil — о ней не говорили.
    var queue: Int?
    var queueAge: Int?
    /// Статус подтвердил независимый водитель (другое устройство и адрес).
    var confirmed: Bool

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    enum CodingKeys: String, CodingKey {
        case lat, lon, status, queue, confirmed
        case statusAge = "status_age"
        case queueAge = "queue_age"
    }

    /// Состарить на `minutes`: статус старше 3 ч и очередь старше 45 мин —
    /// снять (как на сервере). nil — сказать о станции больше нечего.
    func aged(by minutes: Int) -> CngStation? {
        var copy = self
        if let age = statusAge {
            copy.statusAge = age + minutes
            if age + minutes > AppConfig.cngStatusMaxMinutes {
                copy.status = nil; copy.statusAge = nil; copy.confirmed = false
            }
        }
        if let age = queueAge {
            copy.queueAge = age + minutes
            if age + minutes > AppConfig.cngQueueMaxMinutes { copy.queue = nil; copy.queueAge = nil }
        }
        return copy.status == nil && copy.queue == nil ? nil : copy
    }
}

nonisolated enum CngRules {
    /// Ключ станции — как на сервере: точка до 1e-4° (~10 м).
    static func stationKey(_ point: CLLocationCoordinate2D) -> String {
        String(format: "%.4f,%.4f", point.latitude, point.longitude)
    }

    /// Статус станции для заведения из своего файла — ближайшая точка
    /// сервера не дальше `cngMatchMeters`.
    static func station(for venue: CLLocationCoordinate2D, in stations: [CngStation]) -> CngStation? {
        var best: (station: CngStation, meters: Double)?
        for station in stations {
            let meters = GeoMath.fastDistance(venue.latitude, venue.longitude, station.lat, station.lon)
            guard meters <= AppConfig.cngMatchMeters else { continue }
            if best == nil || meters < best!.meters { best = (station, meters) }
        }
        return best?.station
    }

    /// Список на сейчас: ответ сервера, состаренный на время с загрузки.
    static func live(_ fetched: [CngStation], fetchedAt: Date, now: Date) -> [CngStation] {
        let minutes = max(0, Int(now.timeIntervalSince(fetchedAt) / 60))
        return fetched.compactMap { $0.aged(by: minutes) }
    }

    /// Встали у АГНКС: ближайшая станция метана ≤ 60 м, если машина стоит
    /// и о ней не спрашивали в последние 3 ч. nil — не спрашиваем.
    static func stationToAsk(here: CLLocationCoordinate2D, speedKmh: Double, venues: [Venue],
                             askedAt: [String: Date], now: Date) -> Venue? {
        guard speedKmh >= 0, speedKmh < AppConfig.cngStandingKmh else { return nil }
        var best: (venue: Venue, meters: Double)?
        for venue in venues where venue.kind == .cng {
            let meters = GeoMath.fastDistance(here.latitude, here.longitude,
                                              venue.point.latitude, venue.point.longitude)
            guard meters <= AppConfig.cngAskMeters else { continue }
            if best == nil || meters < best!.meters { best = (venue, meters) }
        }
        guard let venue = best?.venue else { return nil }
        if let asked = askedAt[stationKey(venue.point)],
           now.timeIntervalSince(asked) < AppConfig.cngAskCooldownSeconds { return nil }
        return venue
    }

    /// Машина тронулась от станции — поставленный вопрос снять: за рулём
    /// спрашивать нельзя.
    static func shouldCancel(here: CLLocationCoordinate2D, speedKmh: Double,
                             station: CLLocationCoordinate2D) -> Bool {
        speedKmh >= AppConfig.cngLeftKmh
            || GeoMath.fastDistance(here.latitude, here.longitude,
                                    station.latitude, station.longitude) > AppConfig.cngLeftMeters
    }

    /// Порядок в поиске «Метан»: газ есть → неизвестно → газа нет; внутри —
    /// исходный порядок (он уже по расстоянию или по пути). Неподтверждённое
    /// «газа нет» станцию вниз не опускает: один слух не должен прятать
    /// ближайшую АГНКС (ревью 12б.4).
    static func ranked(_ venues: [Venue], stations: [CngStation]) -> [Venue] {
        func rank(_ venue: Venue) -> Int {
            guard let station = station(for: venue.point, in: stations) else { return 1 }
            switch station.status {
            case .gas?: return 0
            case nil: return 1
            case .nogas?: return station.confirmed ? 2 : 1
            }
        }
        return venues.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// Строка под станцией: «Газ есть, 40 мин назад · очередь ~15 мин, 5 мин
    /// назад». Неподтверждённый статус так и назван — слух не продаём как факт.
    static func caption(_ station: CngStation) -> String? {
        var parts: [String] = []
        if let status = station.status, let age = station.statusAge {
            var text = status == .gas ? String(localized: "Газ есть") : String(localized: "Газа нет")
            if !station.confirmed { text = String(format: String(localized: "%@ (по словам водителя)"), text) }
            parts.append(String(format: String(localized: "%1$@, %2$@"), text, ago(age)))
        }
        if let queue = station.queue, let age = station.queueAge {
            parts.append(String(format: String(localized: "%1$@, %2$@"), queueText(queue), ago(age)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func queueText(_ queue: Int) -> String {
        queue >= 60 ? String(localized: "очередь 30+ мин")
                    : String(format: String(localized: "очередь ~%lld мин"), queue)
    }

    static func ago(_ minutes: Int) -> String {
        minutes >= 60 ? String(format: String(localized: "%lld ч назад"), minutes / 60)
                      : String(format: String(localized: "%lld мин назад"), minutes)
    }
}
