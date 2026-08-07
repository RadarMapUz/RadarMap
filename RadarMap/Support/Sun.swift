//
//  Sun.swift
//  RadarMap
//
//  Восход и закат — локально, без сети.
//
//  Тема подложки «авто» переключалась по будильнику (6–19), и это враньё
//  дважды в год по часу: в декабре в Ташкенте в 18:30 темно, а карта ещё
//  светлая и слепит; в июне в 5 утра светло, а карта чёрная. Солнце — не
//  настройка, его положение считается арифметикой по координате и дате
//  (алгоритм NOAA, точность пары минут — больше и не нужно).
//
//  Чистые функции, время и место — параметрами; покрыто SunTests.
//

import CoreLocation
import Foundation

nonisolated enum Sun {

    /// Официальный зенит восхода/заката: 90°50′ — солнце скрылось за горизонт
    /// с поправкой на рефракцию и радиус диска.
    private static let zenithDegrees = 90.833

    /// Восход и закат для точки в данный КАЛЕНДАРНЫЙ день (по поясу календаря).
    /// nil — солнце в этот день не встаёт/не садится (заполярье, не наш случай).
    static func daylight(at coordinate: CLLocationCoordinate2D, on date: Date,
                         calendar: Calendar = .current) -> (sunrise: Date, sunset: Date)? {
        guard let sunrise = event(rising: true, at: coordinate, on: date, calendar: calendar),
              let sunset = event(rising: false, at: coordinate, on: date, calendar: calendar)
        else { return nil }
        return (sunrise, sunset)
    }

    /// Светло ли сейчас в точке. Без координаты (первый запуск, нет
    /// разрешения) — прежние часы 6–19: лучше грубое правило, чем гадание.
    ///
    /// Вопрос задан правильно не как «попали ли в окно суток» (восход и закат
    /// каких именно суток — уже ловушка на границах дня), а как «какое событие
    /// было ПОСЛЕДНИМ»: после восхода — день, после заката — ночь.
    static func isDaytime(at coordinate: CLLocationCoordinate2D?, now: Date,
                          calendar: Calendar = .current) -> Bool {
        func fallback() -> Bool { (6..<19).contains(calendar.component(.hour, from: now)) }
        guard let coordinate else { return fallback() }

        func lastEvent(rising: Bool) -> Date? {
            guard let near = event(rising: rising, at: coordinate, on: now,
                                   calendar: calendar) else { return nil }
            return [near.addingTimeInterval(-86_400), near, near.addingTimeInterval(86_400)]
                .filter { $0 <= now }.max()
        }
        guard let sunrise = lastEvent(rising: true),
              let sunset = lastEvent(rising: false) else { return fallback() }
        return sunrise > sunset
    }

    // MARK: - NOAA

    /// Алгоритм восхода/захода NOAA (упрощённая форма, точность ~2 минуты).
    private static func event(rising: Bool, at coordinate: CLLocationCoordinate2D,
                              on date: Date, calendar: Calendar) -> Date? {
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC")!
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)

        func rad(_ d: Double) -> Double { d * .pi / 180 }
        func deg(_ r: Double) -> Double { r * 180 / .pi }
        func norm(_ v: Double, _ top: Double) -> Double {
            let m = v.truncatingRemainder(dividingBy: top)
            return m < 0 ? m + top : m
        }

        let lngHour = coordinate.longitude / 15
        let t = rising ? dayOfYear + (6 - lngHour) / 24
                       : dayOfYear + (18 - lngHour) / 24

        // Средняя аномалия → истинная долгота Солнца.
        let meanAnomaly = 0.9856 * t - 3.289
        let trueLongitude = norm(meanAnomaly + 1.916 * sin(rad(meanAnomaly))
                                 + 0.020 * sin(rad(2 * meanAnomaly)) + 282.634, 360)

        // Прямое восхождение — в том же квадранте, что долгота.
        var rightAscension = norm(deg(atan(0.91764 * tan(rad(trueLongitude)))), 360)
        rightAscension += (floor(trueLongitude / 90) - floor(rightAscension / 90)) * 90
        rightAscension /= 15

        // Склонение Солнца и часовой угол.
        let sinDec = 0.39782 * sin(rad(trueLongitude))
        let cosDec = cos(asin(sinDec))
        let cosHour = (cos(rad(zenithDegrees)) - sinDec * sin(rad(coordinate.latitude)))
            / (cosDec * cos(rad(coordinate.latitude)))
        guard cosHour >= -1, cosHour <= 1 else { return nil }   // полярный день/ночь

        let hourAngle = (rising ? 360 - deg(acos(cosHour)) : deg(acos(cosHour))) / 15
        let localMean = hourAngle + rightAscension - 0.06571 * t - 6.622
        let utHours = norm(localMean - lngHour, 24)

        var components = utc.dateComponents([.year, .month, .day], from: date)
        components.hour = 0
        guard let midnight = utc.date(from: components) else { return nil }
        let candidate = midnight.addingTimeInterval(utHours * 3600)

        // Свёртка суток. Для восточных долгот восход в UTC приходится на
        // ПРЕДЫДУЩИЕ сутки (Ташкент: 04:52 местного = 23:52 UTC накануне), и
        // нормализация часов в 0…24 уводила событие на день вперёд — первый
        // прогон тестов поймал ровно сутки ошибки. Событие одно на ~24 часа,
        // поэтому правильный вариант — просто ближайший к запрошенному моменту.
        return [candidate.addingTimeInterval(-86_400), candidate,
                candidate.addingTimeInterval(86_400)]
            .min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
    }
}
