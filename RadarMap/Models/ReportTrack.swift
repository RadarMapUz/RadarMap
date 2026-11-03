//
//  ReportTrack.swift
//  RadarMap
//
//  Где стояла тренога, если водитель нажал, уже проехав её (картограф, A4).
//
//  Раньше отметка сдвигалась назад ПО ПРЯМОЙ по курсу на «скорость × 2 с».
//  Модель картографа (200 тыс. прогонов) показала, чем это плохо: 29–45 %
//  точек вставали дальше треноги на 10+ м (опасная сторона — следующий
//  водитель слышит предупреждение позже), у Siri — все 100 % на 46–83 м; а
//  если водитель свернул сразу после треноги, прямая уводила точку на
//  поперечную улицу. Возраст фикса при этом прибавлялся к сдвигу, хотя
//  устаревший фикс и так ближе к треноге.
//
//  Теперь место берётся с собственного трека: кольцо принятых фиксов за
//  последние секунды, каждый со своим временем. Точка — там, где машина была
//  в момент «касание − реакция», по самому треку, с его поворотами; время
//  фикса учтено само собой. Сдвиг не дальше `reportMaxBackMeters` по треку.
//  Трека нет (первая секунда, тихий фон) — прежний сдвиг по прямой на то же
//  время реакции с тем же потолком.
//
//  Ошибка несимметрична: точка раньше треноги предупредит следующего чуть
//  загодя, точка позже — когда он уже проехал. Поэтому вперёд от последнего
//  фикса не экстраполируем никогда.
//
//  Чистая логика, покрыто ReportTrackTests.
//

import CoreLocation
import Foundation

nonisolated struct ReportTrack: Equatable {

    struct Point: Equatable {
        var latitude: Double
        var longitude: Double
        var at: Date

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    /// Старое забываем: дальше `seconds` назад сдвиг не уходит никогда.
    private(set) var points: [Point] = []
    var seconds: TimeInterval = AppConfig.reportTrackSeconds

    /// Принятый фикс. Время — время самого фикса, а не приёма.
    mutating func append(_ coordinate: CLLocationCoordinate2D, at time: Date) {
        // Фиксы приходят по порядку; запоздавший пропускаем, а не сортируем:
        // на горячем пути GPS каждая операция на счету.
        if let last = points.last, time <= last.at { return }
        points.append(Point(latitude: coordinate.latitude, longitude: coordinate.longitude, at: time))
        let cutoff = time.addingTimeInterval(-seconds)
        if let first = points.first, first.at < cutoff {
            points.removeAll { $0.at < cutoff }
        }
    }

    /// Место отметки и курс НА НЁМ.
    ///
    /// Курс — пеленг отрезка трека в точке сдвига, а не курс в момент касания:
    /// свернул сразу после треноги — точка на улице A, а курс касания уже от
    /// улицы B, и снап с ним садил её на B, а сервер получал чужое направление
    /// (ревью 40b, Н6). Отрезок короче `minBearingLegMeters` (стоим) — курс
    /// неизвестен (-1): тогда снап по ближайшей оси, а вопрос задаётся всем.
    struct Origin: Equatable {
        var latitude: Double
        var longitude: Double
        var course: Double

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    /// Короче — пеленгу отрезка не верим: это шум GPS на месте.
    static let minBearingLegMeters: CLLocationDistance = 3

    /// Где машина была в момент `touch − reaction`, по треку.
    ///
    /// nil — трека нет: вызывающий сдвигает по прямой (`origin`).
    /// Позже последнего фикса — последний фикс (вперёд не экстраполируем).
    /// Сдвиг по треку от последнего фикса — не дальше `maxMeters`.
    static func position(in points: [Point], touch: Date, reaction: TimeInterval,
                         maxMeters: CLLocationDistance = AppConfig.reportMaxBackMeters)
        -> CLLocationCoordinate2D? {
        placed(in: points, touch: touch, reaction: reaction, maxMeters: maxMeters)?.coordinate
    }

    /// То же с курсом отрезка, на котором встала точка.
    static func placed(in points: [Point], touch: Date, reaction: TimeInterval,
                       maxMeters: CLLocationDistance = AppConfig.reportMaxBackMeters) -> Origin? {
        guard let newest = points.last else { return nil }
        let target = touch.addingTimeInterval(-reaction)
        if target >= newest.at {
            let course = points.count >= 2 ? bearing(from: points[points.count - 2], to: newest) : -1
            return Origin(latitude: newest.latitude, longitude: newest.longitude, course: course)
        }
        var walked: CLLocationDistance = 0
        var index = points.count - 1
        while index > 0 {
            let later = points[index], earlier = points[index - 1]
            let leg = GeoMath.fastDistance(later.latitude, later.longitude, earlier.latitude, earlier.longitude)
            let course = bearing(from: earlier, to: later)
            // Нужная минута — на этом отрезке: доля по времени.
            if target >= earlier.at {
                let span = later.at.timeIntervalSince(earlier.at)
                let share = span > 0 ? later.at.timeIntervalSince(target) / span : 0
                let back = min(leg * share, max(0, maxMeters - walked))
                return Self.origin(Self.point(from: later, toward: earlier, meters: back, leg: leg), course)
            }
            // Потолок наступил раньше нужной минуты — встаём на нём.
            if walked + leg >= maxMeters {
                return Self.origin(Self.point(from: later, toward: earlier, meters: maxMeters - walked, leg: leg),
                                   course)
            }
            walked += leg
            index -= 1
        }
        // Трек короче нужного — самая старая точка (раньше ничего не знаем).
        let course = points.count >= 2 ? bearing(from: points[0], to: points[1]) : -1
        return Origin(latitude: points[0].latitude, longitude: points[0].longitude, course: course)
    }

    /// Место отметки: по треку, а без трека — прежний сдвиг по прямой на
    /// то же время реакции и с тем же потолком (курс тогда — курс касания).
    static func origin(points: [Point], touch: Date, reaction: TimeInterval,
                       coordinate: CLLocationCoordinate2D, course: Double, speedKmh: Double,
                       maxMeters: CLLocationDistance = AppConfig.reportMaxBackMeters) -> Origin {
        if let onTrack = placed(in: points, touch: touch, reaction: reaction, maxMeters: maxMeters) {
            return onTrack
        }
        guard course >= 0, speedKmh >= ReportPlacement.minBackdateSpeedKmh, reaction > 0 else {
            return Origin(latitude: coordinate.latitude, longitude: coordinate.longitude, course: course)
        }
        let meters = min(maxMeters, speedKmh / 3.6 * reaction)
        let back = (course + 180).truncatingRemainder(dividingBy: 360)
        let point = GeoMath.destination(from: coordinate, bearing: back, distanceMeters: meters)
        return Origin(latitude: point.latitude, longitude: point.longitude, course: course)
    }

    private static func origin(_ point: CLLocationCoordinate2D, _ course: Double) -> Origin {
        Origin(latitude: point.latitude, longitude: point.longitude, course: course)
    }

    /// Пеленг отрезка; короткий (стоим) — неизвестен.
    private static func bearing(from a: Point, to b: Point) -> Double {
        guard GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude) >= minBearingLegMeters
        else { return -1 }
        return GeoMath.bearing(from: a.coordinate, to: b.coordinate)
    }

    /// Точка на отрезке `from → toward` в `meters` от `from`.
    private static func point(from a: Point, toward b: Point, meters: Double,
                              leg: CLLocationDistance) -> CLLocationCoordinate2D {
        guard leg > 0 else { return a.coordinate }
        let t = min(1, max(0, meters / leg))
        return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                      longitude: a.longitude + (b.longitude - a.longitude) * t)
    }
}
