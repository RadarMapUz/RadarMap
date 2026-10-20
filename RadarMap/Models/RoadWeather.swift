//
//  RoadWeather.swift
//  RadarMap
//
//  Погода на перевалах и трассах (план 20.10, 19.1–19.2): файл сервера
//  weather/roads.json (server/build_road_weather.py, open-meteo раз в 30
//  минут) — точки с названием, координатой и окнами опасности на ближайшие
//  шесть часов.
//
//  Телефон качает файл целиком и сам решает, что лежит на его пути: где он
//  находится, сервер не узнаёт. Точки одного перевала — одна группа: о
//  Камчике говорим один раз, а не о каждом склоне.
//
//  Погода — прогноз, а не факт, и данные для показа: на оповещения о камерах
//  не влияет никак (ARCHITECTURE.md, правило 20), поэтому файл не подписан.
//  Чистая логика; покрыто RoadWeatherAlertTests.
//

import CoreLocation
import Foundation

nonisolated struct RoadWeatherPoint: Equatable, Sendable {
    /// Опасность — по важности: гололёд опаснее снега, снег — тумана.
    enum Hazard: String, CaseIterable, Comparable, Sendable {
        case ice, snow, fog, wind

        static func < (a: Hazard, b: Hazard) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    /// Опасность в окне времени: [from, to).
    struct Window: Equatable, Sendable {
        let hazard: Hazard
        let from: Date
        let to: Date
    }

    /// Текст на двух языках — сервер присылает оба, язык выбирает телефон.
    struct Text: Equatable, Sendable {
        let ru: String
        let uz: String

        func value(uzbek: Bool) -> String { uzbek ? uz : ru }
    }

    let id: String
    /// Перевал из нескольких точек — одна группа (у равнинного участка — свой id).
    let group: String
    let isPass: Bool
    let coordinate: CLLocationCoordinate2D
    /// Полудлина участка, который точка представляет, м.
    let radius: CLLocationDistance
    /// «Перевал Камчик» — заголовок баннера.
    let name: Text
    /// «На перевале Камчик» — начало фразы голоса.
    let place: Text
    let windows: [Window]

    static func == (a: RoadWeatherPoint, b: RoadWeatherPoint) -> Bool {
        a.id == b.id && a.group == b.group && a.isPass == b.isPass
            && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude
            && a.radius == b.radius && a.name == b.name && a.place == b.place && a.windows == b.windows
    }

    /// Опасности, которые застанут водителя: уже идут или начнутся в
    /// ближайшие `lead` секунд (столько ехать до точки из окна объявления),
    /// и ещё не кончились.
    func hazards(at now: Date, lead: TimeInterval = AppConfig.roadWeatherLeadSeconds) -> Set<Hazard> {
        Set(windows.filter { $0.to > now && $0.from <= now.addingTimeInterval(lead) }.map(\.hazard))
    }
}

nonisolated struct RoadWeatherSnapshot: Equatable, Sendable {
    let generated: Date
    let points: [RoadWeatherPoint]

    /// Разбор roads.json версии 1:
    /// `{"v":1,"generated":t,"points":[{id, group, kind, lat, lon, r, name:{ru,uz},
    /// where:{ru,uz}, hazards:[{k, from, to}], until, t, vis}]}`.
    /// Другая версия — nil: догадка о чужом формате хуже, чем молчание.
    /// Точка без координаты или названия пропускается, незнакомая опасность
    /// (новый вид на сервере) — тоже: старая сборка о ней не скажет.
    static func decode(_ data: Data) -> RoadWeatherSnapshot? {
        // Не JSON — «нет данных»: опрос раз в 30 минут, журнал им не засоряем.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["v"] as? Int == 1,
              let generated = number(object["generated"]),
              let raw = object["points"] as? [[String: Any]] else { return nil }
        let points = raw.compactMap { row -> RoadWeatherPoint? in
            guard let id = row["id"] as? String, !id.isEmpty,
                  let lat = number(row["lat"]), let lon = number(row["lon"]),
                  (-90...90).contains(lat), (-180...180).contains(lon),
                  let name = text(row["name"]), let place = text(row["where"]) else { return nil }
            let windows = (row["hazards"] as? [[String: Any]] ?? []).compactMap { item -> RoadWeatherPoint.Window? in
                guard let kind = (item["k"] as? String).flatMap(RoadWeatherPoint.Hazard.init(rawValue:)),
                      let from = number(item["from"]), let to = number(item["to"]), to > from else { return nil }
                return RoadWeatherPoint.Window(hazard: kind, from: Date(timeIntervalSince1970: from),
                                               to: Date(timeIntervalSince1970: to))
            }
            return RoadWeatherPoint(id: id, group: (row["group"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                                    isPass: row["kind"] as? String == "pass",
                                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                    radius: max(0, number(row["r"]) ?? 0),
                                    name: name, place: place, windows: windows)
        }
        return RoadWeatherSnapshot(generated: Date(timeIntervalSince1970: generated), points: points)
    }

    /// Файлу больше `roadWeatherStaleSeconds` — данных нет: сборщик стоит
    /// или open-meteo не отвечает, а вчерашний туман — не сегодняшний.
    func isFresh(now: Date) -> Bool {
        let age = now.timeIntervalSince(generated)
        return age <= AppConfig.roadWeatherStaleSeconds && age >= -AppConfig.roadWeatherStaleSeconds
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    private static func text(_ value: Any?) -> RoadWeatherPoint.Text? {
        guard let dict = value as? [String: Any],
              let ru = dict["ru"] as? String, !ru.isEmpty,
              let uz = dict["uz"] as? String, !uz.isEmpty else { return nil }
        return RoadWeatherPoint.Text(ru: ru, uz: uz)
    }
}
