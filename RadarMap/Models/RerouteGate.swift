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
    mutating func note(deviation: CLLocationDistance, now: Date) -> Bool {
        guard deviation > AppConfig.rerouteDeviationMeters else {
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
