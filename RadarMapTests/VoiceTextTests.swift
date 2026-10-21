//
//  VoiceTextTests.swift
//  RadarMapTests
//
//  Записанный голос говорит, только если событие рендерится в ТОТ ЖЕ текст,
//  что построил код рядом (RecordedVoice.plan). Здесь обе стороны сведены:
//  настоящие построители фраз против рендера их событий. Разошлись — запись
//  для этой фразы молча выключилась бы; тест ловит это раньше дороги.
//

import CoreLocation
import XCTest
@testable import RadarMap

@MainActor
final class VoiceTextTests: XCTestCase {

    private typealias OSRM = RouteService.OSRMResponse

    // MARK: - Пробка, лимит, объезд

    func testJamEventRendersTheSpokenPhrase() {
        for (length, delay) in [(320.0, 61.0), (1_249.0, 239.6), (1_500.0, 3_700.0), (870.0, 600.0)] {
            let jam = JamAhead.Jam(startsIn: 200, length: length, delay: delay,
                                   start: CLLocationCoordinate2D(latitude: 41.3, longitude: 69.2))
            XCTAssertEqual(VoiceText.render(jam.voiceEvent), jam.spoken)
        }
    }

    func testLimitAheadEventRendersTheSpokenPhrase() {
        for (limit, distance) in [(40, 212.0), (60, 99.0), (30, 388.0)] {
            let notice = LimitAhead.Notice(limit: limit, distance: distance,
                                           at: CLLocationCoordinate2D(latitude: 41.3, longitude: 69.2))
            XCTAssertEqual(VoiceText.render(notice.voiceEvent), notice.spoken)
        }
    }

    func testDetourEventOnlyWithoutStreet() {
        let plain = RouteService.DetourOffer(id: 1, saving: 487, via: nil, waitingSince: Date())
        XCTAssertEqual(plain.voiceEvent.map(VoiceText.render), plain.spoken)
        let street = RouteService.DetourOffer(id: 2, saving: 487, via: "Шота Руставели", waitingSince: Date())
        XCTAssertNil(street.voiceEvent, "улицу диктор не записывал — фраза синтезатором")
    }

    // MARK: - Манёвры

    private func step(_ type: String, _ modifier: String?, name: String = "", exit: Int? = nil,
                      lanes: [OSRM.Lane]? = nil, stopName: String? = nil) -> RouteStep? {
        RouteService.maneuverStep(
            OSRM.Step(distance: 100, name: name,
                      maneuver: OSRM.Maneuver(type: type, modifier: modifier, exit: exit),
                      intersections: lanes.map { [OSRM.Intersection(lanes: $0)] }),
            at: 500, language: "ru", stopName: stopName)
    }

    /// Каждый озвучиваемый шаг OSRM: команда, ближнее и дальнее
    /// предупреждение рендерятся ровно в то, что сказал бы RouteService.
    func testManeuverEventsRenderTheSpokenPhrases() {
        let modifiers = ["left", "right", "slight left", "slight right", "sharp left", "sharp right",
                         "uturn", "straight", nil]
        let types = ["turn", "end of road", "continue", "fork", "merge", "on ramp", "off ramp",
                     "roundabout", "rotary", "arrive", "depart", "new name"]
        var voiced = 0
        for type in types {
            for modifier in modifiers {
                guard let step = step(type, modifier, exit: 3) else { continue }
                guard let now = step.voiceEvent(meters: nil) else {
                    return XCTFail("\(type)/\(modifier ?? "-"): шаг озвучивается, а события нет")
                }
                voiced += 1
                XCTAssertEqual(VoiceText.render(now), step.text, "\(type)/\(modifier ?? "-")")
                // Край — как у многополосного подъезда: тоже должен совпасть.
                var wide = step
                wide.approachLanes = 3
                for candidate in [step, wide] {
                    for meters in [50, 300, 800] {
                        let spoken = RouteService.withAdvice(
                            String(format: String(localized: "Через %lld метров — %@"), meters, candidate.text),
                            candidate.laneAdvice)
                        XCTAssertEqual(candidate.voiceEvent(meters: meters, advice: candidate.laneAdvice)
                            .map(VoiceText.render), spoken, "\(type)/\(modifier ?? "-")")
                    }
                }
            }
        }
        XCTAssertGreaterThan(voiced, 20)
    }

    func testManeuverLanesRenderLikeWithAdvice() {
        let lanes = "++--".map { LaneHint(arrows: [.left], isValid: $0 == "+") }
        let step = RouteStep(distanceAlong: 500, text: VoiceText.text(.turnLeft), icon: "arrow.turn.up.left",
                             kind: nil, lanes: lanes, voiceAction: .turnLeft)
        let spoken = RouteService.withAdvice(
            String(format: String(localized: "Через %lld метров — %@"), 300, step.text), step.laneAdvice)
        XCTAssertEqual(step.voiceEvent(meters: 300, advice: step.laneAdvice).map(VoiceText.render), spoken)
        XCTAssertTrue(spoken.hasSuffix(String(localized: "Из двух левых рядов")), spoken)
        XCTAssertEqual(step.voiceEvent(meters: nil, advice: step.laneAdvice),
                       .maneuver(.init(action: .turnLeft, meters: nil, lanes: nil)),
                       "у самого манёвра ряд не называют")
    }

    /// Край без полос (20.2) звучит записью тем же текстом, что сказал код;
    /// фраза без совета (ряд уже назван раньше) — без хвоста.
    func testManeuverEdgeRendersLikeWithAdvice() {
        let cases: [(VoiceEvent.Action, LaneAdvice.Edge)] = [
            (.turnLeft, .left), (.uturn, .farLeft), (.turnRight, .right),
            (.offRamp, .keepLeft), (.offRamp, .keepRight)]
        for (action, edge) in cases {
            let step = RouteStep(distanceAlong: 500, text: VoiceText.text(action), icon: "arrow.up",
                                 kind: nil, voiceAction: action, edge: edge, approachLanes: 2)
            let line = String(format: String(localized: "Через %lld метров — %@"), 350, step.text)
            XCTAssertEqual(step.voiceEvent(meters: 350, advice: step.laneAdvice).map(VoiceText.render),
                           RouteService.withAdvice(line, step.laneAdvice))
            XCTAssertTrue(RouteService.withAdvice(line, step.laneAdvice).hasSuffix(LaneAdvice.spoken(edge)))
            XCTAssertEqual(step.voiceEvent(meters: 350).map(VoiceText.render), line,
                           "ряд уже назван — фраза без хвоста")
        }
    }

    func testStreetsAndStopsStaySynthesized() {
        XCTAssertNil(step("turn", "right", name: "Amir Temur shoh ko'chasi")?.voiceEvent(meters: nil),
                     "с улицей — синтезатором")
        XCTAssertNil(step("arrive", nil, stopName: "АЗС")?.voiceEvent(meters: nil),
                     "«заезд: АЗС» — синтезатором")
        XCTAssertNotNil(step("arrive", nil)?.voiceEvent(meters: nil))
    }

    // MARK: - Камера

    private func announcement(_ type: CameraType, distance: Double, urgent: Bool = false,
                              speaksLimit: Bool = false, brief: Bool = false, groupCount: Int = 0,
                              onRoute: Bool = false, direction: CameraDirection? = .ahead,
                              unconfirmed: Bool = false, limit: Int? = nil,
                              speed: Double = 60) -> VoiceEvent? {
        VoiceEvent.cameraAnnouncement(type: type, distance: distance, urgent: urgent,
                                      speaksLimit: speaksLimit, brief: brief, groupCount: groupCount,
                                      onRoute: { onRoute }, direction: direction,
                                      unconfirmed: unconfirmed, currentLimit: limit,
                                      speedKmh: speed, speakSpeedThreshold: AppConfig.speakSpeedThresholdKmh)
    }

    /// Решения фразы о камере — те же, что у announcement: округление
    /// 50/100 м, форма по приоритету «группа → коротко → по маршруту →
    /// полная», хвост «скорость + лимит» только в срочном.
    func testCameraAnnouncementDecisions() {
        typealias Call = VoiceEvent.CameraCall
        XCTAssertEqual(announcement(.stationaryRadar, distance: 377),
                       .camera(Call(kind: .stationaryRadar, form: .full(.ahead), meters: 400)))
        XCTAssertEqual(announcement(.stationaryRadar, distance: 362),
                       .camera(Call(kind: .stationaryRadar, form: .full(.ahead), meters: 350)))
        XCTAssertEqual(announcement(.stationaryRadar, distance: 300, brief: true, groupCount: 2, onRoute: true),
                       .camera(Call(kind: .stationaryRadar, form: .group, meters: 300)))
        XCTAssertEqual(announcement(.mobileRadar, distance: 300, brief: true, onRoute: true),
                       .camera(Call(kind: .mobileRadar, form: .brief, meters: 300)))
        XCTAssertEqual(announcement(.tripod, distance: 300, onRoute: true, unconfirmed: true),
                       .camera(Call(kind: .tripod, form: .onRoute, meters: 300, fromDrivers: true)))
        XCTAssertEqual(announcement(.stationaryCamera, distance: 500, direction: .behindLeft),
                       .camera(Call(kind: .stationaryCamera, form: .full(.aheadLeft), meters: 500)))
        XCTAssertEqual(announcement(.stationaryRadar, distance: 500, urgent: true, limit: 60, speed: 74.6),
                       .camera(Call(kind: .stationaryRadar, form: .full(.ahead), meters: 500,
                                    tail: .speedAndLimit(speed: 75, limit: 60))))
        XCTAssertEqual(announcement(.stationaryRadar, distance: 500, urgent: true, speed: 82),
                       .camera(Call(kind: .stationaryRadar, form: .full(.ahead), meters: 500, tail: .speed(82))))
        XCTAssertEqual(announcement(.stationaryRadar, distance: 500, urgent: true, speed: 12),
                       .camera(Call(kind: .stationaryRadar, form: .full(.ahead), meters: 500)),
                       "ниже порога скорость не называют")
        XCTAssertEqual(announcement(.stationaryRadar, distance: 500, speaksLimit: true, limit: 70),
                       .camera(Call(kind: .stationaryRadar, form: .full(.ahead), meters: 500, tail: .limit(70))))
        XCTAssertNil(announcement(.other("Нечто"), distance: 300), "незнакомый тип — синтезатором")
        XCTAssertNotNil(announcement(.other("Нечто"), distance: 300, groupCount: 1),
                        "групповая фраза тип не называет")
    }

    /// Рендер фразы о камеры — шаблонами announcement: «Отметка водителей:»
    /// со строчной буквой дальше, хвосты в конце.
    func testCameraRenderFollowsAnnouncementTemplates() {
        typealias Call = VoiceEvent.CameraCall
        let kind = CameraType.mobileRadar
        let head = String(format: String(localized: "%@ %@, %lld метров"),
                          kind.displayName, String(localized: "впереди справа"), 300)
        let expected = String(format: String(localized: "Отметка водителей: %@"),
                              head.prefix(1).lowercased() + head.dropFirst())
            + String(format: String(localized: ". Ваша скорость %lld, лимит %lld"), 75, 60)
        XCTAssertEqual(VoiceText.render(.camera(Call(kind: .mobileRadar, form: .full(.aheadRight), meters: 300,
                                                     fromDrivers: true,
                                                     tail: .speedAndLimit(speed: 75, limit: 60)))),
                       expected)
        XCTAssertEqual(VoiceText.render(.camera(Call(kind: .stationaryCamera, form: .brief, meters: 300))),
                       String(format: String(localized: "%@, %lld метров"), CameraType.stationaryCamera.shortName, 300))
    }

    // MARK: - Готовые строки

    func testHotspotAndRoadEventPhrasesAreFoundByText() {
        let index = VoiceText.index()
        for peak in [-1, 0, 1, 2, 3] {
            let spot = TripodHotspots.Spot(lat: 41.3, lon: 69.2, n: 5, days: 3, peak: peak)
            XCTAssertEqual(index[HotspotAlert.phrase(for: spot)], .hotspot(VoiceEvent.Peak(hotspotPeak: peak)))
        }
        for (kind, confirmed) in [(RoadEvent.Kind.closure, true), (.closure, false), (.roadwork, true)] {
            let event = RoadEvent(id: 1, kind: kind, lat: 41.3, lon: 69.2, course: -1,
                                  expires: Date(), confirmed: confirmed)
            XCTAssertNotNil(index[RoadEventRules.phrase(for: event)], RoadEventRules.phrase(for: event))
        }
    }

    func testReportOutcomesAreFoundByText() {
        typealias Outcome = MobileCameraService.QuickOutcome
        let failures: [MobileCameraService.ReportResult.Failure] = [
            .offline, .tooOften, .refused, .serverBroken, .disabled, .badAnswer]
        var outcomes: [Outcome] = [.sent(.created), .sent(.confirmed), .sent(.amended),
                                   .refused(.duplicate), .refused(.noPosition), .refused(.notDriving),
                                   .queued(.serverBroken), .queued(.offline)]
        outcomes += failures.map { .sent(.failed($0)) }
        let index = VoiceText.index()
        for outcome in outcomes {
            XCTAssertNotNil(index[outcome.spoken], outcome.spoken)
        }
        for kind in ReportKind.allCases {
            XCTAssertNotNil(index[kind.title], kind.title)
        }
        for text in [String(localized: "Маршрут перестроен"), String(localized: "Вы прибыли"),
                     String(localized: "Превышение скорости"), String(localized: "Спасибо!"),
                     String(localized: "Отметка убрана"), String(localized: "Не отправилось, нет связи"),
                     String(localized: "Камера, триста метров"),
                     String(localized: "Поездка началась — слежу за камерами"),
                     String(localized: "Поездка завершена"), String(localized: "Маршрут завершён"),
                     String(localized: "Маршрут не построился"),
                     String(localized: "Не вижу точного положения — маршрут пока не построить")] {
            XCTAssertNotNil(index[text], text)
        }
    }

    /// Два события не могут давать один текст: по тексту фраза находится
    /// однозначно.
    func testIndexHasNoCollisions() {
        var events: [VoiceEvent] = VoiceEvent.Phrase.allCases.map { .phrase($0) }
        events += VoiceEvent.Kind.allCases.map { .cameraName($0) }
        events += [.hotspot(nil)] + VoiceEvent.Peak.allCases.map { .hotspot($0) }
        events += (VoiceEvent.Action.simple + (1...VoiceScript.maxRoundaboutExit).map { .roundabout(exit: $0) })
            .map { .maneuver(.init(action: $0, meters: nil, lanes: nil)) }
        XCTAssertEqual(VoiceText.index().count, events.count)
        XCTAssertEqual(Set(events.map(VoiceText.render)).count, events.count)
    }

    func testLaneAdviceTextMatchesPhrase() {
        func row(_ pattern: String) -> [LaneHint] {
            pattern.map { LaneHint(arrows: [.straight], isValid: $0 == "+") }
        }
        for pattern in ["+---", "++--", "+++--", "++++---", "---+", "--++", "-+++", "+++-", "-+-", "-++--"] {
            let lanes = row(pattern)
            XCTAssertEqual(LaneAdvice.run(lanes).map(LaneAdvice.text(for:)), LaneAdvice.phrase(lanes), pattern)
        }
        XCTAssertNil(LaneAdvice.run(row("+-+")), "разрозненные полосы словами не описать")
    }
}
