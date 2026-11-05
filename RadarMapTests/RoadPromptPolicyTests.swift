//
//  RoadPromptPolicyTests.swift
//  RadarMapTests
//
//  Очередь вопросов на ходу (этап 45): один вопрос на экране, камера выше
//  всех, вытесненный возвращается по своему правилу.
//

import XCTest
@testable import RadarMap

final class RoadPromptPolicyTests: XCTestCase {

    private typealias Policy = RoadPromptPolicy
    private typealias Candidate = RoadPromptPolicy.Candidate

    private func decide(_ candidates: [Candidate], covered: Bool = false,
                        standing: Bool = false) -> Policy.Outcome {
        Policy.decide(candidates, covered: covered, standing: standing, minReturn: 5)
    }

    /// Порядок из таблицы дизайнера: своё касание > объезд > вопрос о
    /// проезде > погода > «опаздываю» > «карта по пути».
    func testOrderMatchesTheTable() {
        XCTAssertEqual(Policy.Kind.allCases.sorted(by: >),
                       [.ownTouch, .detour, .passQuestion, .roadWeather, .late, .corridor])
    }

    /// Никогда две сразу: из всех ждущих показан один, старший.
    func testShowsOnlyTheMostImportant() {
        let all = [Candidate(kind: .corridor, id: "c"),
                   Candidate(kind: .passQuestion, id: "q", remaining: 20),
                   Candidate(kind: .late, id: "l", remaining: 30),
                   Candidate(kind: .detour, id: "d", remaining: 20),
                   Candidate(kind: .roadWeather, id: "w", remaining: 15)]
        XCTAssertEqual(decide(all, standing: true).shown?.id, "d")
        XCTAssertEqual(decide(all + [Candidate(kind: .ownTouch, id: "o")], standing: true).shown?.id, "o")
    }

    /// Камера: на экране никого, и никто не снимается — все ждут, отсчёт стоит.
    func testCameraCoversEveryoneAndExpiresNoOne() {
        let all = [Candidate(kind: .ownTouch, id: "o"),
                   Candidate(kind: .passQuestion, id: "q", remaining: 12, preempted: true),
                   Candidate(kind: .corridor, id: "c")]
        let outcome = decide(all, covered: true)
        XCTAssertNil(outcome.shown)
        XCTAssertEqual(outcome.expired, [])
    }

    /// Вытесненный вопрос о проезде возвращается с остатком ≥ 5 с; с меньшим
    /// снимается молча — как молчание, ничего не уходит.
    func testPreemptedQuestionReturnsOnlyWithTimeLeft() {
        let back = Candidate(kind: .passQuestion, id: "q", remaining: 6, preempted: true)
        XCTAssertEqual(decide([back]).shown?.id, "q")
        let gone = Candidate(kind: .passQuestion, id: "q", remaining: 4, preempted: true)
        let outcome = decide([gone])
        XCTAssertNil(outcome.shown)
        XCTAssertEqual(outcome.expired, ["q"])
    }

    /// Порог — для вытесненного; впервые вставший вопрос показывается с
    /// любым остатком (его срок ещё не начинался или начался не у нас).
    func testThresholdAppliesOnlyToPreempted() {
        XCTAssertEqual(decide([Candidate(kind: .roadWeather, id: "w", remaining: 3)]).shown?.id, "w")
    }

    /// Срок вышел целиком — вопрос снят, кто бы он ни был.
    func testZeroLeftExpires() {
        let outcome = decide([Candidate(kind: .detour, id: "d", remaining: 0)])
        XCTAssertNil(outcome.shown)
        XCTAssertEqual(outcome.expired, ["d"])
    }

    /// Объезд, вытесненный камерой, возвращается так же, как вопрос.
    func testDetourComesBackAfterCamera() {
        let detour = Candidate(kind: .detour, id: "d", remaining: 14, preempted: true)
        XCTAssertNil(decide([detour], covered: true).shown)
        XCTAssertEqual(decide([detour]).shown?.id, "d")
    }

    /// Выбор типа, перебитый камерой, не возвращается (тренога уходит по сроку
    /// ReportFlow), и снять его как «молчание» очередь не вправе.
    func testOwnChoiceNeverComesBackAndIsNotExpiredByQueue() {
        let own = Candidate(kind: .ownTouch, id: "o", preempted: true)
        let outcome = decide([own, Candidate(kind: .corridor, id: "c")])
        XCTAssertEqual(outcome.shown?.id, "c")
        XCTAssertEqual(outcome.expired, [])
    }

    /// «Отменить», перебитое камерой, возвращается, пока окно отмены открыто
    /// не меньше порога; меньше — ждёт, но очередь его не снимает.
    func testOwnUndoComesBackWhileWindowIsOpen() {
        let undo = Candidate(kind: .ownTouch, id: "o-sent", remaining: 6, preempted: true)
        XCTAssertNil(decide([undo], covered: true).shown)
        XCTAssertEqual(decide([undo, Candidate(kind: .passQuestion, id: "q", remaining: 20)]).shown?.id, "o-sent")
        let late = Candidate(kind: .ownTouch, id: "o-sent", remaining: 3, preempted: true)
        let outcome = decide([late, Candidate(kind: .passQuestion, id: "q", remaining: 20)])
        XCTAssertEqual(outcome.shown?.id, "q")
        XCTAssertEqual(outcome.expired, [])
        XCTAssertEqual(decide([Candidate(kind: .ownTouch, id: "o-sent", remaining: 0)]).expired, [])
    }

    /// Экран занят ровно тогда, когда оповещение на экране: скрытое кнопкой
    /// «Скрыть» не накрывает выбор типа и «Отменить».
    func testDismissedAlertDoesNotCover() {
        XCTAssertTrue(Policy.cameraCovers(approaching: true, cameraID: 7, dismissedID: nil))
        XCTAssertTrue(Policy.cameraCovers(approaching: true, cameraID: 7, dismissedID: 3))
        XCTAssertFalse(Policy.cameraCovers(approaching: true, cameraID: 7, dismissedID: 7))
        XCTAssertFalse(Policy.cameraCovers(approaching: false, cameraID: 7, dismissedID: nil))
        XCTAssertFalse(Policy.cameraCovers(approaching: true, cameraID: nil, dismissedID: nil))
    }

    /// «Опаздываю», вытесненное на ходу, ждёт следующей остановки.
    func testLateReturnsOnNextStop() {
        let late = Candidate(kind: .late, id: "l", remaining: 20, preempted: true)
        XCTAssertNil(decide([late], standing: false).shown)
        XCTAssertEqual(decide([late], standing: false).expired, [])
        XCTAssertEqual(decide([late], standing: true).shown?.id, "l")
        let short = Candidate(kind: .late, id: "l", remaining: 2, preempted: true)
        XCTAssertEqual(decide([short], standing: true).expired, ["l"])
    }

    /// «Карта по пути» без срока ждёт сколько угодно.
    func testCorridorAlwaysWaits() {
        let corridor = Candidate(kind: .corridor, id: "c", preempted: true)
        let withLate = decide([corridor, Candidate(kind: .late, id: "l", remaining: 30)], standing: true)
        XCTAssertEqual(withLate.shown?.id, "l")
        XCTAssertEqual(withLate.expired, [])
        XCTAssertEqual(decide([corridor]).shown?.id, "c")
    }

    // MARK: - Часы

    /// Время копится только на экране: под камерой отсчёт стоит.
    func testClockStopsWhileHidden() {
        let start = Date(timeIntervalSince1970: 1_000)
        var clock = RoadPromptClock()
        XCTAssertFalse(clock.wasShown)
        clock.show(at: start)
        XCTAssertEqual(clock.deadline(total: 20), start.addingTimeInterval(20))
        clock.hide(at: start.addingTimeInterval(8))
        XCTAssertTrue(clock.preempted)
        XCTAssertNil(clock.deadline(total: 20))
        // Камера стояла 40 секунд — остаток прежний.
        XCTAssertEqual(clock.remaining(total: 20, at: start.addingTimeInterval(48)), 12)
        clock.show(at: start.addingTimeInterval(48))
        XCTAssertEqual(clock.deadline(total: 20), start.addingTimeInterval(60))
        XCTAssertEqual(clock.remaining(total: 20, at: start.addingTimeInterval(58)), 2)
    }

    /// Повторный показ не сбрасывает начало, повторное скрытие — не копит.
    func testClockIsIdempotent() {
        let start = Date(timeIntervalSince1970: 0)
        var clock = RoadPromptClock()
        clock.show(at: start)
        clock.show(at: start.addingTimeInterval(5))
        clock.hide(at: start.addingTimeInterval(10))
        clock.hide(at: start.addingTimeInterval(30))
        XCTAssertEqual(clock.shown(at: start.addingTimeInterval(30)), 10)
    }
}
