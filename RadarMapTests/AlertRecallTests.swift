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

    // MARK: - Верная тишина (14.10)

    /// Встречный двойник и поперечная улица: у самой камеры гейт на каждом
    /// годном тике доказал «не наша» — промолчали верно, это не промах, и
    /// долю охвата такая камера не трогает.
    func testProvenSilenceIsNotAMiss() {
        var recall = AlertRecall()
        recall.noteAlert(cameraID: 1, distance: 400)
        recall.notePassed(cameraID: 1)
        recall.notePassed(cameraID: 2)
        for _ in 0..<3 { recall.noteTraverse(cameraID: 2, provenNotOurs: true) }
        let tally = recall.tally()
        XCTAssertEqual(tally.passed, 2, "проехали — география, как и раньше")
        XCTAssertEqual(tally.notOurs, 1)
        XCTAssertEqual(tally.silent, 0)
        XCTAssertEqual(tally.ours, 1)
        XCTAssertEqual(tally.recall, 1)
        XCTAssertEqual(recall.silentIDs, [])
        XCTAssertEqual(recall.notOursIDs, [2])
    }

    /// Один тик без доказательства (камера «наша», позади, коридор) — и
    /// тишина о ней снова промах: исключать из счёта можно только по
    /// доказательству на всём проезде.
    func testOneUnprovenTickMakesItAMissAgain() {
        var recall = AlertRecall()
        recall.notePassed(cameraID: 3)
        recall.noteTraverse(cameraID: 3, provenNotOurs: true)
        recall.noteTraverse(cameraID: 3, provenNotOurs: false)
        recall.noteTraverse(cameraID: 3, provenNotOurs: true)
        XCTAssertEqual(recall.tally().silent, 1)
        XCTAssertEqual(recall.tally().notOurs, 0)
        XCTAssertEqual(recall.silentIDs, [3])
    }

    /// Стояли у камеры без курса — гейты воздержались, доказательства нет:
    /// промах. Воздержание не портит доказательство с других тиков.
    func testAbstainingTicksProveNothing() {
        var recall = AlertRecall()
        recall.notePassed(cameraID: 4)
        recall.noteTraverse(cameraID: 4, provenNotOurs: nil)
        XCTAssertEqual(recall.tally().silent, 1, "только воздержания — тишина остаётся промахом")
        recall.noteTraverse(cameraID: 4, provenNotOurs: true)
        recall.noteTraverse(cameraID: 4, provenNotOurs: nil)
        XCTAssertEqual(recall.tally().notOurs, 1)
    }

    /// На фиксе уровня Wi-Fi курс по земле — шум: «доказательство» гейта по
    /// нему тишину не оправдывает (тик воздерживается), на хорошем — да.
    func testProofOnAPoorFixDoesNotExcuseSilence() {
        let good = AppConfig.courseProofMaxAccuracyMeters
        XCTAssertEqual(AlertRecall.traverseEvidence(.provenAxis, accuracy: good), true)
        XCTAssertEqual(AlertRecall.traverseEvidence(.ours, accuracy: good), false)
        XCTAssertNil(AlertRecall.traverseEvidence(.provenDirection, accuracy: good + 1))
        XCTAssertNil(AlertRecall.traverseEvidence(.unfiltered, accuracy: 5))
    }

    /// Предупредили — это предупреждение, что бы гейт ни сказал на траверзе.
    func testAWarnedCameraStaysWarned() {
        var recall = AlertRecall()
        recall.noteAlert(cameraID: 5, distance: 300)
        recall.notePassed(cameraID: 5)
        recall.noteTraverse(cameraID: 5, provenNotOurs: true)
        let tally = recall.tally()
        XCTAssertEqual(tally.warned, 1)
        XCTAssertEqual(tally.notOurs, 0)
    }

    /// Счёт складывается, старый файл без поля читается нулём, сброс поездки
    /// забывает и доказательства.
    func testNotOursAccumulatesDecodesAndResets() throws {
        let total = AlertRecall.Tally(passed: 3, warned: 1, notOurs: 2)
            + AlertRecall.Tally(passed: 2, warned: 1, silent: 1)
        XCTAssertEqual(total.notOurs, 2)
        XCTAssertEqual(total.ours, 3)
        XCTAssertEqual(try XCTUnwrap(total.recall), 2.0 / 3, accuracy: 1e-9)
        let old = try JSONDecoder().decode(AlertRecall.Tally.self,
                                           from: Data(#"{"passed":4,"warned":3,"silent":1}"#.utf8))
        XCTAssertEqual(old.notOurs, 0)
        XCTAssertEqual(old.ours, 4)

        var recall = AlertRecall()
        recall.notePassed(cameraID: 6)
        recall.noteTraverse(cameraID: 6, provenNotOurs: true)
        recall.reset()
        recall.notePassed(cameraID: 6)
        XCTAssertEqual(recall.tally().silent, 1, "доказательство прошлой поездки не переезжает")
    }

    /// Проезд камеры, о которой молчали, помечается в записи (6.7): экран
    /// проезда поднимает жалобу «не предупредила» наверх. Старые записи без
    /// поля читаются как «не знаем», а не как «молчали».
    func testSilentPassIsMarkedAndOldRecordsAreUnknown() throws {
        var recall = AlertRecall()
        recall.noteAlert(cameraID: 1, distance: 400)
        XCTAssertTrue(recall.wasAlerted(cameraID: 1))
        XCTAssertFalse(recall.wasAlerted(cameraID: 2))

        let old = #"{"id":"6E1D7C9A-8C2B-4A57-9D1E-2F3A4B5C6D7E","cameraID":2,"typeRaw":"Стационар радар","location":"Юнусабад","speedKmh":70,"date":0}"#
        let decoded = try JSONDecoder().decode(PassedCamera.self, from: Data(old.utf8))
        XCTAssertNil(decoded.silent)
    }
}
