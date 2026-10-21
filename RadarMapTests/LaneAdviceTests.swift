//
//  LaneAdviceTests.swift
//  RadarMapTests
//
//  Ряд полос словами: говорим только однозначное. Край без полос OSRM —
//  по ПДД и полосам своей дороги, один раз на манёвр и после камеры (20.2).
//

import CoreLocation
import XCTest
@testable import RadarMap

final class LaneAdviceTests: XCTestCase {

    private func row(_ pattern: String) -> [LaneHint] {
        pattern.map { LaneHint(arrows: [.straight], isValid: $0 == "+") }
    }

    func testRunsFromTheLeftEdge() {
        XCTAssertEqual(LaneAdvice.phrase(row("+---")), String(localized: "Из левого ряда"))
        XCTAssertEqual(LaneAdvice.phrase(row("++--")), String(localized: "Из двух левых рядов"))
        XCTAssertEqual(LaneAdvice.phrase(row("+++--")), String(localized: "Из трёх левых рядов"))
        XCTAssertEqual(LaneAdvice.phrase(row("++++---")), String(localized: "Из левых рядов"))
    }

    func testRunsFromTheRightEdge() {
        XCTAssertEqual(LaneAdvice.phrase(row("---+")), String(localized: "Из правого ряда"))
        XCTAssertEqual(LaneAdvice.phrase(row("--++")), String(localized: "Из двух правых рядов"))
    }

    func testAllButOneEdgeSaysWhichToAvoid() {
        XCTAssertEqual(LaneAdvice.phrase(row("+++-")), String(localized: "Из любого ряда, кроме правого"))
        XCTAssertEqual(LaneAdvice.phrase(row("-+++")), String(localized: "Из любого ряда, кроме левого"))
        XCTAssertEqual(LaneAdvice.phrase(row("+-")), String(localized: "Из левого ряда"),
                       "из двух полос «кроме правого» — это просто левый")
    }

    func testMiddle() {
        XCTAssertEqual(LaneAdvice.phrase(row("-+-")), String(localized: "Из среднего ряда"))
        XCTAssertEqual(LaneAdvice.phrase(row("-++--")), String(localized: "Из средних рядов"))
    }

    func testNothingToSay() {
        XCTAssertNil(LaneAdvice.phrase(row("++++")), "подходят все — подсказка пустая")
        XCTAssertNil(LaneAdvice.phrase(row("----")))
        XCTAssertNil(LaneAdvice.phrase(row("+-+-")), "разрозненные — только стрелки")
        XCTAssertNil(LaneAdvice.phrase(row("+")))
        XCTAssertNil(LaneAdvice.phrase([]))
    }

    func testHighwayShowsTheRowEarlier() {
        XCTAssertEqual(LaneAdvice.showDistance(speedKmh: 40), AppConfig.engineManeuverApproachMeters)
        XCTAssertEqual(LaneAdvice.showDistance(speedKmh: 90), AppConfig.laneRowHighwayMeters)
        XCTAssertGreaterThan(AppConfig.laneRowHighwayMeters, AppConfig.engineManeuverApproachMeters)
    }
}

final class LaneVoiceTests: XCTestCase {
    func testEarlyCallSaysWhichRowsWhenItIsClear() {
        let lanes = [LaneHint(arrows: [.left], isValid: true), LaneHint(arrows: [.straight], isValid: false)]
        let advice = LaneAdvice.advice(lanes: lanes, edge: .left, lanesPerDirection: 3)
        XCTAssertEqual(RouteService.withAdvice("Через 300 метров — поверните налево", advice),
                       "Через 300 метров — поверните налево. " + String(localized: "Из левого ряда"))
    }

    func testNoLanesNoExtraWords() {
        XCTAssertEqual(RouteService.withAdvice("Через 300 метров — поверните налево", nil),
                       "Через 300 метров — поверните налево")
    }

    /// Владелец, 21.10: «налево — нужно перестроиться налево, с левого края».
    func testEdgeWithoutLanesIsSaidAsAnInstruction() {
        XCTAssertEqual(RouteService.withAdvice("Через 350 метров — поверните налево", .edge(.left)),
                       "Через 350 метров — поверните налево. " + String(localized: "Перестройтесь в левый ряд"))
        XCTAssertEqual(LaneAdvice.spoken(.edge(.farLeft)), String(localized: "Перестройтесь в крайний левый ряд"))
        XCTAssertEqual(LaneAdvice.spoken(.edge(.right)), String(localized: "Перестройтесь в правый ряд"))
        XCTAssertEqual(LaneAdvice.spoken(.edge(.keepRight)), String(localized: "Держитесь правее"))
    }
}

/// Край без полос OSRM (20.2): тип поворота + полосы своей дороги.
final class LaneEdgeTests: XCTestCase {

    private func row(_ pattern: String) -> [LaneHint] {
        pattern.map { LaneHint(arrows: [.straight], isValid: $0 == "+") }
    }

    func testTurnsGetTheEdgeTheRulesRequire() {
        // ПДД: налево и разворот — из крайнего левого, направо — из крайнего правого.
        XCTAssertEqual(LaneAdvice.edge(osrmType: "turn", modifier: "left"), .left)
        XCTAssertEqual(LaneAdvice.edge(osrmType: "turn", modifier: "sharp left"), .left)
        XCTAssertEqual(LaneAdvice.edge(osrmType: "end of road", modifier: "left"), .left)
        XCTAssertEqual(LaneAdvice.edge(osrmType: "turn", modifier: "right"), .right)
        XCTAssertEqual(LaneAdvice.edge(osrmType: "end of road", modifier: "sharp right"), .right)
    }

    func testUTurnIsTheFarLeftLane() {
        XCTAssertEqual(LaneAdvice.edge(osrmType: "turn", modifier: "uturn"), .farLeft)
        XCTAssertEqual(LaneAdvice.edge(osrmType: "continue", modifier: "uturn"), .farLeft)
        XCTAssertNil(LaneAdvice.edge(osrmType: "continue", modifier: "left"),
                     "continue — «едем по своей дороге», а не поворот")
    }

    /// Развилка и плавный поворот уже говорят сторону самой командой
    /// («держитесь левее») — второй раз то же слово не нужно; съезд стороны
    /// не называет и край получает.
    func testForkSaysTheSideItselfButAnExitNeedsIt() {
        XCTAssertNil(LaneAdvice.edge(osrmType: "fork", modifier: "slight left"))
        XCTAssertNil(LaneAdvice.edge(osrmType: "fork", modifier: "right"))
        XCTAssertNil(LaneAdvice.edge(osrmType: "turn", modifier: "slight left"))
        XCTAssertEqual(LaneAdvice.edge(osrmType: "off ramp", modifier: "slight right"), .keepRight)
        XCTAssertEqual(LaneAdvice.edge(osrmType: "off ramp", modifier: "left"), .keepLeft)
        XCTAssertNil(LaneAdvice.edge(osrmType: "roundabout", modifier: "right"))
        XCTAssertNil(LaneAdvice.edge(osrmType: "merge", modifier: "slight left"))
        XCTAssertNil(LaneAdvice.edge(osrmType: "turn", modifier: "straight"))
    }

    func testOSRMLanesWinOverTheEdge() {
        XCTAssertEqual(LaneAdvice.advice(lanes: row("+--"), edge: .right, lanesPerDirection: 3),
                       .lanes(.leftOne), "полосы OSRM точнее догадки")
        XCTAssertNil(LaneAdvice.advice(lanes: row("+++"), edge: .left, lanesPerDirection: 3),
                     "подходят все полосы — «перестройтесь» было бы неправдой")
        XCTAssertNil(LaneAdvice.advice(lanes: row("+-+"), edge: .left, lanesPerDirection: 3),
                     "разрозненные — только ряд стрелок")
    }

    func testEdgeNeedsSomewhereToMove() {
        XCTAssertEqual(LaneAdvice.advice(lanes: [], edge: .left, lanesPerDirection: 2), .edge(.left))
        XCTAssertEqual(LaneAdvice.advice(lanes: [], edge: .farLeft, lanesPerDirection: 3), .edge(.farLeft))
        XCTAssertNil(LaneAdvice.advice(lanes: [], edge: .left, lanesPerDirection: 1),
                     "одна полоса — ряд не выбирают")
        XCTAssertNil(LaneAdvice.advice(lanes: [], edge: .left, lanesPerDirection: nil),
                     "о дороге ничего не знаем — молчим")
        XCTAssertNil(LaneAdvice.advice(lanes: [], edge: nil, lanesPerDirection: 3))
    }

    func testCardTextCarriesTheEdgeOnly() {
        XCTAssertEqual(LaneAdvice.instruction("Поверните налево на улицу Лабзак", advice: .edge(.left)),
                       "Поверните налево на улицу Лабзак, " + String(localized: "левый ряд"))
        XCTAssertEqual(LaneAdvice.instruction("Поверните налево", advice: .lanes(.leftTwo)), "Поверните налево",
                       "полосы OSRM показывает ряд стрелок, текст их не повторяет")
        XCTAssertEqual(LaneAdvice.instruction("Поверните налево", advice: nil), "Поверните налево")
    }

    func testStepCarriesItsAdvice() {
        var step = RouteStep(distanceAlong: 500, text: "поверните налево", icon: "arrow.turn.up.left",
                             kind: .left, edge: .left)
        XCTAssertNil(step.laneAdvice, "полос подъезда ещё не знаем")
        step.approachLanes = 3
        XCTAssertEqual(step.laneAdvice, .edge(.left))
        XCTAssertEqual(step.laneEdge, .left)
        step = RouteStep(distanceAlong: 500, text: "поверните налево на улицу Лабзак", icon: "arrow.turn.up.left",
                         kind: .left, shortText: "поверните налево", edge: .left, approachLanes: 2)
        XCTAssertEqual(step.compactInstruction, "поверните налево, " + String(localized: "левый ряд"),
                       "в одну строку улица уступает краю")
    }

    // MARK: - Полосы своей дороги на подъезде

    private let origin = CLLocationCoordinate2D(latitude: 41.3000, longitude: 69.2500)

    /// Отрезок на север через `origin`, ±150 м.
    private func northSouth(_ kind: RoadClass, oneWay: Bool = false, lanes: Int = 0,
                            detailed: Bool = true, dLon: Double = 0) -> RoadLine {
        RoadLine(points: [CLLocationCoordinate2D(latitude: 41.2987, longitude: 69.2500 + dLon),
                          CLLocationCoordinate2D(latitude: 41.3013, longitude: 69.2500 + dLon)],
                 kind: kind, isOneWay: oneWay, isDetailed: detailed, lanes: lanes)
    }

    private func eastWest(_ kind: RoadClass) -> RoadLine {
        RoadLine(points: [CLLocationCoordinate2D(latitude: 41.3000, longitude: 69.2480),
                          CLLocationCoordinate2D(latitude: 41.3000, longitude: 69.2520)],
                 kind: kind, isDetailed: true)
    }

    func testApproachLanesComeFromTheRoadAlongTheCourse() {
        // Проспект без тега: дефолт класса 6 полос на обе стороны → 3 в нашу.
        XCTAssertEqual(LaneAdvice.approachLanes(at: origin, course: 0, roads: [northSouth(.primary)]), 3)
        // Встречный курс — та же дорога, ось в сети не обязана смотреть по ходу.
        XCTAssertEqual(LaneAdvice.approachLanes(at: origin, course: 180, roads: [northSouth(.primary)]), 3)
        // Тег lanes на односторонней ленте — все её полосы наши.
        XCTAssertEqual(LaneAdvice.approachLanes(at: origin, course: 0,
                                                roads: [northSouth(.secondary, oneWay: true, lanes: 4)]), 4)
        // Жилая улица: две полосы на обе стороны — одна в нашу.
        XCTAssertEqual(LaneAdvice.approachLanes(at: origin, course: 0, roads: [northSouth(.residential)]), 1)
    }

    func testCrossStreetOfTheJunctionDoesNotCount() {
        // Подъезд с юга; поперечный проспект перекрёстка ближе, но поперёк курса.
        let roads = [eastWest(.primary), northSouth(.residential, dLon: 0.0001)]
        XCTAssertEqual(LaneAdvice.approachLanes(at: origin, course: 0, roads: roads), 1)
        XCTAssertNil(LaneAdvice.approachLanes(at: origin, course: 0, roads: [eastWest(.primary)]))
    }

    func testUnknowingSourceGivesNoLanes() {
        // Линия индекса лимитов: ни класса, ни тега — её «две полосы» дефолт незнания.
        XCTAssertNil(LaneAdvice.approachLanes(at: origin, course: 0,
                                              roads: [northSouth(.unknown, detailed: false)]))
        XCTAssertNil(LaneAdvice.approachLanes(at: origin, course: 0, roads: [northSouth(.primary, dLon: 0.001)]),
                     "дорога в 80 м сбоку — не наша")
        XCTAssertNil(LaneAdvice.approachLanes(at: origin, course: 0, roads: []))
    }

    // MARK: - Когда сказать

    func testAdviceDistanceFollowsSpeed() {
        XCTAssertEqual(LaneAdvice.adviceDistance(speedKmh: 0), 300)
        XCTAssertEqual(LaneAdvice.adviceDistance(speedKmh: 40), 300, "в городе — не ближе 300 м")
        XCTAssertEqual(LaneAdvice.adviceDistance(speedKmh: 60), 60 / 3.6 * 20, accuracy: 0.01)
        XCTAssertEqual(LaneAdvice.adviceDistance(speedKmh: 70), 600, "трасса — не ближе 600 м")
        XCTAssertEqual(LaneAdvice.adviceDistance(speedKmh: 120), 1000, accuracy: 0.01)
        XCTAssertGreaterThan(LaneAdvice.adviceDistance(speedKmh: 60), AppConfig.maneuverNearCallMeters,
                             "ближняя фраза в 280 м на 60 км/ч — поздно для ряда")
    }

    func testTownMovesTheNearCallToTheWindow() {
        let calls = LaneAdvice.calls(earlyCall: true, hasAdvice: true, speedKmh: 60, cameraHolds: false)
        XCTAssertEqual(calls.near, 60 / 3.6 * 20, accuracy: 0.01)
        XCTAssertEqual(calls.far, AppConfig.maneuverFarCallMeters, "дальняя фраза — как была")
        XCTAssertFalse(calls.adviceOnFar, "за 850 м в городе ряд рано: по пути есть свои перекрёстки")
        XCTAssertEqual(LaneAdvice.calls(earlyCall: true, hasAdvice: false, speedKmh: 60, cameraHolds: false),
                       .standard(earlyCall: true), "без совета ступени прежние")
    }

    func testHighwaySaysTheRowInTheFarCall() {
        let turn = LaneAdvice.calls(earlyCall: true, hasAdvice: true, speedKmh: 100, cameraHolds: false)
        XCTAssertTrue(turn.adviceOnFar)
        XCTAssertEqual(turn.near, AppConfig.maneuverNearCallMeters)
        // Съезду дальняя фраза не положена — она появляется на краю окна.
        let exit = LaneAdvice.calls(earlyCall: false, hasAdvice: true, speedKmh: 100, cameraHolds: false)
        XCTAssertEqual(exit.far ?? 0, 100 / 3.6 * 30, accuracy: 0.01)
        XCTAssertTrue(exit.adviceOnFar)
        XCTAssertEqual(exit.near, AppConfig.maneuverNearCallMeters, "ближняя — напоминание, как была")
    }

    /// Прогон подъезда: какие ступени прозвучали и в какой из них ряд.
    private func drive(earlyCall: Bool, speedKmh: Double, from start: Double = 1200,
                       cameraHolds: (Double) -> Bool = { _ in false }) -> [(stage: Int, at: Double, advice: Bool)] {
        var spoken = 3
        var said = false
        var out: [(Int, Double, Bool)] = []
        for distance in stride(from: start, through: 0, by: -5.0) {
            let calls = LaneAdvice.calls(earlyCall: earlyCall, hasAdvice: true, speedKmh: speedKmh,
                                         cameraHolds: cameraHolds(distance))
            guard let stage = RouteService.voiceStage(distance: distance, spoken: spoken, calls: calls) else { continue }
            spoken = stage
            let attach = LaneAdvice.attaches(stage: stage, calls: calls, alreadySaid: said)
            if attach { said = true }
            out.append((stage, distance, attach))
        }
        return out
    }

    func testRowIsSaidOncePerManeuver() {
        for (early, speed) in [(true, 40.0), (true, 60.0), (true, 100.0), (false, 60.0), (false, 110.0)] {
            let calls = drive(earlyCall: early, speedKmh: speed)
            XCTAssertEqual(calls.filter(\.advice).count, 1, "ровно один раз: \(early) \(speed)")
            XCTAssertFalse(calls.contains { $0.stage == 0 && $0.advice }, "в самой команде — поздно")
            let at = calls.first(where: \.advice)?.at ?? 0
            XCTAssertGreaterThanOrEqual(at, min(LaneAdvice.adviceDistance(speedKmh: speed),
                                                AppConfig.maneuverFarCallMeters) - 5,
                                        "ряд — не позже окна: \(early) \(speed)")
        }
    }

    func testTownRowRidesOnTheMovedNearCallNotAnExtraPhrase() {
        let calls = drive(earlyCall: true, speedKmh: 60)
        XCTAssertEqual(calls.map(\.stage), [2, 1, 0], "три фразы, как без совета: дальняя, ближняя, команда")
        XCTAssertEqual(calls[1].at, 330, accuracy: 5, "ближняя переехала к окну 333 м")
        XCTAssertTrue(calls[1].advice)
    }

    func testCameraFirstTheRowWaitsForTheRegularNearCall() {
        // Камера держит голос до 200 м: ранняя ближняя не звучит, ряд едет на
        // обычной ближней (280 м), а не встаёт в очередь перед фразой о камере.
        let calls = drive(earlyCall: true, speedKmh: 60, cameraHolds: { $0 > 200 })
        let near = calls.first { $0.stage == 1 }
        XCTAssertLessThan(near?.at ?? 999, AppConfig.maneuverNearCallMeters)
        XCTAssertEqual(near?.advice, true)
        // Трасса: дальняя на краю окна для съезда — тоже добавленная, ждёт.
        let exit = drive(earlyCall: false, speedKmh: 100, cameraHolds: { _ in true })
        XCTAssertEqual(exit.map(\.stage), [1, 0])
        XCTAssertEqual(exit.first?.advice, true)
    }

    func testEnteringLateSkipsTheRowAtTheTurnItself() {
        let calls = drive(earlyCall: true, speedKmh: 30, from: 40)
        XCTAssertEqual(calls.map(\.stage), [0])
        XCTAssertFalse(calls[0].advice)
    }

    func testSpokenMetersMatchRecordedSteps() {
        XCTAssertEqual(RouteService.spokenMeters(333, far: false), 350)
        XCTAssertEqual(RouteService.spokenMeters(428, far: false), 400, "«450» записи нет — до 100 м")
        XCTAssertEqual(RouteService.spokenMeters(262, far: false), 250)
        XCTAssertEqual(RouteService.spokenMeters(833, far: true), 800)
        for meters in [300.0, 333, 389, 410, 430] {
            XCTAssertNotNil(VoiceDistance.segment(meters: RouteService.spokenMeters(meters, far: false), form: .after))
        }
    }
}
