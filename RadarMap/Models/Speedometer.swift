//
//  Speedometer.swift
//  RadarMap
//
//  Цифра скорости целиком: стоянка (Standstill), сглаживание (SpeedSmoother)
//  и молчание GPS (SpeedBound) в одном порядке — том, в котором их раньше
//  вызывал LocationService вперемешку с остальным тиком (25.C).
//
//  Пока три части жили в сервисе по отдельности, их сочетание можно было
//  проверить только поездкой: «стоим у стоп-линии — 3 км/ч» (CarPlay, 21.10)
//  рождалось на стыке — стоянка не наступала от доплеровского шума, а фиксы
//  без скорости перезапускали затухание. Здесь стык — чистая структура с
//  временем параметром, покрытая SpeedometerTests: светофор, шум на месте,
//  пропуск фиксов, ползание в пробке, CarPlay без поездки.
//
//  Одна цифра на всех: HUD телефона, CarPlay и его плитка, часы, конвейер
//  оповещений и запись проездов читают `LocationService.speedKmh`. Ниже
//  `SpeedBound.lowKmh` (а шум и стоянка — ниже `standstillNoiseMaxKmh`)
//  оповещения от неё не зависят (радиус базовый, голос с 20 км/ч), а
//  проезд берёт минимум по зоне — ноль вместо шума не пишет нарушений.
//

import CoreLocation
import Foundation

nonisolated struct Speedometer: Sendable {

    /// Стоянка: и скорость, и неподвижная стрелка на карте.
    private(set) var standstill = Standstill()
    private var smoother = SpeedSmoother()
    /// Цифра, км/ч.
    private(set) var kmh: Double = 0
    private var lastFixAt: Date?
    /// Последний фикс с доплером — от него отсчитывается молчание скорости.
    private var lastSpeed: (at: Date, coordinate: CLLocationCoordinate2D)?
    private var lastCoordinate: CLLocationCoordinate2D?

    /// Принятый фикс. `rawKmh < 0` — скорости в фиксе нет: цифра прежняя
    /// (нулём считать нельзя — проезд берёт минимум по зоне), но стоянку
    /// по положению это не отменяет.
    @discardableResult
    mutating func fix(_ coordinate: CLLocationCoordinate2D, rawKmh: Double,
                      speedAccuracyKmh: Double = -1, accuracy: Double, course: Double,
                      motionStationary: Bool = false, at time: Date) -> Double {
        standstill.update(coordinate, rawKmh: rawKmh, speedAccuracyKmh: speedAccuracyKmh,
                          accuracy: accuracy, course: course,
                          motionStationary: motionStationary, at: time)
        if standstill.isStopped {
            smoother.reset()
            kmh = 0
        } else if rawKmh >= 0 {
            kmh = smoother.update(rawKmh: rawKmh, speedAccuracyKmh: speedAccuracyKmh, at: time)
        }
        lastFixAt = time
        lastCoordinate = coordinate
        if rawKmh >= 0 { lastSpeed = (time, coordinate) }
        return kmh
    }

    /// Тик без фикса (раз в секунду, только пока цифра ненулевая). Цифра
    /// гаснет настолько, насколько её опровергает молчание (SpeedBound); на
    /// нуле — стоим: точка остановки — `here` (что сейчас нарисовано).
    @discardableResult
    mutating func silence(at now: Date, distanceFilter: Double, accuracy: Double,
                          motionStationary: Bool = false,
                          here: CLLocationCoordinate2D? = nil) -> Double {
        guard kmh > 0, let lastFixAt else { return kmh }
        let moved: Double
        if let from = lastSpeed?.coordinate, let to = lastCoordinate {
            moved = GeoMath.fastDistance(from.latitude, from.longitude, to.latitude, to.longitude)
        } else {
            moved = 0
        }
        kmh = SpeedBound.capped(kmh, distanceFilter: distanceFilter,
                                secondsSinceFix: now.timeIntervalSince(lastFixAt),
                                secondsSinceSpeed: lastSpeed.map { now.timeIntervalSince($0.at) },
                                movedSinceSpeed: moved, accuracy: accuracy,
                                motionStationary: motionStationary)
        if kmh == 0 {
            smoother.reset()
            standstill.stopIfIdle(at: here ?? lastCoordinate)
        }
        return kmh
    }

    /// Новая поездка: непрерывность сглаживания разорвана, а стоянка — нет
    /// (машина та же и стоит там же).
    mutating func restartSmoothing() {
        smoother.reset()
    }

    /// Тихий фон: непрерывный GPS выключен — всё заново.
    mutating func reset() {
        self = Speedometer()
    }
}
