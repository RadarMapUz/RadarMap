//
//  AlertRecallTests.swift
//  RadarMapTests
//
//  Метрика, которой приложение оценивает само себя, обязана быть честной
//  строже любой другой: ей проще всего врать в свою пользу.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class AlertRecallTests: XCTestCase {

    /// Ничего не было — доли нет. Ноль из нуля это не «ноль процентов»
    /// и не «сто»: об этом просто нечего сказать.
    func testEmptyHasNoShare() {
        let recall = AlertRecall()
        XCTAssertNil(recall.tally().recall)
        XCTAssertTrue(recall.tally().isEmpty)
    }

    /// Предупредили заранее обо всех — сто процентов.
    func testWarnedInAdvanceCountsAsSuccess() {
        var recall = AlertRecall()
        for id in 1...3 {
            recall.noteAlert(cameraID: id, distance: 400)
            recall.notePassed(cameraID: id)
        }
        let tally = recall.tally()
        XCTAssertEqual(tally.passed, 3)
        XCTAssertEqual(tally.warned, 3)
        XCTAssertEqual(tally.recall, 1)
    }

    /// Промолчали — это промах, и он обязан быть виден. Именно ради этой
    /// строки метрика и заведена.
    func testSilenceIsCountedAsAMiss() {
        var recall = AlertRecall()
        recall.notePassed(cameraID: 7)
        let tally = recall.tally()
        XCTAssertEqual(tally.passed, 1)
        XCTAssertEqual(tally.silent, 1)
        XCTAssertEqual(tally.warned, 0)
        XCTAssertEqual(tally.recall, 0)
    }

    /// Предупреждение, впервые прозвучавшее уже в зоне измерения, успехом не
    /// считается: формально сказали, а отпустить газ человек уже не успевает.
    /// Без этого правила метрика показывала бы сто процентов там, где водитель
    /// не получил ничего.
    func testAWarningAtTheCameraItselfIsNotASuccess() {
        var recall = AlertRecall()
        recall.noteAlert(cameraID: 1, distance: 30)
        recall.notePassed(cameraID: 1)
        let tally = recall.tally()
        XCTAssertEqual(tally.late, 1)
        XCTAssertEqual(tally.warned, 0)
        XCTAssertEqual(tally.recall, 0)
    }

    /// Уровни эскалации (2 и 3) звучат вплотную у КАЖДОЙ камеры. Если брать
    /// последнюю дистанцию, поздним окажется любое предупреждение.
    func testEscalationDoesNotSpoilAnEarlyWarning() {
        var recall = AlertRecall()
        recall.noteAlert(cameraID: 1, distance: 400)
        recall.noteAlert(cameraID: 1, distance: 240)
        recall.noteAlert(cameraID: 1, distance: 120)
        recall.notePassed(cameraID: 1)
        XCTAssertEqual(recall.tally().warned, 1)
        XCTAssertEqual(recall.tally().late, 0)
    }

    /// Сказали о камере, мимо которой не проехали: это не ошибка (свернул),
    /// но считается отдельно — рост этого числа и есть «пугает зря».
    func testUnusedWarningsAreCountedApart() {
        var recall = AlertRecall()
        recall.noteAlert(cameraID: 1, distance: 400)
        recall.noteAlert(cameraID: 2, distance: 400)
        recall.notePassed(cameraID: 1)
        let tally = recall.tally()
        XCTAssertEqual(tally.passed, 1)
        XCTAssertEqual(tally.unused, 1)
        // «Впустую» не портит долю охвата: это другой вопрос.
        XCTAssertEqual(tally.recall, 1)
    }

    /// Одна камера, проеханная дважды за поездку, — это одна камера.
    func testPassingTheSameCameraTwiceCountsOnce() {
        var recall = AlertRecall()
        recall.notePassed(cameraID: 5)
        recall.notePassed(cameraID: 5)
        XCTAssertEqual(recall.tally().passed, 1)
    }

    /// Итоги поездок складываются: вопрос «умно ли» решается на сотнях
    /// проездов, а не на одной дороге до работы.
    func testTalliesAccumulate() {
        let first = AlertRecall.Tally(passed: 10, warned: 9, late: 1, silent: 0, unused: 2)
        let second = AlertRecall.Tally(passed: 5, warned: 4, late: 0, silent: 1, unused: 0)
        let total = first + second
        XCTAssertEqual(total.passed, 15)
        XCTAssertEqual(total.warned, 13)
        XCTAssertEqual(total.silent, 1)
        XCTAssertEqual(total.unused, 2)
    }

    func testResetClearsTheTrip() {
        var recall = AlertRecall()
        recall.noteAlert(cameraID: 1, distance: 400)
        recall.notePassed(cameraID: 1)
        recall.reset()
        XCTAssertTrue(recall.tally().isEmpty)
    }
}
