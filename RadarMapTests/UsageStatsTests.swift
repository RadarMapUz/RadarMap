//
//  UsageStatsTests.swift
//  RadarMapTests
//
//  Обезличенный агрегат. Проверяем главным образом то, чего в нём БЫТЬ НЕ
//  ДОЛЖНО: это единственные данные о пользователе, покидающие телефон помимо
//  краудсорса, и обещание из настроек («ни маршрутов, ни координат, ни
//  времени») должно держаться кодом, а не памятью автора.
//

import XCTest
@testable import RadarMap

final class UsageStatsTests: XCTestCase {

    func testEncodedReportCarriesNoLocationOrTime() throws {
        var stats = UsageStats(day: "2026-08-06")
        stats.trips = 3
        stats.kilometres = 42.5
        stats.alerts = 17
        stats.passes = 9
        stats.screens = ["map": 5]
        // Счётчики качества решений обязаны пройти ту же проверку: они новые,
        // и соблазн положить в них «где именно» самый большой.
        stats.limitSource = ["tag": 7, "assumed": 2]
        stats.maneuvers = ["right": 4, "roundabout": 1]
        stats.tripsDropped = ["short": 1, "merged": 2]
        // Охват предупреждений — счётчик о КАМЕРАХ, то есть о местах, куда
        // человек ездит. Именно поэтому наружу уходят только суммы: ни одного
        // идентификатора камеры, ни одной дистанции, ни одного времени.
        stats.alertRecall = ["passed": 49, "warned": 47, "late": 1,
                             "silent": 1, "unused": 4]
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(stats), encoding: .utf8))
        for forbidden in ["lat", "lon", "coordinate", "route", "track",
                          "startedAt", "endedAt", "timestamp", "address"] {
            XCTAssertFalse(json.lowercased().contains(forbidden.lowercased()),
                           "в отчёте не должно быть «\(forbidden)»")
        }
        // Единственная временная метка — календарный день, без часов и минут.
        XCTAssertTrue(json.contains("2026-08-06"))
    }

    func testEmptyReportIsRecognised() {
        var stats = UsageStats(day: "2026-08-06")
        XCTAssertTrue(stats.isEmpty, "приложение не открывали — слать нечего")
        stats.screens = ["map": 1]
        XCTAssertFalse(stats.isEmpty)
    }

    func testEmptyIgnoresFunnelFieldsOnly() {
        var stats = UsageStats(day: "2026-08-06")
        stats.onboarded = true
        stats.locationAuth = "always"
        XCTAssertTrue(stats.isEmpty,
                      "разрешения — это состояние, а не активность: сами по себе отчёта не делают")
    }

    func testTodayIsCalendarDayNotTimestamp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        let date = Date(timeIntervalSince1970: 1_786_000_000)
        let day = UsageStats.today(calendar: calendar, now: date)
        XCTAssertEqual(day.count, 10)
        XCTAssertEqual(day.filter { $0 == "-" }.count, 2)
        // Дважды в один день — одна и та же строка: иначе счётчики дробились бы.
        XCTAssertEqual(day, UsageStats.today(calendar: calendar,
                                             now: date.addingTimeInterval(3600)))
    }

    func testPendingQueueHasACap() {
        var file = UsageStatsFile(current: UsageStats(day: "2026-08-06"))
        for index in 0..<20 {
            file.pending.append(UsageStats(day: "2026-07-\(index + 1)"))
        }
        // Обрезку делает сервис, здесь фиксируем сам факт потолка: статистика
        // недельной давности ничего не решает, а очередь расти вечно не должна.
        XCTAssertLessThanOrEqual(UsageStatsFile.pendingCap, 14)
        XCTAssertGreaterThan(UsageStatsFile.pendingCap, 0)
    }

    func testRoundTripKeepsCounters() throws {
        var stats = UsageStats(day: "2026-08-06")
        stats.trips = 2
        stats.kilometres = 12.3
        stats.screens = ["map": 4, "stats": 1]
        let file = UsageStatsFile(current: stats, pending: [UsageStats(day: "2026-08-05")])
        let decoded = try JSONDecoder().decode(
            UsageStatsFile.self, from: JSONEncoder().encode(file))
        XCTAssertEqual(decoded.current, stats)
        XCTAssertEqual(decoded.pending.map(\.day), ["2026-08-05"])
    }
}
