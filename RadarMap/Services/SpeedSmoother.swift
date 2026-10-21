//
//  SpeedSmoother.swift
//  RadarMap
//
//  Скорость на спидометре: сглаживать шум, не пряча динамику.
//
//  Прежнее сглаживание было парой констант (0.6 старого + 0.4 нового) и
//  предполагало тик раз в секунду. Но тики НЕ раз в секунду: адаптивный GPS
//  на крейсере отдаёт фикс раз в 15–25 метров, в городе это 2–3 секунды, — и
//  константный вес на редких тиках растягивал хвост на пять с лишним секунд.
//  Водитель тормозит, а цифра ещё едет. Спидометр, который врёт при
//  торможении, хуже дёрганого: по нему принимают решение у камеры.
//
//  Два правила вместо весов:
//  * **Сглаживание зависит от времени**, а не от номера тика: вес нового
//    значения — 1 − exp(−dt/τ). Редкие тики почти не сглаживаются (за три
//    секунды сглаживать уже нечего), частые — как раньше.
//  * **Большой скачок — не шум.** GPS-шум на крейсере — ±2–3 км/ч; перепад
//    больше `snapDeltaKmh` бывает только от настоящего разгона или
//    торможения, и его показываем сразу, без хвоста.
//
//  Чистая структура без обращения к часам — время передаётся параметром,
//  поэтому поведение воспроизводимо в тестах (SpeedSmootherTests).
//

import Foundation

nonisolated struct SpeedSmoother {

    /// Постоянная времени сглаживания: за τ секунд цифра проходит ~63%
    /// разницы. 0.7 с гасит покадровый шум, но не отстаёт заметно глазу.
    static let tau: TimeInterval = 0.7
    /// Перепад, который считаем настоящим изменением скорости, а не шумом.
    static let snapDeltaKmh: Double = 6
    /// Пауза, после которой прошлое значение устарело (туннель, остановка
    /// GPS): начинаем с сырого, сглаживать старую скорость с новой нельзя.
    static let staleAfterSeconds: TimeInterval = 5

    private var value: Double?
    private var lastAt: Date?

    /// Ниже 1 км/ч показываем 0: дрожь стоящего GPS не должна читаться как
    /// «ползу». Тот же порог, что был в LocationService.
    private static func floored(_ kmh: Double) -> Double { kmh < 1 ? 0 : kmh }

    /// `speedAccuracyKmh` — погрешность доплера (< 0 — неизвестна). Медленнее
    /// порога шума и не больше своей погрешности — измерение не отличает
    /// скорость от нуля, и на экран идёт ноль, а не «3–5 км/ч» стоя (25.C).
    /// Ползком 5 км/ч с обычной погрешностью 1–2 км/ч это не задевает.
    mutating func update(rawKmh: Double, speedAccuracyKmh: Double = -1, at now: Date) -> Double {
        defer { lastAt = now }
        let rawKmh = rawKmh < AppConfig.standstillNoiseMaxKmh
            && Standstill.isZeroish(rawKmh: rawKmh, speedAccuracyKmh: speedAccuracyKmh) ? 0 : rawKmh
        guard let previous = value, let lastAt,
              now.timeIntervalSince(lastAt) < Self.staleAfterSeconds else {
            let fresh = Self.floored(rawKmh)
            value = fresh
            return fresh
        }
        if abs(rawKmh - previous) > Self.snapDeltaKmh {
            let fresh = Self.floored(rawKmh)
            value = fresh
            return fresh
        }
        let dt = max(0, now.timeIntervalSince(lastAt))
        let alpha = 1 - exp(-dt / Self.tau)
        let smoothed = Self.floored(previous + (rawKmh - previous) * alpha)
        value = smoothed
        return smoothed
    }

    /// Сброс при смене режима геолокации: непрерывность значений разорвана,
    /// и первое значение нового режима должно быть сырым.
    mutating func reset() {
        value = nil
        lastAt = nil
    }
}

/// Скорость, когда новых фиксов нет.
///
/// На стоянке фиксы не приходят: их не пускает distanceFilter. Спидометр
/// держал последнюю пришедшую скорость — 13 км/ч с момента торможения — и
/// стоящая машина «ехала» (поездка владельца 07.10.2026). Догадка «наверно,
/// стоим» тут не нужна: раз фикса нет, машина сдвинулась меньше чем на
/// distanceFilter, значит её скорость не больше distanceFilter / прошедшее
/// время. Это верхняя граница, а не оценка, — цифра падает ровно настолько,
/// насколько её опровергает молчание GPS, и не ниже.
nonisolated enum SpeedBound {
    /// Сколько секунд после фикса граница не применяется: обычный интервал
    /// между фиксами на ходу.
    static let graceSeconds: TimeInterval = 1.5
    /// Ниже — показываем 0: «ползу 2 км/ч» на стоянке читается как сбой.
    static let floorKmh: Double = 3

    /// Без фильтра расстояния (экран открыт, CarPlay) молчание GPS ничего
    /// не говорит о пройденном — это потеря сигнала, а не «проехали меньше
    /// фильтра». Цифру держим до окна «нет сигнала», потом ноль. До 20.10 без
    /// фильтра граница не применялась вовсе (под землёй на 15 км/ч цифра
    /// застывала навсегда); шаг «10 м за секунду молчания» оказался хуже —
    /// один пропущенный фикс на 90 км/ч ронял её до 18, сжимал радиус
    /// оповещения, и камера звучала дважды (ревью S8).
    static let noFilterHoldSeconds: TimeInterval = 8

    /// Низкая скорость: ниже неё молчание GPS дольше `lowSilenceSeconds`
    /// означает стоянку, а не «ехали, но фикс потерялся» (25.C). Порог ниже
    /// всего, что слушает скорость в конвейере оповещений: радиус на такой
    /// скорости — базовый, направленные гейты включаются с 10 км/ч только
    /// на фиксе, голос — с 20; ноль вместо 12 их не трогает.
    static let lowKmh: Double = 15
    /// Без фильтра расстояния фиксы идут раз в секунду и стоя: два-три
    /// пропущенных на низкой скорости — машина стоит (или приёмник ослеп —
    /// тогда держать скорость ползания тем более незачем).
    static let lowSilenceSeconds: TimeInterval = 2.5
    /// С фильтром: на скорости v фикс приходит раз в distanceFilter / v.
    /// Молчание дольше полутора таких интервалов — средняя скорость упала
    /// ниже двух третей, а на низкой скорости это торможение до нуля.
    static let lowSilenceSlack: Double = 1.5

    /// `secondsSinceSpeed` — с последнего фикса С ДОПЛЕРОМ (nil — тот же, что
    /// `secondsSinceFix`): фиксы без скорости (Wi-Fi стоя, iOS отдаёт −1)
    /// раньше перезапускали отсчёт, и цифра ползания висела, пока они идут.
    /// Но только пока точка стоит: `movedSinceSpeed` больше
    /// max(`standstillExitMeters`, `accuracy`) — едем, просто без доплера.
    /// `motionStationary` — CoreMotion уверен, что стоим (если слежение уже
    /// идёт): на низкой скорости это ноль сразу после обычного интервала.
    static func capped(_ kmh: Double, distanceFilter: Double,
                       secondsSinceFix: TimeInterval,
                       secondsSinceSpeed: TimeInterval? = nil,
                       movedSinceSpeed: Double = 0, accuracy: Double = 0,
                       motionStationary: Bool = false) -> Double {
        guard kmh > 0 else { return kmh }
        if kmh < lowKmh {
            let still = movedSinceSpeed <= max(AppConfig.standstillExitMeters, accuracy)
            let quiet = still ? max(secondsSinceFix, secondsSinceSpeed ?? secondsSinceFix) : secondsSinceFix
            if motionStationary, quiet > graceSeconds { return 0 }
            // Без фильтра фиксы обязаны идти и стоя; ниже порога шума цифра
            // и так могла быть шумом — при любом фильтре молчание дольше
            // `lowSilenceSeconds` значит ноль (пропуск фиксов на стоянке).
            if distanceFilter <= 0 || kmh < AppConfig.standstillNoiseMaxKmh {
                if quiet >= lowSilenceSeconds { return 0 }
            } else if quiet >= max(lowSilenceSeconds,
                                   distanceFilter / (kmh / 3.6) * lowSilenceSlack) {
                return 0
            }
        }
        guard secondsSinceFix > graceSeconds else { return kmh }
        guard distanceFilter > 0 else { return secondsSinceFix >= noFilterHoldSeconds ? 0 : kmh }
        let bound = distanceFilter / secondsSinceFix * 3.6
        let value = min(kmh, bound)
        return value < floorKmh ? 0 : value
    }
}
