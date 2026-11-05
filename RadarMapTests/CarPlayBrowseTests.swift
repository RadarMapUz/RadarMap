//
//  CarPlayBrowseTests.swift
//  RadarMapTests
//
//  Осмотр карты в машине. Главное — характеризация бага 2.2.20: карта
//  вернулась к машине, а интерфейс осмотра остался, и в баре стояла одна
//  «Готово» без «Поездки», «Звука», «Куда» и «Радар!» (аудит 18.10, п. 1).
//

import XCTest
@testable import RadarMap

final class CarPlayBrowseTests: XCTestCase {

    private typealias B = CarPlayBrowse

    private func run(_ events: [B.Event], from state: B.State = B.State(),
                     previewing: Bool = false) -> (B.State, [B.Effect]) {
        var state = state
        var effects: [B.Effect] = []
        for event in events {
            effects = B.reduce(&state, event, previewing: previewing)
        }
        return (state, effects)
    }

    func testIdleReturnClosesPanningNotOnlyTheMap() {
        // Сдвинули в осмотре и забыли: через таймер — и к машине, и бар назад.
        let (state, effects) = run([.panningShown, .moved, .idleTimeout])
        XCTAssertTrue(effects.contains(.closePanning), "осмотр закрывается вместе с возвратом")
        XCTAssertTrue(effects.contains(.recenter))
        XCTAssertTrue(state.following)
    }

    func testPanningWithoutAnyMoveStillTimesOut() {
        // 2.2.20: открыли осмотр и ничего не тронули — таймера не было вовсе.
        let (_, opened) = run([.panningShown])
        XCTAssertEqual(opened, [.armIdle])
        let (state, effects) = run([.panningShown, .idleTimeout])
        XCTAssertEqual(effects.first, .closePanning)
        XCTAssertFalse(effects.contains(.recenter), "карта и так у машины — двигать незачем")
        XCTAssertTrue(state.following)
    }

    func testCameraAheadClosesPanningAndReturnsTheMap() {
        let (state, effects) = run([.panningShown, .moved, .cameraAhead])
        XCTAssertEqual(effects.prefix(2), [.closePanning, .recenter])
        XCTAssertTrue(state.following)
    }

    func testCameraAheadWhileFollowingChangesNothing() {
        XCTAssertEqual(run([.cameraAhead]).1, [])
    }

    func testEveryMoveRearmsTheTimer() {
        XCTAssertEqual(run([.panningShown, .moved]).1, [.armIdle])
        XCTAssertEqual(run([.panningShown, .zoomed]).1, [.armIdle], "зум в осмотре — тоже активность")
    }

    func testZoomWhileFollowingIsNotBrowsing() {
        // «+» при слежении сдвигает автозум — таймеру возврата там делать нечего.
        let (state, effects) = run([.zoomed])
        XCTAssertEqual(effects, [])
        XCTAssertTrue(state.following)
    }

    func testDoneKeepsTheFreeMapUntilTheTimer() {
        // «Готово» после сдвига: карта стоит, таймер возврата жив.
        let (state, effects) = run([.panningShown, .moved, .panningHidden])
        XCTAssertEqual(effects, [])
        XCTAssertFalse(state.panning)
        XCTAssertFalse(state.following)
        let (_, later) = run([.idleTimeout], from: state)
        XCTAssertEqual(later, [.recenter, .cancelIdle])
    }

    func testDoneWithoutMovingCancelsTheTimer() {
        XCTAssertEqual(run([.panningShown, .panningHidden]).1, [.cancelIdle])
    }

    func testRouteChoiceHoldsTheOverview() {
        // Выбор маршрута: линия целиком, и ни таймер, ни камера её не сбивают.
        let (state, effects) = run([.overview], previewing: true)
        XCTAssertFalse(state.following, "«+/−» в обзоре — зум карты, а не автозума")
        XCTAssertEqual(effects, [.cancelIdle])
        XCTAssertEqual(run([.idleTimeout], from: state, previewing: true).1, [])
        XCTAssertEqual(run([.cameraAhead], from: state, previewing: true).1, [])
        XCTAssertEqual(run([.zoomed], from: state, previewing: true).1, [])
    }

    /// «Весь маршрут» во время ведения (10.4) — обзор вернётся к машине сам,
    /// камера впереди возвращает сразу.
    func testOverviewWhileGuidingReturnsByItself() {
        let (state, effects) = run([.overview], previewing: false)
        XCTAssertFalse(state.following)
        XCTAssertEqual(effects, [.armIdle])
        XCTAssertEqual(run([.idleTimeout], from: state, previewing: false).1, [.recenter, .cancelIdle])
        XCTAssertEqual(run([.cameraAhead], from: state, previewing: false).1, [.recenter, .cancelIdle])
    }

    func testRecenterAfterPreviewFollowsAgain() {
        var state = B.State(following: false, panning: false)
        XCTAssertEqual(B.reduce(&state, .recenter, previewing: false), [.recenter, .cancelIdle])
        XCTAssertTrue(state.following)
    }

    /// Удержанная стрелка не панорамирует вечно: «отпустили» теряется при
    /// автозакрытии осмотра и отключении машины (аудит 19.10).
    func testPanHoldStopsAtTheCap() {
        XCTAssertTrue(B.panHoldContinues(steps: 0, interval: 0.15, maxSeconds: 15))
        XCTAssertTrue(B.panHoldContinues(steps: 99, interval: 0.15, maxSeconds: 15))
        XCTAssertFalse(B.panHoldContinues(steps: 100, interval: 0.15, maxSeconds: 15))
        XCTAssertFalse(B.panHoldContinues(steps: 10_000))
    }

    /// Возврат по камере — по признаку баннера, один раз на камеру (QA 05.11).
    func testCameraReturnFollowsTheBannerOncePerCamera() {
        let foreign = CarPlayCameraCue.decide(cameraID: 5, approaching: true, familiar: false)
        let own = CarPlayCameraCue.decide(cameraID: 6, approaching: true, familiar: true)
        XCTAssertTrue(CarPlayBrowse.cameraReturn(foreign, returnedFor: nil).due)
        XCTAssertEqual(CarPlayBrowse.cameraReturn(foreign, returnedFor: nil).returnedFor, 5)
        XCTAssertFalse(CarPlayBrowse.cameraReturn(foreign, returnedFor: 5).due, "та же камера — уже вернулись")
        XCTAssertTrue(CarPlayBrowse.cameraReturn(CarPlayCameraCue.decide(cameraID: 9, approaching: true,
                                                                         familiar: false), returnedFor: 5).due,
                      "следующая камера — снова")
        XCTAssertFalse(CarPlayBrowse.cameraReturn(own, returnedFor: nil).due, "своя камера без баннера")
        XCTAssertNil(CarPlayBrowse.cameraReturn(.none, returnedFor: 5).returnedFor, "подъезд кончился — забыли")
    }
}
