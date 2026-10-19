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

import CoreLocation
import Foundation

nonisolated enum GPSTiers {

    /// Всё, что нужно для решения. Собирается LocationService из живых полей.
    struct Situation {
        /// До ближайшей цели (камера или манёвр), метры.
        var nearestTargetMeters: Double
        var speedKmh: Double
        /// Секунд с последнего движения (скорость ≥ 3 км/ч).
        var idleSeconds: TimeInterval
    }

    /// «Стоим»: скорость ниже порога дольше выдержки. Второй потребитель —
    /// стояночное затемнение приборки — ушёл вместе со спидометром, поэтому
    /// выдержка одна, GPS-ная.
    static func isStanding(speedKmh: Double, idleSeconds: TimeInterval) -> Bool {
        speedKmh < AppConfig.gpsStandstillSpeedKmh && idleSeconds > AppConfig.gpsIdleAfterSeconds
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
    ///
    /// Буста плавности больше нет: он существовал ради схемы CarPlay, а схема
    /// убрана 11.10. Карта движка плавна и на крейсерских 25 м — она тянет
    /// метку между фиксами анимацией.
    static func tier(_ s: Situation) -> Int {
        var tier = s.nearestTargetMeters < AppConfig.gpsPreciseApproachMeters ? 0
                 : s.nearestTargetMeters < AppConfig.gpsMidApproachMeters ? 1 : 2
        if isStanding(speedKmh: s.speedKmh, idleSeconds: s.idleSeconds),
           s.nearestTargetMeters > AppConfig.gpsStandstillNearCameraMeters {
            tier = 3
        }
        return tier
    }

    /// Точность и фильтр расстояния для тира.
    ///
    /// `watched` — на карту смотрят: подключён экран машины или телефон
    /// открыт. Тогда фильтра расстояния нет вовсе, а на стоянке точность не
    /// падает до сотни метров. Причина — поле 12.10 («спидометр не успевает,
    /// карта рывками»): на крейсере фильтр 25 м давал фикс раз в 2–3 с на
    /// 40 км/ч — цифра скорости и камера карты ехали ступенями, а со стоянки
    /// (фильтр 30 м) первый фикс приходил метров через тридцать: машина уже
    /// ехала, а на экране стоял ноль. Фильтр не экономит чип — он только
    /// прореживает фиксы; экономия стоянки — в точности, а у смотрящего
    /// водителя она не нужна: экран и так горит сильнее GPS. В кармане (никто
    /// не смотрит) лестница прежняя.
    static func request(tier: Int, watched: Bool) -> Request {
        if watched {
            switch tier {
            case 0:  return Request(accuracy: kCLLocationAccuracyBest, distanceFilter: kCLDistanceFilterNone)
            default: return Request(accuracy: kCLLocationAccuracyNearestTenMeters,
                                    distanceFilter: kCLDistanceFilterNone)
            }
        }
        switch tier {
        case 0:  return Request(accuracy: kCLLocationAccuracyBest, distanceFilter: 6)
        case 1:  return Request(accuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 15)
        case 2:  return Request(accuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 25)
        // Стоянка: GPS-чип отдыхает; тронулись — первый тик вернёт тир.
        default: return Request(accuracy: kCLLocationAccuracyHundredMeters, distanceFilter: 30)
        }
    }

    /// Тир с оглядкой на энергосбережение.
    ///
    /// Раньше Low Power Mode просто ВЫКЛЮЧАЛ лестницу, и вместо неё на всю
    /// поездку вставали фиксированные десять метров с фильтром 20. Это
    /// инверсия: самая дешёвая ступень лестницы — стоянка — стоит 100 метров и
    /// фильтр 30, то есть режим, включённый ради экономии, запрещал самую
    /// большую экономию. Час в пробке или на парковке с идущей поездкой
    /// обходился дороже ИМЕННО в энергосбережении.
    ///
    /// Правильно наоборот: лестница работает, недоступна только верхняя,
    /// самая дорогая ступень. Точность «Best» — это про подъезд к камере, и в
    /// режиме экономии её честно уступают десяти метрам.
    static func tier(_ s: Situation, lowPower: Bool) -> Int {
        let base = tier(s)
        return lowPower ? max(base, 1) : base
    }

    // MARK: - Открытое приложение без поездки

    /// Что просить у системы.
    struct Request: Equatable {
        var accuracy: CLLocationAccuracy
        var distanceFilter: CLLocationDistance
    }

    /// Просьба для открытого экрана без поездки и без машины.
    ///
    /// Здесь просили «до 10 м» (в энергосбережении — «до 100 м»), и в
    /// помещении система честно исполняла это точками по Wi-Fi хуже 65 м.
    /// Фильтр (`maxHorizontalAccuracyMeters`) их бракует, а значит ни одного
    /// принятого фикса: экран навсегда застревал в «уточняем положение» с
    /// меткой в 100–300 м от человека. Телефон владельца, 11.10: Apple Карты
    /// ставили точку на место, RadarMap — нет. Запрос «до 100 м» вообще был
    /// хуже порога фильтра, то есть в энергосбережении принятых фиксов не
    /// бывало по построению.
    ///
    /// Теперь как у Apple Карт: «Best». Экран при этом всё равно включён, и
    /// разница в расходе с «до 10 м» на его фоне мала. В энергосбережении —
    /// десять метров: в пределах порога фильтра, а если и они бракуются,
    /// просьбу поднимет `escalatedAccuracy`.
    ///
    /// `idle` — телефон лежит (нет движения `gpsIdleAfterSeconds`), а точка
    /// уже есть: «Best» на столе дома держал GPS-чип на максимуме, пока
    /// человек смотрит карту (аудит энергии 19.10). Тогда — «до 10 м» и фильтр
    /// 30 м: первый же фикс в движении вернёт «Best» (LocationService).
    static func foreground(lowPower: Bool, idle: Bool = false) -> Request {
        if idle { return Request(accuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 30) }
        return lowPower ? Request(accuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 20)
                        : Request(accuracy: kCLLocationAccuracyBest, distanceFilter: 10)
    }

    /// Лежит ли телефон открытого экрана: стоим дольше порога и точка есть.
    static func foregroundIdle(idleSeconds: TimeInterval, hasPosition: Bool) -> Bool {
        hasPosition && idleSeconds >= AppConfig.gpsIdleAfterSeconds
    }

    /// Фикс открытого экрана забракован по точности: какую точность просить
    /// теперь. nil — уже просим максимум, поднимать некуда.
    static func escalatedAccuracy(from requested: CLLocationAccuracy) -> CLLocationAccuracy? {
        requested == kCLLocationAccuracyBest ? nil : kCLLocationAccuracyBest
    }
}
