//
//  RerouteGateTests.swift
//  RadarMapTests
//
//  Сценарий A6 (12в): съезд с маршрута → перестроение; шум GPS и возврат
//  на линию — без лишнего перестроения; неудачи удваивают паузу.
//

import XCTest
@testable import RadarMap

final class RerouteGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let off = AppConfig.rerouteDeviationMeters + 50
    private let on = 10.0

    private func run(_ gate: inout RerouteGate, _ deviations: [Double], from start: TimeInterval = 0) -> [Int] {
        deviations.enumerated().compactMap { index, deviation in
            gate.note(deviation: deviation, now: t0.addingTimeInterval(start + Double(index))) ? index : nil
        }
    }

    func testRealDetourRebuildsAfterConfirmation() {
        var gate = RerouteGate()
        let ticks = AppConfig.rerouteConfirmTicks
        XCTAssertEqual(run(&gate, Array(repeating: on, count: 5) + Array(repeating: off, count: ticks)), [5 + ticks - 1])
    }

    /// Маршрут без сети (12б.10): подъезд к трассе — прямая через кварталы до
    /// трёх километров, и улицы к ней уходят от неё на сотни метров. С
    /// обычным порогом это перестраивало без конца — та же прямая от новой
    /// точки и «Маршрут перестроен» каждые полминуты (ревью 14.2). Свой порог
    /// пропускает улицы, но не другую трассу.
    func testOfflineRouteToleratesItsStraightApproach() {
        let limit = AppConfig.offlineRouteRerouteMeters
        let ticks = AppConfig.rerouteConfirmTicks
        var gate = RerouteGate()
        let streets = Array(repeating: 900.0, count: 3 * ticks)
        XCTAssertEqual(streets.enumerated().filter { index, deviation in
            gate.note(deviation: deviation, now: t0.addingTimeInterval(Double(index) * 30), limit: limit)
        }.count, 0, "в 900 м от прямой подъезда — ещё не съезд")
        XCTAssertEqual(gate.offRouteTicks, 0)
        var elsewhere = RerouteGate()
        let gone = Array(repeating: limit + 500, count: ticks)
        XCTAssertEqual(gone.enumerated().filter { index, deviation in
            elsewhere.note(deviation: deviation, now: t0.addingTimeInterval(Double(index)), limit: limit)
        }.map(\.offset), [ticks - 1], "ушли на другую трассу — перестраиваем")
        // Обычный маршрут — прежние 150 м.
        var regular = RerouteGate()
        XCTAssertFalse(run(&regular, Array(repeating: 900.0, count: ticks)).isEmpty)
    }

    func testNoiseAndReturnToTheLineDoNotRebuild() {
        var gate = RerouteGate()
        // Выброс на 2 фикса и обратно на линию — дважды подряд: счёт с нуля.
        XCTAssertEqual(run(&gate, [on, off, off, on, off, off, on, on]), [])
        XCTAssertEqual(gate.offRouteTicks, 0)
    }

    func testCooldownAfterARebuildAndBackoffOnFailures() {
        var gate = RerouteGate()
        let ticks = AppConfig.rerouteConfirmTicks
        XCTAssertFalse(run(&gate, Array(repeating: off, count: ticks)).isEmpty)
        // Ещё в объезде сразу после перестроения — пауза.
        XCTAssertEqual(run(&gate, Array(repeating: off, count: 10), from: Double(ticks)), [])
        // Неудача удваивает паузу: через обычные 20 с — рано, через 40+ — можно.
        gate.noteFailure()
        let base = AppConfig.rerouteCooldownSeconds
        XCTAssertEqual(run(&gate, Array(repeating: off, count: ticks), from: base + 5), [])
        XCTAssertFalse(run(&gate, Array(repeating: off, count: ticks), from: 2 * base + 10).isEmpty)
        gate.noteSuccess()
        XCTAssertEqual(gate.failures, 0)
    }

    // MARK: - Устойчивый съезд (снимок CarPlay 21.10, 08:28)

    private func runDrift(_ gate: inout RerouteGate, _ deviations: [Double]) -> [Int] {
        deviations.enumerated().compactMap { index, deviation in
            gate.note(deviation: deviation, now: t0.addingTimeInterval(Double(index)),
                      drift: AppConfig.rerouteDriftMeters) ? index : nil
        }
    }

    /// Свернул мимо: отклонения из прогона в симуляторе (поворот направо
    /// вместо прямо, 31 км/ч). Проекция цепляется за попутный кусок маршрута
    /// впереди, и отклонение пляшет вокруг 150 м — три фикса подряд за ним
    /// не набирались, перестроение ждало 15 с. Устойчивые 50+ м — съезд.
    func testTurnOffWithDancingDeviationRebuildsEarly() {
        let recorded: [Double] = [0, 8, 12, 55, 56, 82, 122, 126, 72, 155, 133, 106, 96, 118, 152, 214, 167]
        var old = RerouteGate()
        XCTAssertEqual(run(&old, recorded), [16], "без правила — только на шестнадцатом фиксе")
        var gate = RerouteGate()
        XCTAssertEqual(runDrift(&gate, recorded), [6],
                       "четвёртый фикс подряд дальше \(AppConfig.rerouteDriftMeters) м")
    }

    /// Дублёр проспекта (15–40 м от оси) и шум — не съезд, сколько ни едь.
    func testServiceRoadAndNoiseDoNotRebuild() {
        var gate = RerouteGate()
        XCTAssertEqual(runDrift(&gate, Array(repeating: 40, count: 60)), [])
        var noisy = RerouteGate()
        let spikes = (0..<40).map { $0 % AppConfig.rerouteDriftTicks == 0 ? 10.0 : 90.0 }
        XCTAssertEqual(runDrift(&noisy, spikes), [], "выброс короче \(AppConfig.rerouteDriftTicks) фиксов")
        XCTAssertEqual(noisy.driftTicks, AppConfig.rerouteDriftTicks - 1)
    }

    /// Устойчивый съезд подчиняется той же паузе после перестроения.
    func testDriftRespectsTheCooldown() {
        var gate = RerouteGate()
        let ticks = AppConfig.rerouteDriftTicks
        XCTAssertEqual(runDrift(&gate, Array(repeating: 80, count: ticks)), [ticks - 1])
        let after = (0..<10).compactMap { index -> Int? in
            gate.note(deviation: 80, now: t0.addingTimeInterval(Double(ticks + index)),
                      drift: AppConfig.rerouteDriftMeters) ? index : nil
        }
        XCTAssertEqual(after, [], "в паузе \(AppConfig.rerouteCooldownSeconds) с — не перестраиваем")
        gate.resetTicks()
        XCTAssertEqual(gate.driftTicks, 0)
    }

    /// Порог устойчивого съезда растёт с погрешностью: на фиксах 60 м между
    /// домами снос 55 м при верном курсе — не съезд. Хороший фикс — прежние 50 м.
    func testDriftLimitGrowsWithFixAccuracy() {
        XCTAssertEqual(RerouteGate.driftLimit(accuracy: 5), AppConfig.rerouteDriftMeters)
        XCTAssertEqual(RerouteGate.driftLimit(accuracy: 10), AppConfig.rerouteDriftMeters)
        XCTAssertEqual(RerouteGate.driftLimit(accuracy: 60),
                       AppConfig.rerouteDriftMeters + RoadCorridor.accuracyAllowance(60))
        XCTAssertGreaterThan(RerouteGate.driftLimit(accuracy: -1), RerouteGate.driftLimit(accuracy: 60) - 0.001,
                             "неизвестная точность — как худшая принятая")
        XCTAssertEqual(RerouteGate.driftLimit(accuracy: nil), AppConfig.rerouteDriftMeters)

        // Снос 70 м четыре фикса подряд на фиксах 60 м — не перестроение.
        var gate = RerouteGate()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let drift = RerouteGate.driftLimit(accuracy: 60)
        for tick in 0..<6 {
            XCTAssertFalse(gate.note(deviation: 70, now: now.addingTimeInterval(Double(tick)), drift: drift))
        }
    }

    // MARK: - Ход навстречу линии (20.9)

    /// Фиксы на линии (отклонение 12 м — ни 150, ни 50 не набираются) с
    /// ходом по ней: `along` — прогресс, `against` — навстречу ли.
    private func runHeading(_ gate: inout RerouteGate, _ fixes: [(along: Double, against: Bool)],
                            from start: TimeInterval = 0) -> [Int] {
        fixes.enumerated().compactMap { index, fix in
            gate.note(deviation: 12, now: t0.addingTimeInterval(start + Double(index)),
                      drift: AppConfig.rerouteDriftMeters,
                      heading: RerouteGate.Heading(along: fix.along, against: fix.against)) ? index : nil
        }
    }

    /// Развернулись на той же улице: до линии 12 м, отклонение не скажет
    /// ничего никогда — а маршрут вёл назад до самой цели. Четыре фикса
    /// навстречу и 30+ м назад по линии — перестроение.
    func testDrivingBackAlongTheLineRebuilds() {
        let forward = (0..<10).map { (along: 500 + Double($0) * 12, against: false) }
        let back = (0..<8).map { (along: 608 - Double($0) * 12, against: true) }
        var old = RerouteGate()
        XCTAssertEqual(run(&old, Array(repeating: 12, count: 18)), [], "по отклонению — никогда")
        var gate = RerouteGate()
        XCTAssertEqual(runHeading(&gate, forward + back), [10 + AppConfig.rerouteWrongWayTicks - 1],
                       "четвёртый фикс навстречу, прогресс отступил на 36 м")
        XCTAssertEqual(gate.wrongWayTicks, back.count - AppConfig.rerouteWrongWayTicks, "серия с нуля")
    }

    /// Курс навстречу, а прогресс не отступает (застыл на конце окна
    /// проекции, выброс курса) — не перестраиваем: нужен и курс, и ход.
    func testAgainstWithoutRetreatDoesNotRebuild() {
        var gate = RerouteGate()
        let stuck = (0..<12).map { (along: 800 + Double($0 % 2) * 5, against: true) }
        XCTAssertEqual(runHeading(&gate, stuck), [])
        XCTAssertFalse(gate.isWrongWay)
        XCTAssertEqual(gate.wrongWayTicks, 12)
    }

    /// Один попутный фикс посреди серии — счёт с нуля, как у сноса.
    func testAgreeingFixRestartsTheCount() {
        var gate = RerouteGate()
        let fixes: [(along: Double, against: Bool)] = [
            (900, true), (888, true), (876, true), (870, false),
            (858, true), (846, true), (834, true),
        ]
        XCTAssertEqual(runHeading(&gate, fixes), [])
        XCTAssertEqual(gate.wrongWayTicks, 3)
    }

    /// «Навстречу» — только на ходу и с курсом: стоя у светофора с
    /// выдержанным курсом, без курса или без ветки — нет.
    func testAgainstNeedsATrustedCourseOnTheMove() {
        let moving = AppConfig.directionalMinSpeedKmh + 20
        XCTAssertTrue(RerouteGate.isAgainst(course: 270, speedKmh: moving, routeCourse: 90))
        XCTAssertTrue(RerouteGate.isAgainst(course: 200, speedKmh: moving, routeCourse: 10), "через север: 170°")
        XCTAssertTrue(RerouteGate.isAgainst(course: 90, speedKmh: AppConfig.directionalMinSpeedKmh,
                                            routeCourse: 269))
        XCTAssertFalse(RerouteGate.isAgainst(course: 270, speedKmh: AppConfig.directionalMinSpeedKmh - 1,
                                             routeCourse: 90), "ползём или стоим — курсу на месте не верим")
        XCTAssertFalse(RerouteGate.isAgainst(course: 270, speedKmh: 0, routeCourse: 90))
        XCTAssertFalse(RerouteGate.isAgainst(course: -1, speedKmh: moving, routeCourse: 90), "курса нет")
        XCTAssertFalse(RerouteGate.isAgainst(course: .nan, speedKmh: moving, routeCourse: 90))
        XCTAssertFalse(RerouteGate.isAgainst(course: 270, speedKmh: moving, routeCourse: nil), "ветки нет")
        XCTAssertFalse(RerouteGate.isAgainst(course: 180, speedKmh: moving, routeCourse: 90),
                       "поворот под прямым углом — не разворот")
        XCTAssertFalse(RerouteGate.isAgainst(course: 90 + AppConfig.rerouteWrongWayDegrees, speedKmh: moving,
                                             routeCourse: 90), "порог — строго больше")
    }

    /// Шум приёмника на месте: прогресс пляшет ±15 м, курс выдержан
    /// навстречу, но скорость ноль — `against` не наступает, и ничего.
    func testStandingNoiseNeverRebuilds() {
        var gate = RerouteGate()
        let noise = (0..<60).map { tick -> (along: Double, against: Bool) in
            let along = 700 + Double([0, -15, 9, -12, 15, -6][tick % 6])
            return (along, RerouteGate.isAgainst(course: 270, speedKmh: Double(tick % 4), routeCourse: 90))
        }
        XCTAssertEqual(runHeading(&gate, noise), [])
        XCTAssertEqual(gate.wrongWayTicks, 0)
    }

    /// Ход навстречу подчиняется той же паузе и тому же бэкоффу; в паузе
    /// он снова подтверждается — и остатку «по маршруту» не верят (isWrongWay).
    func testWrongWayRespectsTheCooldownAndBackoff() {
        let ticks = AppConfig.rerouteWrongWayTicks
        let back = (0..<40).map { (along: 2000 - Double($0) * 12, against: true) }
        var gate = RerouteGate()
        XCTAssertEqual(runHeading(&gate, Array(back.prefix(ticks))), [ticks - 1])
        XCTAssertFalse(gate.isWrongWay, "перестроение сбросило серию")
        let base = AppConfig.rerouteCooldownSeconds
        XCTAssertEqual(runHeading(&gate, Array(back[ticks..<(ticks + 10)]), from: Double(ticks)), [],
                       "в паузе \(base) с — не перестраиваем")
        XCTAssertTrue(gate.isWrongWay, "но навстречу едем по-прежнему")
        gate.noteFailure()
        gate.resetTicks()
        XCTAssertFalse(gate.isWrongWay)
        XCTAssertEqual(runHeading(&gate, Array(back[14..<(14 + ticks)]), from: base + 5), [],
                       "неудача удвоила паузу")
        gate.resetTicks()
        XCTAssertEqual(runHeading(&gate, Array(back[20..<(20 + ticks)]), from: 2 * base + 10), [ticks - 1])
    }

    /// Маршрут без сети правила не имеет: `heading` nil — серия не копится.
    func testNoHeadingMeansNoWrongWayRule() {
        var gate = RerouteGate()
        for tick in 0..<10 {
            XCTAssertFalse(gate.note(deviation: 12, now: t0.addingTimeInterval(Double(tick)),
                                     limit: AppConfig.offlineRouteRerouteMeters, heading: nil))
        }
        XCTAssertEqual(gate.wrongWayTicks, 0)
    }
}
