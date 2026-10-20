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
//    * выход: два фикса подряд не медленнее `standstillExitKmh` (тронулись)
//      или смещение от точки остановки больше max(`standstillExitMeters`,
//      точность фикса) — тогда это уже не шум, а ползком в пробке.
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
    private var lastCourse: Double = -1

    /// Принятый фикс. `rawKmh < 0` — скорости в фиксе нет (решаем по смещению),
    /// `course < 0` — курса нет.
    mutating func update(_ coordinate: CLLocationCoordinate2D, rawKmh: Double,
                         accuracy: Double, course: Double, at time: Date) {
        if isStopped {
            guard let anchor else { return leave() }
            let moved = GeoMath.fastDistance(anchor.latitude, anchor.longitude,
                                             coordinate.latitude, coordinate.longitude)
            fastFixes = rawKmh >= AppConfig.standstillExitKmh ? fastFixes + 1 : 0
            if fastFixes >= 2
                || moved > max(AppConfig.standstillExitMeters, accuracy) {
                leave()
            }
            return
        }
        if course >= 0 { lastCourse = course }
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
            isStopped = true
            anchor = slowStart ?? coordinate
            anchorCourse = lastCourse
            fastFixes = 0
        }
    }

    /// Фиксов нет, а скорость уже погасла до нуля (затухание спидометра) —
    /// стоим по определению: точка остановки — последняя известная.
    mutating func stopIfIdle(at coordinate: CLLocationCoordinate2D?) {
        guard !isStopped, let coordinate else { return }
        isStopped = true
        anchor = coordinate
        anchorCourse = lastCourse
        fastFixes = 0
    }

    mutating func reset() {
        self = Standstill()
    }

    private mutating func leave() {
        isStopped = false
        anchor = nil
        slowSince = nil
        slowStart = nil
        startedBlind = false
        fastFixes = 0
    }
}
