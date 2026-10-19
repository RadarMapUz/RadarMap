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
