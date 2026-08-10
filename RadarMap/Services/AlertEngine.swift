//
//  AlertEngine.swift
//  RadarMap
//
//  Движок порогов приближения к камере: чем ближе — тем выше уровень (1–3).
//  Чистая машина состояний без CLLocation, звука и UI — каждое решение
//  «сигналить или нет» покрыто тестами. Кто и чем сигналит, решает вызывающий.
//

import CoreLocation

nonisolated struct AlertEngine {
    /// «Пора сигналить»: уровень эскалации вырос.
    struct Decision: Equatable {
        /// 1 — вошли в радиус, 2–3 — эскалация сигналов по мере приближения.
        let level: Int
        /// Первое оповещение об этой камере. Уровень может начаться и со второго,
        /// и с третьего: камеру бывает видно поздно — повернули на улицу прямо
        /// перед ней, вернулся сигнал после туннеля, соседняя камера была ближе.
        /// Голос и баннер привязаны к этому флагу, а не к `level == 1`, иначе о
        /// поздно замеченной камере приложение молчит совсем.
        let isFirst: Bool
    }

    /// Достигнутый уровень по каждой камере — повторно на том же уровне не сигналим.
    private var announcedLevel: [Int: Int] = [:]

    /// Умный радиус: предупреждаем за `alertLeadTimeSeconds` до камеры.
    /// Растёт со скоростью (на трассе — раньше), но не ниже базового из настроек.
    static func effectiveRadius(speedKmh: Double, baseRadius: CLLocationDistance) -> CLLocationDistance {
        let bySpeed = (speedKmh / 3.6) * AppConfig.alertLeadTimeSeconds
        return min(AppConfig.maxDynamicRadius, max(baseRadius, bySpeed))
    }

    /// Оценить приближение: вернёт решение, если уровень вырос; nil — молчим.
    /// Выход за радиус с гистерезисом сбрасывает серию — при возврате сигналим заново.
    mutating func evaluate(cameraID: Int, distance: CLLocationDistance,
                           radius: CLLocationDistance) -> Decision? {
        if distance > radius + AppConfig.alertExitHysteresisMeters {
            announcedLevel[cameraID] = 0
            return nil
        }
        // Пороги по убыванию, без массива: решение принимается по каждой
        // камере в радиусе на каждом тике GPS.
        var level = 0
        if distance <= radius { level += 1 }
        if distance <= radius * 0.6 { level += 1 }
        if distance <= radius * 0.3 { level += 1 }
        let previous = announcedLevel[cameraID] ?? 0
        guard level > previous else { return nil }
        announcedLevel[cameraID] = level
        return Decision(level: level, isFirst: previous == 0)
    }

    mutating func reset() {
        announcedLevel.removeAll()
    }
}
