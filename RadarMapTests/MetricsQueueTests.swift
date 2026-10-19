//
//  MetricsQueueTests.swift
//  RadarMapTests
//
//  Отчёты MetricKit без сети (S26, 20.10): откладываются на диск, не
//  копятся без конца — не больше 20 и не старше недели.
//

import XCTest
@testable import RadarMap

final class MetricsQueueTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MetricsQueue.pending().forEach(MetricsQueue.remove)
    }

    override func tearDown() {
        MetricsQueue.pending().forEach(MetricsQueue.remove)
        super.tearDown()
    }

    func testFailedReportIsKeptAndOldOnesAreDropped() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        MetricsQueue.save(Data("{}".utf8), now: now.addingTimeInterval(-8 * 86_400))
        XCTAssertEqual(MetricsQueue.pending().count, 1, "не ушёл — отложен")
        MetricsQueue.save(Data("{\"a\":1}".utf8), now: now)
        XCTAssertEqual(MetricsQueue.pending().count, 1, "старше недели — долой, свежий — на месте")
    }

    /// В очереди — отчёт без устройства; id ставится при отправке, текущий:
    /// отложенный под прошлым id не свяжет его с новым (ревью S26).
    func testDeviceIsAddedAtSendTime() throws {
        let report = try JSONSerialization.data(withJSONObject: ["kind": "diagnostic", "payload": ["a": 1]])
        XCTAssertFalse(String(decoding: report, as: UTF8.self).contains("device"))
        let body = try XCTUnwrap(MetricsQueue.stamped(report, device: "NEW"))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(parsed["device"] as? String, "NEW")
        XCTAssertEqual(parsed["kind"] as? String, "diagnostic")
        XCTAssertNil(MetricsQueue.stamped(Data("не json".utf8), device: "NEW"))
    }

    /// Что сервер не примет никогда, не откладывается; отвергнутое ТЕЛО (400,
    /// 413…) очередь не держит; «не тот адрес» (404, 405, 403 — откат строки
    /// nginx), сеть и 5xx — повтор, очередь цела.
    func testOutcomesAndCaps() {
        XCTAssertEqual(APIClient.outcome(status: 200), .accepted)
        XCTAssertEqual(APIClient.outcome(status: 400), .rejected(400))
        XCTAssertEqual(APIClient.outcome(status: 413), .rejected(413))
        XCTAssertEqual(APIClient.outcome(status: 422), .rejected(422))
        for status in [404, 405, 403, 421, 429, 408, 500, 503] {
            XCTAssertEqual(APIClient.outcome(status: status), .retry, "\(status)")
        }
        XCTAssertTrue(MetricsQueue.fits(Data(count: 1_500_000), kind: "diagnostic"))
        XCTAssertFalse(MetricsQueue.fits(Data(count: 1_900_000), kind: "diagnostic"), "запас к потолку сервера")
        XCTAssertFalse(MetricsQueue.fits(Data(count: 190_000), kind: "metric"))
    }

    func testQueueIsCapped() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<(MetricsQueue.maxFiles + 5) {
            MetricsQueue.save(Data("{}".utf8), now: now.addingTimeInterval(Double(i)))
        }
        let pending = MetricsQueue.pending()
        XCTAssertEqual(pending.count, MetricsQueue.maxFiles)
        XCTAssertTrue(pending.first?.lastPathComponent.hasPrefix(String(format: "%.0f", now.timeIntervalSince1970 + 5)) == true,
                      "выброшены самые старые")
    }
}
