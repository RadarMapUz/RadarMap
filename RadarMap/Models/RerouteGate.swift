//
//  RerouteGate.swift
//  RadarMap
//
//  Когда перестраивать маршрут после съезда (сценарий 12в A6). Решение жило
//  внутри RouteService.updateProgress рядом с живым MKDirections и не
//  проверялось ничем: шум GPS не должен перестраивать (подтверждение
//  `rerouteConfirmTicks` фиксами подряд), вернулись на линию — счёт с нуля,
//  после перестроения — кулдаун, и каждая неудача удваивает его (×16 потолок):
//  без бэкоффа при мёртвой сети перестроение долбило бы MKDirections и OSRM
//  каждые 20 с всё время объезда.
//
//  Чистая логика — RerouteGateTests.
//

import CoreLocation

nonisolated struct RerouteGate {
    /// Фиксов подряд вне линии.
    private(set) var offRouteTicks = 0
    private var lastRebuildAt: Date = .distantPast
    /// Подряд неудачных перестроений.
    private(set) var failures = 0

    /// Фикс: отклонение от линии. true — пора перестраивать (счётчик и
    /// время перестроения уже отмечены).
    ///
    /// `limit` — с какого отклонения это съезд. У маршрута без сети он свой
    /// (`offlineRouteRerouteMeters`): подъезд к графу трасс и от него — прямая
    /// до трёх километров через кварталы, и водитель, едущий по улицам к
    /// трассе, уходил от неё дальше 150 м сам. Перестроение без сети давало
    /// ту же прямую от новой точки — и так по кругу: A* по всей стране и
    /// «Маршрут перестроен» каждые полминуты до самой трассы (ревью 14.2).
    mutating func note(deviation: CLLocationDistance, now: Date,
                       limit: CLLocationDistance = AppConfig.rerouteDeviationMeters) -> Bool {
        guard deviation > limit else {
            offRouteTicks = 0
            return false
        }
        offRouteTicks += 1
        let cooldown = AppConfig.rerouteCooldownSeconds * pow(2, Double(min(failures, 4)))
        guard offRouteTicks >= AppConfig.rerouteConfirmTicks,
              now.timeIntervalSince(lastRebuildAt) > cooldown else { return false }
        offRouteTicks = 0
        lastRebuildAt = now
        return true
    }

    mutating func noteFailure() { failures += 1 }
    mutating func noteSuccess() { failures = 0 }

    /// Новый маршрут или сброс прогресса: счёт съезда — с нуля.
    mutating func resetTicks() { offRouteTicks = 0 }
    /// Маршрут снят: и неудачи с нуля.
    mutating func reset() {
        offRouteTicks = 0
        failures = 0
    }
}
