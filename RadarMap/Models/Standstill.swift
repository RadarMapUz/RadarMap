//
//  Standstill.swift
//  RadarMap
//
//  Стоянка: машина стоит, а GPS — нет.
//
//  На месте приёмник продолжает присылать точки: они гуляют на 5–30 м
//  (в городе больше — отражения от домов), доплеровская скорость показывает
//  2–7 км/ч, курс крутится. Водитель видел ровно это: «скорость при
//  остановке не падает до нуля, и стрелка после остановки уходит куда-то
//  назад» (владелец, CarPlay, 12.10). Сглаживание скорости тут не поможет —
//  шум не убывает, он и есть сигнал приёмника на месте.
//
//  Решение — состояние, а не фильтр:
//    * вход: доплеровская скорость ниже `standstillEnterKmh` держится
//      `standstillEnterSeconds` — машина стоит; точка остановки запоминается;
//    * на стоянке: скорость — ровно 0, положение на карте — точка остановки
//      и курс до неё: стрелка не повторяет блуждание приёмника;
//    * вход по шуму (25.C): доплер на месте гуляет 3–8 км/ч, и порог
//      3,5 км/ч не наступал никогда — тогда решает положение: за две
//      секунды точка почти не сдвинулась и прошла куда меньше, чем обещал
//      доплер (или доплер сам в пределах своей погрешности, или CoreMotion
//      видит стоянку);
//    * выход: один уверенный фикс (скорость ≥ `standstillExitKmh` и ≥ трёх
//      своих погрешностей), два фикса подряд не медленнее `standstillExitKmh`
//      (и двух погрешностей, если она известна) или смещение от точки остановки больше
//      max(`standstillExitMeters`, точность фикса) — тогда это уже не шум,
//      а ползком в пробке; ползком прочь от точки остановки (два фикса не
//      медленнее порога входа и половина того смещения) — тоже выход.
//
//  Только для показа и скорости: оповещения, трек и проезды по-прежнему
//  считаются по сырому фиксу (LocationService). Чистая логика, время —
//  параметром; покрыто StandstillTests.
//

import CoreLocation
import Foundation

nonisolated struct Standstill: Sendable {

    /// Стоим ли сейчас.
    private(set) var isStopped = false
    /// Точка остановки и курс до неё — что рисовать, пока стоим.
    private(set) var anchor: CLLocationCoordinate2D?
    private(set) var anchorCourse: Double = -1

    private var slowSince: Date?
    private var slowStart: CLLocationCoordinate2D?
    /// Медленный отрезок начат фиксом БЕЗ скорости — о стоянке говорит одно
    /// положение, и ждать его подтверждения дольше (`standstillBlindEnterSeconds`).
    private var startedBlind = false
    private var fastFixes = 0
    /// Подряд фиксов не медленнее порога входа (ползком прочь со стоянки).
    private var movingFixes = 0
    private var lastCourse: Double = -1

    /// Фикс с доплером ниже `standstillNoiseMaxKmh` — кандидат в шум.
    private struct Sample: Sendable {
        let at: Date
        let coordinate: CLLocationCoordinate2D
        let kmh: Double
        /// Доплер не больше своей погрешности: «может быть и ноль».
        let zeroish: Bool
    }
    /// Непрерывный ряд таких фиксов за последние секунды, новые в конце.
    private var calm: [Sample] = []

    /// Скорость в пределах своей погрешности — измерение не отличает её от
    /// нуля. `speedAccuracyKmh < 0` — погрешность неизвестна: не «ноль».
    nonisolated static func isZeroish(rawKmh: Double, speedAccuracyKmh: Double) -> Bool {
        rawKmh >= 0 && speedAccuracyKmh >= 0 && rawKmh <= speedAccuracyKmh
    }

    /// Принятый фикс. `rawKmh < 0` — скорости в фиксе нет (решаем по смещению),
    /// `course < 0` — курса нет, `speedAccuracyKmh < 0` — погрешность скорости
    /// неизвестна. `motionStationary` — CoreMotion уверен, что стоим (только
    /// если слежение за движением уже идёт, MotionService).
    mutating func update(_ coordinate: CLLocationCoordinate2D, rawKmh: Double,
                         speedAccuracyKmh: Double = -1,
                         accuracy: Double, course: Double,
                         motionStationary: Bool = false, at time: Date) {
        let zeroish = Self.isZeroish(rawKmh: rawKmh, speedAccuracyKmh: speedAccuracyKmh)
        if isStopped {
            guard let anchor else { return leave() }
            let moved = GeoMath.fastDistance(anchor.latitude, anchor.longitude,
                                             coordinate.latitude, coordinate.longitude)
            // С известной погрешностью «быстрый» фикс — ещё и вне двух её
            // величин (шум 7 км/ч при погрешности 4 — шум), «уверенный» —
            // вне трёх: тронулись, число на экран сразу.
            let sigma = max(speedAccuracyKmh, 0)
            let fast = rawKmh >= max(AppConfig.standstillExitKmh, 2 * sigma) && !zeroish
            let sure = fast && speedAccuracyKmh >= 0
                && rawKmh >= AppConfig.standstillExitSigmas * speedAccuracyKmh
            fastFixes = fast ? fastFixes + 1 : 0
            movingFixes = rawKmh >= AppConfig.standstillEnterKmh && !zeroish ? movingFixes + 1 : 0
            if sure || fastFixes >= 2
                || moved > max(AppConfig.standstillExitMeters, accuracy)
                || (movingFixes >= 2 && moved > max(AppConfig.standstillExitMeters / 2, accuracy)) {
                leave()
            }
            return
        }
        if course >= 0 { lastCourse = course }
        rememberCalm(coordinate, rawKmh: rawKmh, zeroish: zeroish, at: time)
        if let start = noiseStop(motionStationary: motionStationary) {
            return stop(at: start)
        }
        // Скорости нет — медленным считаем, только пока точка почти на месте
        // относительно начала медленного отрезка.
        let slow: Bool
        var blind = false
        if rawKmh >= 0 {
            slow = rawKmh < AppConfig.standstillEnterKmh
        } else if let start = slowStart {
            slow = GeoMath.fastDistance(start.latitude, start.longitude,
                                        coordinate.latitude, coordinate.longitude)
                < AppConfig.standstillExitMeters
        } else {
            // Скорости нет, а медленного отрезка ещё нет — начинаем его по
            // положению. Раньше здесь было «не медленно», и машина, вставшая
            // под фиксами без скорости (Wi-Fi в подземном паркинге, iOS
            // отдаёт −1 стоя; симулятор на стоянке), не вставала НИКОГДА:
            // спидометр держал последние 40 км/ч, а полноэкранная тревога о
            // камере в 300 м позади висела, пока не тронешься (прогон 13.3).
            slow = true
            blind = true
        }
        guard slow else {
            slowSince = nil
            slowStart = nil
            startedBlind = false
            return
        }
        if slowSince == nil {
            slowSince = time
            slowStart = coordinate
            startedBlind = blind
        } else if rawKmh >= 0 {
            startedBlind = false   // доплер подтвердил: медленно — обычный порог
        }
        let needed = startedBlind ? AppConfig.standstillBlindEnterSeconds
                                  : AppConfig.standstillEnterSeconds
        if let since = slowSince, time.timeIntervalSince(since) >= needed {
            stop(at: slowStart ?? coordinate)
        }
    }

    /// Ряд фиксов-кандидатов в шум: рвётся фиксом быстрее порога шума или
    /// без скорости, старше окна — выбрасывается.
    private mutating func rememberCalm(_ coordinate: CLLocationCoordinate2D, rawKmh: Double,
                                       zeroish: Bool, at time: Date) {
        guard rawKmh >= 0, rawKmh < AppConfig.standstillNoiseMaxKmh else {
            calm.removeAll(keepingCapacity: true)
            return
        }
        calm.append(Sample(at: time, coordinate: coordinate, kmh: rawKmh, zeroish: zeroish))
        let horizon = AppConfig.standstillEnterSeconds * 2
        calm.removeAll { time.timeIntervalSince($0.at) > horizon }
    }

    /// Стоим по шуму: последние `standstillEnterSeconds` (не меньше трёх
    /// фиксов) доплер ниже порога шума, а положение ему противоречит.
    /// Возвращает точку начала окна — она и станет точкой остановки.
    private func noiseStop(motionStationary: Bool) -> CLLocationCoordinate2D? {
        guard let last = calm.last,
              let from = calm.lastIndex(where: {
                  last.at.timeIntervalSince($0.at) >= AppConfig.standstillEnterSeconds
              }),
              calm.count - from >= 3 else { return nil }
        let window = calm[from...]
        let first = window[window.startIndex]
        let net = GeoMath.fastDistance(first.coordinate.latitude, first.coordinate.longitude,
                                       last.coordinate.latitude, last.coordinate.longitude)
        // Доплер «может быть и ноль» или CoreMotion видит стоянку — положению
        // достаточно почти не сдвинуться.
        if net < AppConfig.standstillNoiseStillMeters,
           motionStationary || window.allSatisfy(\.zeroish) {
            return first.coordinate
        }
        guard net < AppConfig.standstillNoiseNetMeters else { return nil }
        // Путь, который обещал доплер (трапеции между фиксами).
        var promised = 0.0
        for (a, b) in zip(window, window.dropFirst()) {
            promised += (a.kmh + b.kmh) / 2 / 3.6 * b.at.timeIntervalSince(a.at)
        }
        return net < AppConfig.standstillNoiseNetShare * promised ? first.coordinate : nil
    }

    private mutating func stop(at point: CLLocationCoordinate2D) {
        isStopped = true
        anchor = point
        anchorCourse = lastCourse
        fastFixes = 0
        movingFixes = 0
        calm.removeAll(keepingCapacity: true)
    }

    /// Фиксов нет, а скорость уже погасла до нуля (затухание спидометра) —
    /// стоим по определению: точка остановки — последняя известная.
    mutating func stopIfIdle(at coordinate: CLLocationCoordinate2D?) {
        guard !isStopped, let coordinate else { return }
        stop(at: coordinate)
    }

    private mutating func leave() {
        isStopped = false
        anchor = nil
        slowSince = nil
        slowStart = nil
        startedBlind = false
        fastFixes = 0
        movingFixes = 0
        calm.removeAll(keepingCapacity: true)
    }
}
