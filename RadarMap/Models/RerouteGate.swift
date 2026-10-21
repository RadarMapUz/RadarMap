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
//  Второй путь к съезду (21.10) — умеренное отклонение, но устойчивое:
//  `rerouteDriftMeters` `rerouteDriftTicks` фиксов подряд. Свернув мимо
//  поворота, машина не обязана уйти от линии на 150 м три фикса подряд:
//  проекция цепляется за попутный курсу кусок маршрута впереди, и отклонение
//  пляшет вокруг порога, сбрасывая счёт.
//
//  Чистая логика — RerouteGateTests.
//

import CoreLocation

nonisolated struct RerouteGate {
    /// Фиксов подряд вне линии.
    private(set) var offRouteTicks = 0
    /// Фиксов подряд дальше `drift` от линии (умеренный, но устойчивый съезд).
    private(set) var driftTicks = 0
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
    ///
    /// `drift` — порог устойчивого съезда (`rerouteDriftMeters`), nil — без
    /// этого правила (маршрут без сети: его прямые подъезды и так далеко).
    mutating func note(deviation: CLLocationDistance, now: Date,
                       limit: CLLocationDistance = AppConfig.rerouteDeviationMeters,
                       drift: CLLocationDistance? = nil) -> Bool {
        offRouteTicks = deviation > limit ? offRouteTicks + 1 : 0
        driftTicks = drift.map { deviation > $0 } == true ? driftTicks + 1 : 0
        let cooldown = AppConfig.rerouteCooldownSeconds * pow(2, Double(min(failures, 4)))
        guard offRouteTicks >= AppConfig.rerouteConfirmTicks || driftTicks >= AppConfig.rerouteDriftTicks,
              now.timeIntervalSince(lastRebuildAt) > cooldown else { return false }
        offRouteTicks = 0
        driftTicks = 0
        lastRebuildAt = now
        return true
    }

    mutating func noteFailure() { failures += 1 }
    mutating func noteSuccess() { failures = 0 }

    /// Новый маршрут или сброс прогресса: счёт съезда — с нуля.
    /// Порог устойчивого съезда с запасом на погрешность фикса — то же
    /// правило 1:1 сверх 10 м, что у коридора и повторного подхода (14.14–14.16).
    /// Между домами позицию уводит на 40–60 м при верном курсе, и голые 50 м
    /// перестраивали бы маршрут по кругу с «Маршрут перестроен». nil — точность
    /// не передали (тесты): без запаса.
    static func driftLimit(accuracy: CLLocationAccuracy?) -> CLLocationDistance {
        guard let accuracy else { return AppConfig.rerouteDriftMeters }
        return AppConfig.rerouteDriftMeters
            + RoadCorridor.accuracyAllowance(LocationGates.accuracyOrPoorest(accuracy))
    }

    mutating func resetTicks() {
        offRouteTicks = 0
        driftTicks = 0
    }
    /// Маршрут снят: и неудачи с нуля.
    mutating func reset() {
        resetTicks()
        failures = 0
    }
}
