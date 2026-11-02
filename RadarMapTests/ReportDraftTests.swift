//
//  ReportDraftTests.swift
//  RadarMapTests
//
//  Черновик отметки (вариант B, 02.11): тренога молчанием или «тап-тап»,
//  «✕» — ничего, точка и скорость — с первого касания, одна отправка на все
//  входы, тип с другого входа закрывает выбор, окно «Отменить» 8 с.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class ReportDraftTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func touch(_ source: ReportDraft.Source = .phone, at: Date? = nil, lat: Double = 41.3,
                       speed: Double = 60) -> ReportDraft.Touch {
        ReportDraft.Touch(latitude: lat, longitude: 69.2, speedKmh: speed, course: 90, isTripActive: true,
                          fix: nil, at: at ?? t0, source: source)
    }

    /// Касание ничего не отправляет: открывает выбор с отсчётом 3 с.
    func testTapOpensChoiceAndSendsNothing() {
        var draft = ReportDraft()
        XCTAssertEqual(draft.tap(touch(), refusal: nil, showsChoice: true),
                       .choose(deadline: t0.addingTimeInterval(AppConfig.reportChooseSeconds)))
        XCTAssertFalse(draft.isInFlight)
        XCTAssertNotNil(draft.choosing)
    }

    /// Молчание 3 с — тренога, по точке касания.
    func testSilenceSendsTripod() {
        var draft = ReportDraft()
        _ = draft.tap(touch(), refusal: nil, showsChoice: true)
        XCTAssertEqual(draft.expire(now: t0.addingTimeInterval(2.9)), .none, "до срока — ничего")
        XCTAssertEqual(draft.expire(now: t0.addingTimeInterval(3)), .send(touch(), .tripod))
        XCTAssertTrue(draft.isInFlight)
    }

    func testChoiceSendsThatKind() {
        var draft = ReportDraft()
        _ = draft.tap(touch(), refusal: nil, showsChoice: true)
        XCTAssertEqual(draft.choose(.post), .send(touch(), .post))
        XCTAssertEqual(draft.expire(now: t0.addingTimeInterval(10)), .none, "выбранное не уходит второй раз треногой")
    }

    /// «✕» — не уходит ничего, и отсчёт после этого ничего не отправит.
    func testCancelSendsNothing() {
        var draft = ReportDraft()
        _ = draft.tap(touch(), refusal: nil, showsChoice: true)
        XCTAssertEqual(draft.cancel(), .cancelled)
        XCTAssertEqual(draft.phase, .idle)
        XCTAssertEqual(draft.expire(now: t0.addingTimeInterval(5)), .none)
        XCTAssertEqual(draft.choose(.tripod), .none)
    }

    /// «Тап-тап» вслепую — тренога сразу и по ПЕРВОЙ точке.
    func testDoubleTapSendsTripodAtFirstPoint() {
        var draft = ReportDraft()
        let first = touch(at: t0, lat: 41.300)
        _ = draft.tap(first, refusal: nil, showsChoice: true)
        let second = touch(at: t0.addingTimeInterval(0.6), lat: 41.301)
        XCTAssertEqual(draft.tap(second, refusal: nil, showsChoice: true), .send(first, .tripod))
    }

    /// Одна отправка на все входы: касание во время полёта — проглочено.
    func testTapWhileSendingIsBusy() {
        var draft = ReportDraft()
        _ = draft.tap(touch(.watch), refusal: nil, showsChoice: false)
        XCTAssertTrue(draft.isInFlight)
        XCTAssertEqual(draft.tap(touch(.carBar), refusal: nil, showsChoice: true), .busy)
        XCTAssertEqual(draft.explicit(.post, touch: touch(.siri), refusal: nil), .busy)
    }

    /// Siri «Пост здесь» при открытом выборе: тот же черновик, тип поста,
    /// точка — первого касания.
    func testExplicitKindClosesOpenChoice() {
        var draft = ReportDraft()
        let first = touch(.phone, lat: 41.300)
        _ = draft.tap(first, refusal: nil, showsChoice: true)
        XCTAssertEqual(draft.explicit(.post, touch: touch(.siri, lat: 41.305), refusal: nil), .send(first, .post))
    }

    /// Точка, скорость и курс — из момента касания, без изменений.
    func testTouchSnapshotTravelsUnchanged() {
        var draft = ReportDraft()
        let first = touch(at: t0, lat: 41.3123, speed: 72)
        _ = draft.tap(first, refusal: nil, showsChoice: true)
        guard case .send(let sent, _) = draft.expire(now: t0.addingTimeInterval(4)) else {
            return XCTFail("молчание должно отправить")
        }
        XCTAssertEqual(sent, first)
        XCTAssertEqual(sent.speedKmh, 72)
    }

    /// Отказ ReportGuard по точке касания — черновика нет.
    func testRefusalAtTapCreatesNoDraft() {
        var draft = ReportDraft()
        XCTAssertEqual(draft.tap(touch(), refusal: .notDriving, showsChoice: true), .refused(.notDriving))
        XCTAssertEqual(draft.phase, .idle)
        XCTAssertEqual(draft.serial, 0)
    }

    /// Камера на экране машины (или часы, плашка) — выбор не встаёт,
    /// тренога уходит сразу.
    func testNoChoiceSendsTripodAtOnce() {
        var draft = ReportDraft()
        XCTAssertEqual(draft.tap(touch(.carMap), refusal: nil, showsChoice: false), .send(touch(.carMap), .tripod))
        XCTAssertFalse(ReportDraft.Source.watch.offersChoice)
        XCTAssertFalse(ReportDraft.Source.liveActivity.offersChoice)
        XCTAssertFalse(ReportDraft.Source.phoneAlert.offersChoice)
        XCTAssertTrue(ReportDraft.Source.carBar.offersChoice)
    }

    /// Окно «Отменить» — 8 с; потом черновик закрывается сам.
    func testUndoWindowIsEightSeconds() {
        var draft = ReportDraft()
        _ = draft.tap(touch(), refusal: nil, showsChoice: false)
        let answered = t0.addingTimeInterval(1)
        draft.finished(delivered: true, serverID: 42, queued: false, now: answered)
        XCTAssertEqual(draft.sent?.undoUntil, answered.addingTimeInterval(8))
        XCTAssertEqual(draft.sent?.canUndo, true)
        XCTAssertFalse(draft.closeUndo(now: answered.addingTimeInterval(7.9)))
        XCTAssertTrue(draft.closeUndo(now: answered.addingTimeInterval(8)))
        XCTAssertEqual(draft.phase, .idle)
    }

    /// Без сети: отметка в очереди — «Отменить» снимает её оттуда по времени
    /// касания.
    func testQueuedReportCanBeUndone() {
        var draft = ReportDraft()
        _ = draft.tap(touch(), refusal: nil, showsChoice: false)
        draft.finished(delivered: true, serverID: nil, queued: true, now: t0)
        XCTAssertEqual(draft.sent?.canUndo, true)
        XCTAssertEqual(draft.sent?.touchedAt, t0)
        draft.undone()
        XCTAssertEqual(draft.phase, .idle)
    }

    /// Влилась в чужую точку — отменять нечего (точка не своя).
    func testMergedReportCannotBeUndone() {
        var draft = ReportDraft()
        _ = draft.tap(touch(), refusal: nil, showsChoice: false)
        draft.finished(delivered: true, serverID: nil, queued: false, now: t0)
        XCTAssertEqual(draft.sent?.canUndo, false)
    }

    /// Не ушла — черновика нет, отменять нечего.
    func testFailureClosesDraft() {
        var draft = ReportDraft()
        _ = draft.tap(touch(), refusal: nil, showsChoice: false)
        draft.finished(delivered: false, serverID: nil, queued: false, now: t0)
        XCTAssertEqual(draft.phase, .idle)
    }

    /// Сетка машины до iOS 27: водитель сказал «не тренога» — молчание
    /// теперь не отправляет ничего.
    func testHoldTurnsSilenceIntoNothing() {
        var draft = ReportDraft()
        _ = draft.tap(touch(), refusal: nil, showsChoice: true)
        draft.hold(until: t0.addingTimeInterval(10))
        XCTAssertEqual(draft.expire(now: t0.addingTimeInterval(5)), .none)
        XCTAssertEqual(draft.expire(now: t0.addingTimeInterval(10)), .cancelled)
    }

    /// Новое касание в окне «Отменить» — новый черновик; отказ по нему не
    /// трогает прежнюю отметку.
    func testRefusedTapKeepsPreviousUndo() {
        var draft = ReportDraft()
        _ = draft.tap(touch(), refusal: nil, showsChoice: false)
        draft.finished(delivered: true, serverID: 7, queued: false, now: t0)
        XCTAssertEqual(draft.tap(touch(), refusal: .duplicate, showsChoice: true), .refused(.duplicate))
        XCTAssertNotNil(draft.sent)
    }

    /// Siri — поправка на фразу; остальные — общая реакция.
    func testReactionBySource() {
        XCTAssertEqual(ReportDraft.Source.phone.reactionSeconds, AppConfig.reportReactionSeconds)
        XCTAssertGreaterThan(ReportDraft.Source.siri.reactionSeconds, ReportDraft.Source.carBar.reactionSeconds)
    }

    /// Род у каждого типа свой: «Тренога отмечена», «Пост ДПС отмечен».
    func testSpokenTypeAgreesInGender() {
        XCTAssertEqual(ReportWords.marked(.tripod), "Тренога отмечена")
        XCTAssertEqual(ReportWords.marked(.post), "Пост ДПС отмечен")
        XCTAssertEqual(ReportWords.marked(.accident), "ДТП отмечено")
        XCTAssertEqual(ReportWords.marked(.radar), "Радар отмечен")
        XCTAssertEqual(ReportKind.chosenOnTheGo.first, ReportDraft.defaultKind)
        XCTAssertEqual(ReportDraft.defaultKind, .tripod)
        XCTAssertEqual(ReportKind.chosenOnTheGo.map(ReportWords.title), ["Тренога", "Пост ДПС", "ДТП"])
    }
}
