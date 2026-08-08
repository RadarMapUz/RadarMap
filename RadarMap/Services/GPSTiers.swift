//
//  GPSTiers.swift
//  RadarMap
//
//  Чистое решение «какой тир точности GPS сейчас» — вынуто из
//  LocationService, чтобы порядок правил был закреплён тестами, а не
//  чтением кода рядом с живым CLLocationManager.
//
//  Главная правка против нагрева: «стою» определяется скоростью и временем,
//  а НЕ расстоянием до камеры. Раньше стояночный тир включался только с
//  крейсерского (камеры дальше 1.5 км) — в Ташкенте камера почти всегда
//  ближе, и на каждом светофоре GPS молотил в полную точность, как будто
//  вот-вот проезд. Теперь на стоянке расслабляемся и рядом с камерой — с
//  двумя предохранителями (см. tier), чтобы тревога не пострадала ни на тик.
//
//  Покрыто GPSTiersTests.
//

import Foundation

nonisolated enum GPSTiers {

    /// Всё, что нужно для решения. Собирается LocationService из живых полей.
    struct Situation {
        /// До ближайшей цели (камера или манёвр), метры.
        var nearestTargetMeters: Double
        var speedKmh: Double
        /// Секунд с последнего движения (скорость ≥ 3 км/ч).
        var idleSeconds: TimeInterval
        /// Приборка телефона или схема CarPlay на экране.
        var sketchVisible: Bool
        var isForeground: Bool
        /// Телефон холодный (PerformanceMode == .full).
        var thermalIsFull: Bool
    }

    /// «Стоим»: скорость ниже порога дольше выдержки. Одна дефиниция на тир
    /// GPS и на стояночное затемнение приборки — двум копиям правила нельзя
    /// разъехаться.
    static func isStanding(speedKmh: Double, idleSeconds: TimeInterval,
                           idleAfter: TimeInterval = AppConfig.gpsIdleAfterSeconds) -> Bool {
        speedKmh < AppConfig.gpsStandstillSpeedKmh && idleSeconds > idleAfter
    }

    /// Тир точности: 0 — финал (Best/6 м), 1 — подъезд (10 м/15 м),
    /// 2 — крейсер (10 м/25 м), 3 — стоянка (100 м/30 м, GPS-чип отдыхает).
    ///
    /// Порядок правил значим и закреплён тестами:
    /// 1. База — по дистанции до цели.
    /// 2. Стоянка бьёт базу, но НЕ ближе gpsStandstillNearCameraMeters:
    ///    очередь ползком у самой камеры пишет проезд точно (зона замера
    ///    80 м + запас). Выход мгновенный: первый фикс с движением возвращает
    ///    точный тир, а до камеры остаётся >120 м точного ведения.
    /// 3. Буст плавности схемы — только с крейсера и только на холодном
    ///    телефоне: стоянку не трогаем (стоя анимировать нечего), финал и
    ///    подъезд и так точные.
    static func tier(_ s: Situation) -> Int {
        var tier = s.nearestTargetMeters < AppConfig.gpsPreciseApproachMeters ? 0
                 : s.nearestTargetMeters < AppConfig.gpsMidApproachMeters ? 1 : 2
        if isStanding(speedKmh: s.speedKmh, idleSeconds: s.idleSeconds),
           s.nearestTargetMeters > AppConfig.gpsStandstillNearCameraMeters {
            tier = 3
        }
        if tier == 2, s.sketchVisible, s.isForeground, s.thermalIsFull {
            tier = 1
        }
        return tier
    }
}
