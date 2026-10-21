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
//  Третий (20.9) — ход навстречу линии: развернулись на той же улице или
//  поехали по маршруту задом наперёд. До линии честные 5–30 м, и отклонение
//  не скажет ничего никогда; говорит курс против ветки, которую выбрала
//  проекция, `rerouteWrongWayTicks` фиксов подряд вместе с отступившим
//  прогрессом. Ветку выбирает проекция со штрафом встречным сегментам, так
//  что маршрут-петля, возвращающийся по той же улице обратно, на обратной
//  ветке попутен — и правило молчит.
//
//  Чистая логика — RerouteGateTests.
//

import CoreLocation

nonisolated struct RerouteGate {
    /// Фиксов подряд вне линии.
    private(set) var offRouteTicks = 0
    /// Фиксов подряд дальше `drift` от линии (умеренный, но устойчивый съезд).
    private(set) var driftTicks = 0
    /// Фиксов подряд навстречу линии (20.9).
    private(set) var wrongWayTicks = 0
    /// Прогресс по линии на первом фиксе серии навстречу и на последнем.
    private var wrongWayFrom: CLLocationDistance = 0
    private var wrongWayAlong: CLLocationDistance = 0
    private var lastRebuildAt: Date = .distantPast
    /// Подряд неудачных перестроений.
    private(set) var failures = 0

    /// Ход по линии на этом фиксе (20.9): где на ней проекция (`along`) и
    /// едем ли навстречу ветке, которую проекция выбрала (`against`,
    /// см. `isAgainst`). nil в `note` — правило не действует (маршрут без
    /// сети: его прямые подъезды к трассам ничего не говорят о стороне).
    struct Heading: Equatable {
        var along: CLLocationDistance
        var against: Bool
    }

    /// Навстречу линии: курс достоверен (`course` ≥ 0 — его выдаёт
    /// LocationFilter), едем не медленнее `directionalMinSpeedKmh` и курс
    /// расходится с направлением выбранной ветки больше `rerouteWrongWayDegrees`.
    /// Стоим, курса нет или ветки нет — не навстречу: шум приёмника на
    /// месте и выдержанный курс у светофора маршрут не перестраивают.
    static func isAgainst(course: CLLocationDirection, speedKmh: Double,
                          routeCourse: CLLocationDirection?) -> Bool {
        guard course >= 0, course.isFinite, speedKmh >= AppConfig.directionalMinSpeedKmh,
              let routeCourse, routeCourse >= 0, routeCourse.isFinite else { return false }
        return GeoMath.angleDifference(course, routeCourse) > AppConfig.rerouteWrongWayDegrees
    }

    /// Едем навстречу линии устойчиво: `rerouteWrongWayTicks` фиксов подряд
    /// и прогресс за серию отступил на `rerouteWrongWayBackMeters`. Остатку
    /// «по маршруту» до его камер тогда верить нельзя, как и при съезде.
    var isWrongWay: Bool {
        wrongWayTicks >= AppConfig.rerouteWrongWayTicks
            && wrongWayFrom - wrongWayAlong >= AppConfig.rerouteWrongWayBackMeters
    }

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
    ///
    /// `heading` — ход по линии (20.9), nil — без правила «навстречу».
    mutating func note(deviation: CLLocationDistance, now: Date,
                       limit: CLLocationDistance = AppConfig.rerouteDeviationMeters,
                       drift: CLLocationDistance? = nil,
                       heading: Heading? = nil) -> Bool {
        offRouteTicks = deviation > limit ? offRouteTicks + 1 : 0
        driftTicks = drift.map { deviation > $0 } == true ? driftTicks + 1 : 0
        if let heading, heading.against {
            if wrongWayTicks == 0 { wrongWayFrom = heading.along }
            wrongWayTicks += 1
            wrongWayAlong = heading.along
        } else {
            wrongWayTicks = 0
        }
        let cooldown = AppConfig.rerouteCooldownSeconds * pow(2, Double(min(failures, 4)))
        guard offRouteTicks >= AppConfig.rerouteConfirmTicks || driftTicks >= AppConfig.rerouteDriftTicks
                || isWrongWay,
              now.timeIntervalSince(lastRebuildAt) > cooldown else { return false }
        resetTicks()
        lastRebuildAt = now
        return true
    }

    mutating func noteFailure() { failures += 1 }
    mutating func noteSuccess() { failures = 0 }

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

    /// Новый маршрут или сброс прогресса: счёт съезда — с нуля.
    mutating func resetTicks() {
        offRouteTicks = 0
        driftTicks = 0
        wrongWayTicks = 0
    }
    /// Маршрут снят: и неудачи с нуля.
    mutating func reset() {
        resetTicks()
        failures = 0
    }
}
