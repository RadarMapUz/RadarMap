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

    /// Плашка: прибытие сдвинулось на 2+ мин или сменилась тревожность —
    /// повод обновить; минута в пробке и та же строка — нет (бюджет плашки).
    func testLiveActivityUpdatesOnlyOnRealGhostChanges() {
        var old = CameraActivityAttributes.ContentState(nearestTitle: nil, nearestSymbol: "checkmark.shield.fill",
                                                        distanceMeters: nil, arrivesAt: nil, since: nil)
        old.etaClock = arrival
        old.etaCaption = "Работа · как обычно"
        old.etaAlert = false
        var minute = old
        minute.etaClock = arrival.addingTimeInterval(60)
        minute.etaCaption = "Работа · +1 мин к обычному"
        XCTAssertFalse(LiveActivityService.differs(minute, from: old, now: arrival), "минута в пробке — не повод")
        var shifted = old
        shifted.etaClock = arrival.addingTimeInterval(120)
        XCTAssertTrue(LiveActivityService.differs(shifted, from: old, now: arrival))
        var alarm = old
        alarm.etaAlert = true
        XCTAssertTrue(LiveActivityService.differs(alarm, from: old, now: arrival))
        var gone = old
        gone.etaClock = nil
        XCTAssertTrue(LiveActivityService.differs(gone, from: old, now: arrival))
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
        XCTAssertTrue(CommuteLiveService.showsLatePlaque(slack: .late, done: false, shown: true, speedKmh: 30,
                                                         coveredByCamera: false),
                      "показанная держится и тронувшись — не мигает в «едем-стоим»")
    }
}

/// «Почему дольше» одним словом (8.8.12): пробка или стояли — только когда
/// причина видна; без неё — без слова.
final class GhostReasonTests: XCTestCase {
    func testReasonOnlyWhenVisible() {
        XCTAssertNil(CommuteGhost.reason(delta: 30, jamSeconds: 300, longestStand: 600), "меньше минуты — не «дольше»")
        XCTAssertEqual(CommuteGhost.reason(delta: 360, jamSeconds: 300, longestStand: 0), .jam)
        XCTAssertEqual(CommuteGhost.reason(delta: 360, jamSeconds: 0, longestStand: AppConfig.commuteLongStandSeconds), .stood)
        XCTAssertNil(CommuteGhost.reason(delta: 360, jamSeconds: 20, longestStand: 90), "светофор и полминуты — не причина")
        // Короткая ранняя пробка и долгая стоянка у аптеки — «стояли»: что
        // стоило больше секунд, то и названо.
        XCTAssertEqual(CommuteGhost.reason(delta: 400, jamSeconds: 90, longestStand: 240), .stood)
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
