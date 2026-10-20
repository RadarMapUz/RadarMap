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
        let data = try JSONEncoder().encode(stats)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        // Проверяем ИМЕНА полей, а не буквы в документе. Прежде здесь искалась
        // подстрока, и «lat» находилась в ключе «late» — охват предупреждений,
        // никакой не широты. Поиск по подстроке ловил бы и «platform», и
        // «translate», а настоящую утечку с именем «где» — ровно так же, как
        // ловит проверка ниже. То есть шумел, не добавляя строгости.
        let tree = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in Self.allKeys(of: tree) {
            XCTAssertFalse(Self.forbiddenKeys.contains(key.lowercased()),
                           "в отчёте не должно быть поля «\(key)»")
        }

        // Вторая сеть, и она надёжнее списка запретов: утечку принесёт НОВОЕ
        // поле, а не поле с заранее известным дурным именем. Поэтому набор
        // полей верхнего уровня закреплён — добавили своё, тест упал, и о
        // приватности пришлось подумать до отправки, а не после.
        XCTAssertEqual(Set(tree.keys), Self.expectedTopLevelKeys,
                       "состав отчёта изменился — проверьте, что новое поле "
                       + "не рассказывает, где человек был и когда")

        // Ни одна строка в отчёте не должна выглядеть числом с точкой:
        // координату иначе как строкой или дробью не передать.
        for value in Self.allStringValues(of: tree) where value != "2026-08-06" {
            XCTAssertNil(Double(value), "строка «\(value)» похожа на число")
        }

        // Единственная временная метка — календарный день, без часов и минут.
        XCTAssertTrue(json.contains("2026-08-06"))
    }

    /// Имена, которых в обезличенном отчёте быть не может ни на каком уровне.
    private static let forbiddenKeys: Set<String> = [
        "lat", "latitude", "lon", "lng", "long", "longitude",
        "coord", "coords", "coordinate", "coordinates", "location",
        "position", "place", "address", "geo", "point", "points",
        "route", "track", "path", "trace", "polyline",
        "startedat", "endedat", "timestamp", "time", "at", "when",
        "cameraid", "cameraids", "tripid", "deviceid", "id",
    ]

    /// Состав отчёта на сегодня. Список ведётся руками намеренно.
    private static let expectedTopLevelKeys: Set<String> = [
        "day", "onboarded", "locationAuth", "notificationsAllowed",
        "trips", "kilometres", "alerts", "passes", "reports", "screens",
        "limitSource", "maneuvers", "tripsDropped", "alertRecall", "voiced",
        "memoryWarnings",
    ]

    nonisolated private static func allKeys(of value: Any) -> [String] {
        switch value {
        case let map as [String: Any]:
            return Array(map.keys) + map.values.flatMap(allKeys(of:))
        case let list as [Any]:
            return list.flatMap(allKeys(of:))
        default:
            return []
        }
    }

    nonisolated private static func allStringValues(of value: Any) -> [String] {
        switch value {
        case let map as [String: Any]:
            return map.values.flatMap(allStringValues(of:))
        case let list as [Any]:
            return list.flatMap(allStringValues(of:))
        case let text as String:
            return [text]
        default:
            return []
        }
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
