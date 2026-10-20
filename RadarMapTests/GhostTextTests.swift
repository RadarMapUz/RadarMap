//
//  GhostTextTests.swift
//  RadarMapTests
//
//  Слова призрака одни на панели поездки, в доке и на плитке CarPlay и на
//  плашке Live Activity (8.8.3б): без «быстрее обычного», тревожность — по
//  запасу или по заметной задержке, а плашка обновляется со сменой минуты
//  прибытия или подписи, а не на каждом фиксе.
//

import XCTest
@testable import RadarMap

final class GhostTextTests: XCTestCase {
    private let arrival = Date(timeIntervalSince1970: 1_800_000_000)

    private func ghost(_ delta: Int, slack: CommuteGhost.TargetSlack? = nil) -> CommuteLiveService.Display {
        CommuteLiveService.Display(direction: .toWork, arrival: arrival, deltaMinutes: delta, slack: slack)
    }

    private func slack(_ state: CommuteGhost.Slack, _ minutes: Int) -> CommuteGhost.TargetSlack {
        CommuteGhost.TargetSlack(state: state, minutes: minutes, deadline: arrival.addingTimeInterval(600))
    }

    func testNeverSaysFaster() throws {
        try XCTSkipUnless(Bundle.main.preferredLocalizations.first == "ru", "слова — по русскому каталогу")
        XCTAssertEqual(GhostText.tail(ghost(-6)), "как обычно", "опережение видно по времени, не словами")
        XCTAssertEqual(GhostText.tail(ghost(0)), "как обычно")
        XCTAssertEqual(GhostText.tail(ghost(4)), "+4 мин к обычному")
        XCTAssertEqual(GhostText.caption(ghost(4)), "Работа · +4 мин к обычному")
    }

    func testAlertByTargetOrNoticeableDelay() {
        XCTAssertFalse(GhostText.isAlert(ghost(AppConfig.commuteGhostLateMinutes - 1)))
        XCTAssertTrue(GhostText.isAlert(ghost(AppConfig.commuteGhostLateMinutes)))
        XCTAssertTrue(GhostText.isAlert(ghost(0, slack: slack(.tight, 2))))
        XCTAssertTrue(GhostText.isAlert(ghost(0, slack: slack(.late, -3))))
        XCTAssertFalse(GhostText.isAlert(ghost(9, slack: slack(.comfortable, 12))),
                       "со сроком решает запас, а не отклонение")
    }

    /// Плашка: смена минуты прибытия или подписи — повод обновить, та же
    /// строка на следующем фиксе — нет.
    func testLiveActivityUpdatesOnGhostMinuteOnly() {
        var old = CameraActivityAttributes.ContentState(nearestTitle: nil, nearestSymbol: "checkmark.shield.fill",
                                                        distanceMeters: nil, arrivesAt: nil, since: nil)
        old.etaClock = arrival
        old.etaCaption = "Работа · как обычно"
        var same = old
        same.since = arrival.addingTimeInterval(5)
        XCTAssertFalse(LiveActivityService.differs(same, from: old, now: arrival))
        var later = old
        later.etaClock = arrival.addingTimeInterval(60)
        XCTAssertTrue(LiveActivityService.differs(later, from: old, now: arrival))
        var worse = old
        worse.etaCaption = "Работа · +4 мин к обычному"
        XCTAssertTrue(LiveActivityService.differs(worse, from: old, now: arrival))
    }
}

/// «Опаздываю — предупредить?» (8.8.14): только «позже срока», стоя, не под
/// оповещением о камере и один раз за поездку.
final class GhostLatePlaqueTests: XCTestCase {
    func testShownOnlyLateStandingOnce() {
        XCTAssertTrue(CommuteLiveService.showsLatePlaque(slack: .late, done: false, speedKmh: 0, coveredByCamera: false))
        XCTAssertFalse(CommuteLiveService.showsLatePlaque(slack: .tight, done: false, speedKmh: 0, coveredByCamera: false),
                       "впритык — ещё не опаздываем")
        XCTAssertFalse(CommuteLiveService.showsLatePlaque(slack: nil, done: false, speedKmh: 0, coveredByCamera: false),
                       "без срока — никогда")
        XCTAssertFalse(CommuteLiveService.showsLatePlaque(slack: .late, done: false, speedKmh: 45, coveredByCamera: false),
                       "на ходу лист «Поделиться» — помеха")
        XCTAssertFalse(CommuteLiveService.showsLatePlaque(slack: .late, done: true, speedKmh: 0, coveredByCamera: false),
                       "одна на поездку")
        XCTAssertFalse(CommuteLiveService.showsLatePlaque(slack: .late, done: false, speedKmh: 0, coveredByCamera: true),
                       "под оповещением о камере ждёт")
    }
}

/// «Почему дольше» одним словом (8.8.12): пробка или стояли — только когда
/// причина видна; без неё — без слова.
final class GhostReasonTests: XCTestCase {
    func testReasonOnlyWhenVisible() {
        XCTAssertNil(CommuteGhost.reason(delta: 30, sawJam: true, longestStand: 600), "меньше минуты — не «дольше»")
        XCTAssertEqual(CommuteGhost.reason(delta: 360, sawJam: true, longestStand: 0), .jam)
        XCTAssertEqual(CommuteGhost.reason(delta: 360, sawJam: false, longestStand: AppConfig.commuteLongStandSeconds), .stood)
        XCTAssertNil(CommuteGhost.reason(delta: 360, sawJam: false, longestStand: 90), "светофор — не «стояли»")
    }

    func testWordJoinsTheTail() throws {
        try XCTSkipUnless(Bundle.main.preferredLocalizations.first == "ru", "слова — по русскому каталогу")
        let ghost = CommuteLiveService.Display(direction: .toWork, arrival: Date(timeIntervalSince1970: 1_800_000_000),
                                               deltaMinutes: 6, slack: nil, reason: .jam)
        XCTAssertEqual(GhostText.tail(ghost), "+6 мин к обычному · пробка")
        var usual = ghost
        usual.reason = .stood
        XCTAssertEqual(GhostText.tail(usual), "+6 мин к обычному · стояли")
        let calm = CommuteLiveService.Display(direction: .toWork, arrival: ghost.arrival, deltaMinutes: 0,
                                              slack: nil, reason: .jam)
        XCTAssertEqual(GhostText.tail(calm), "как обычно", "как обычно — без причины")
    }
}
