//
//  ManeuverTests.swift
//  RadarMapTests
//
//  Манёвр как данные: тип поворота и полосы.
//
//  Тесты здесь стерегут не столько разбор, сколько ЗАПРЕТЫ. Полосы приходят
//  от чужого сервера, рисуются водителю за рулём и читаются им как указание —
//  поэтому неполный ряд обязан исчезать целиком, а не дорисовываться до
//  правдоподобного.
//

import XCTest
@testable import RadarMap

final class ManeuverTests: XCTestCase {

    private func step(_ type: String, _ modifier: String?, name: String = "",
                      exit: Int? = nil,
                      lanes: [RouteService.OSRMResponse.Lane]? = nil) -> RouteStep? {
        let intersections = lanes.map {
            [RouteService.OSRMResponse.Intersection(lanes: $0)]
        }
        return RouteService.maneuverStep(
            RouteService.OSRMResponse.Step(
                distance: 100, name: name,
                maneuver: RouteService.OSRMResponse.Maneuver(
                    type: type, modifier: modifier, exit: exit),
                intersections: intersections),
            at: 500, language: "ru")
    }

    private func lane(_ indications: [String], valid: Bool)
        -> RouteService.OSRMResponse.Lane {
        RouteService.OSRMResponse.Lane(valid: valid, indications: indications)
    }

    // MARK: - Тип манёвра

    func testKindFollowsModifierNotPhrase() {
        XCTAssertEqual(step("turn", "right")?.kind, .right)
        XCTAssertEqual(step("turn", "sharp left")?.kind, .sharpLeft)
        XCTAssertEqual(step("turn", "uturn")?.kind, .uturn)
        // Развилка и перекрёсток говорят разными фразами, но геометрия
        // поворота у них одна — тип обязан это отражать.
        XCTAssertEqual(step("fork", "slight right")?.kind, .slightRight)
        XCTAssertEqual(step("roundabout", nil, exit: 2)?.kind, .roundabout)
        XCTAssertEqual(step("arrive", nil)?.kind, .arrive)
    }

    func testUnknownModifierIsStraightNotCrash() {
        // Чужой сервер вправе прислать то, чего мы не знаем; маршрут от этого
        // ломаться не должен.
        XCTAssertEqual(ManeuverKind.fromOSRM(modifier: "sideways"), .straight)
        XCTAssertEqual(ManeuverKind.fromOSRM(modifier: nil), .straight)
    }

    func testArriveIsNotDrawnAsTurn() {
        XCTAssertFalse(ManeuverKind.arrive.isDrawable)
        XCTAssertTrue(ManeuverKind.right.isDrawable)
    }

    // MARK: - Полосы

    func testLanesParsedFromFirstIntersection() {
        let parsed = step("turn", "right", lanes: [
            lane(["straight"], valid: false),
            lane(["straight", "right"], valid: true),
        ])
        XCTAssertEqual(parsed?.lanes.count, 2)
        XCTAssertEqual(parsed?.lanes.first?.isValid, false)
        XCTAssertEqual(parsed?.lanes.last?.arrows, [.straight, .right])
    }

    func testNoLanesWhenServerSentNone() {
        XCTAssertEqual(step("turn", "right")?.lanes, [])
    }

    func testIncompleteRowIsDroppedWhole() {
        // Полоса без единой понятной стрелки выпала бы из ряда, и водитель
        // увидел бы три полосы там, где их четыре. Считать полосы глазами он
        // будет по дороге, а не по нашему рендеру — поэтому либо весь ряд,
        // либо ничего.
        let parsed = step("turn", "right", lanes: [
            lane(["straight"], valid: false),
            lane(["летим"], valid: true),
            lane(["right"], valid: true),
        ])
        XCTAssertEqual(parsed?.lanes, [], "неполный ряд полос обязан исчезать целиком")
    }

    func testLaneWithoutValidFlagIsNotOurs() {
        // Отсутствие `valid` — это «сервер не сказал», а не «подходит».
        // Подсветить полосу без подтверждения значит послать водителя в неё.
        let parsed = step("turn", "right", lanes: [
            RouteService.OSRMResponse.Lane(valid: nil, indications: ["right"]),
        ])
        XCTAssertEqual(parsed?.lanes.first?.isValid, false)
    }

    func testNoneIndicationReadsAsStraight() {
        // `none` — полоса без разметки. Пустая клетка в ряду выглядела бы
        // поломкой рендера.
        let parsed = step("turn", "right", lanes: [lane(["none"], valid: false)])
        XCTAssertEqual(parsed?.lanes.first?.arrows, [.straight])
    }

    // MARK: - Какая стрелка показывается на полосе

    func testPrimaryArrowPrefersOurSide() {
        // «Прямо и направо» на подходящей полосе при повороте направо обязано
        // показать направо: со стрелкой «прямо» водитель поедет прямо.
        let lane = LaneHint(arrows: [.straight, .right], isValid: true)
        XCTAssertEqual(lane.primaryArrow(for: .right), .right)
    }

    func testPrimaryArrowOfForeignLaneStaysAsIs() {
        // Чужая полоса показывает то, что на ней нарисовано, а не то, куда
        // едем мы: она объясняет, почему в неё НЕ надо.
        let lane = LaneHint(arrows: [.straight, .right], isValid: false)
        XCTAssertEqual(lane.primaryArrow(for: .right), .straight)
    }

    func testPrimaryArrowWithoutKindTakesFirst() {
        let lane = LaneHint(arrows: [.slightLeft, .straight], isValid: true)
        XCTAssertEqual(lane.primaryArrow(for: nil), .slightLeft)
    }

    // MARK: - Остановка по пути

    /// Прибытие на промежуточной точке — «заезд», а не «вы прибыли»: иначе
    /// голос у заправки объявлял бы конец маршрута, и водитель решал бы, что
    /// цель потерялась.
    func testStopArrivalIsNotFinalArrival() {
        let arrive = RouteService.OSRMResponse.Step(
            distance: 0, name: "",
            maneuver: RouteService.OSRMResponse.Maneuver(type: "arrive", modifier: nil, exit: nil))
        let final = RouteService.maneuverStep(arrive, at: 900, language: "ru")
        let stop = RouteService.maneuverStep(arrive, at: 900, language: "ru", stopName: "АЗС")
        XCTAssertEqual(final?.icon, "flag.checkered")
        XCTAssertEqual(stop?.icon, "mappin.circle.fill")
        XCTAssertTrue(stop?.text.contains("АЗС") == true)
        XCTAssertNotEqual(stop?.text, final?.text)
    }

    // MARK: - Ступени голоса манёвра

    /// Далеко — только манёврам, которым нужна ранняя фраза; ступень — одна.
    func testVoiceStageFar() {
        XCTAssertNil(RouteService.voiceStage(distance: 900, spoken: 3, earlyCall: true))
        XCTAssertEqual(RouteService.voiceStage(distance: 800, spoken: 3, earlyCall: true), 2)
        XCTAssertNil(RouteService.voiceStage(distance: 800, spoken: 3, earlyCall: false))
        XCTAssertNil(RouteService.voiceStage(distance: 800, spoken: 2, earlyCall: true),
                     "дальняя фраза уже сказана — повторять нечего")
    }

    func testVoiceStageNearAndNow() {
        XCTAssertEqual(RouteService.voiceStage(distance: 200, spoken: 2, earlyCall: true), 1)
        XCTAssertNil(RouteService.voiceStage(distance: 200, spoken: 1, earlyCall: true))
        XCTAssertEqual(RouteService.voiceStage(distance: 30, spoken: 1, earlyCall: true), 0)
        XCTAssertNil(RouteService.voiceStage(distance: 30, spoken: 0, earlyCall: true))
    }

    /// Въехали в маршрут уже у поворота: сразу «сейчас», пропущенные дальние
    /// ступени не догоняем.
    func testVoiceStageSkipsMissedEarlierStages() {
        XCTAssertEqual(RouteService.voiceStage(distance: 30, spoken: 3, earlyCall: true), 0)
        XCTAssertEqual(RouteService.voiceStage(distance: 200, spoken: 3, earlyCall: false), 1)
    }

    // MARK: - Короткая фраза для машины (11.10)

    /// Узкая карточка машины берёт первый влезающий вариант: без короткой
    /// фразы без улицы она оставалась пустой.
    func testShortTextDropsTheStreet() {
        let withStreet = step("turn", "left", name: "Amir Temur shoh ko'chasi")
        XCTAssertNotNil(withStreet?.shortText)
        XCTAssertTrue(withStreet?.text.hasPrefix(withStreet?.shortText ?? "#") == true)
        XCTAssertLessThan(withStreet?.shortText?.count ?? 0, withStreet?.text.count ?? 0)
        XCTAssertNil(step("turn", "left")?.shortText, "улицы нет — короткая фраза не нужна")
    }
}
