//
//  ReportDeliveryTests.swift
//  RadarMapTests
//
//  Что происходит с отметкой и голосом водителя после тапа, когда связи нет
//  или ответы приходят не по порядку (ловец багов, 39): досылка не подменяет
//  «последнюю отметку», голос без сети ждёт в очереди, протухшая отметка не
//  пропадает молча.
//

import XCTest
@testable import RadarMap

final class ReportDeliveryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func sent(_ id: Int, at seconds: TimeInterval, kind: ReportKind = .radar) -> ReportGuard.Sent {
        ReportGuard.Sent(kind: kind, latitude: 41.31, longitude: 69.25,
                         at: t0.addingTimeInterval(seconds), serverID: id)
    }

    // MARK: - Последняя своя отметка

    func testQueuedDeliveryNeverReplacesTheLiveReport() {
        // Связь вернулась: ушла старая A из очереди, водитель тут же отметил
        // B. Ответ по A пришёл позже — «Перекрыто» и «Отменить» обязаны
        // остаться у B.
        let b = sent(2, at: 60)
        let a = sent(1, at: 0)
        XCTAssertEqual(ReportGuard.lastAfterDelivery(current: b, delivered: a, isLive: false), b)
        XCTAssertNil(ReportGuard.lastAfterDelivery(current: nil, delivered: a, isLive: false),
                     "досылка не открывает окно уточнения и отзыва")
        XCTAssertEqual(ReportGuard.lastAfterDelivery(current: a, delivered: b, isLive: true), b)
    }

    func testRefineOfferNamesItsOwnPoint() {
        // Уточнение идёт в точку предложения: её id едет в самом предложении,
        // а не берётся из «последней отправленной».
        let offer = sent(42, at: 0)
        XCTAssertEqual(offer.serverID, 42)
        var retyped = offer
        retyped.kind = .tripod
        XCTAssertEqual(retyped.serverID, offer.serverID, "уточнение типа не теряет точку")
    }

    // MARK: - Очередь отметок

    func testExpiredQueuedReportIsSeparatedForAnHonestNotice() {
        let old = PendingReport(kind: "radar", lat: 41.31, lon: 69.25, cls: "",
                                at: t0.addingTimeInterval(-ReportQueue.maxAge(kind: "radar") - 1))
        let fresh = PendingReport(kind: "tripod", lat: 41.32, lon: 69.26, cls: "", at: t0)
        let (send, expired) = ReportQueue.split([old, fresh], now: t0)
        XCTAssertEqual(send, [fresh])
        XCTAssertEqual(expired, [old], "протухшая отметка не уходит, но и не пропадает молча")
    }

    // MARK: - Очередь голосов

    func testSecondVoteAboutTheSamePointReplacesTheFirst() {
        let yes = PendingVote(reportID: 7, value: 1, kind: "pass", at: t0)
        let no = PendingVote(reportID: 7, value: -1, kind: "pass", at: t0.addingTimeInterval(30))
        let other = PendingVote(reportID: 8, value: -1, kind: "", at: t0)
        let queue = VoteQueue.enqueued(no, into: VoteQueue.enqueued(other, into: VoteQueue.enqueued(yes, into: [])))
        XCTAssertEqual(queue, [other, no], "передумал — это не второй голос")
    }

    func testVoteQueueKeepsTheFreshest() {
        var queue: [PendingVote] = []
        for id in 1...(VoteQueue.limit + 3) {
            queue = VoteQueue.enqueued(PendingVote(reportID: id, value: -1, kind: "", at: t0), into: queue)
        }
        XCTAssertEqual(queue.count, VoteQueue.limit)
        XCTAssertEqual(queue.last?.reportID, VoteQueue.limit + 3)
    }

    func testStaleVoteIsDropped() {
        let stale = PendingVote(reportID: 1, value: -1, kind: "pass", at: t0.addingTimeInterval(-VoteQueue.maxAge - 1))
        let fresh = PendingVote(reportID: 2, value: 1, kind: "pass", at: t0.addingTimeInterval(-60))
        let (send, expired) = VoteQueue.split([stale, fresh], now: t0)
        XCTAssertEqual(send, [fresh])
        XCTAssertEqual(expired, [stale], "голос о другой дороге часовой давности не уходит")
    }
}
