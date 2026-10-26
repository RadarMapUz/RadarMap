//
//  ItogiBudgetTests.swift
//  RadarMapTests
//
//  Бюджеты расчётов «Итогов» 31E (продолжение PerformanceBudgetTests —
//  отдельным файлом, чтобы параллельные ветки не правили одну простыню):
//  экран периода с пробками, путём выше лимита и целью недели, пробки по
//  сырому треку на финише и память своих дорог. Потолки щедрые — ловят
//  регресс в разы, а не проценты.
//

import XCTest
@testable import RadarMap

final class ItogiBudgetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Месяц плотной езды: 50 записей (потолок истории) по 400 точек трека,
    /// с пробками, участками выше лимита и проездами камер; два года дней.
    private func heavyHistory() -> (history: [TripRecord], days: [TripDay]) {
        var history: [TripRecord] = []
        for index in 0..<50 {
            let start = now.addingTimeInterval(-Double(index) * 14 * 3600)
            let track = (0..<400).flatMap { step -> [Double] in
                [41.30 + Double(step) * 0.0003, 69.20 + Double(index % 5) * 0.01, 50]
            }
            let jams = (0..<6).map { j in
                TripJam(lat: 41.30 + Double(j) * 0.01, lon: 69.25, at: start + Double(j) * 300, seconds: 240)
            }
            let runs = (0..<10).map { r in
                OverLimitRun(lat: 41.30 + Double(r) * 0.005, lon: 69.26, at: start + Double(r) * 60,
                             meters: 300, limitKmh: 60, maxKmh: 80)
            }
            let passes = (0..<8).map { p in
                PassedCamera(id: UUID(), cameraID: p, typeRaw: "Стационар радар", location: "Камера \(p)",
                             speedKmh: p % 3 == 0 ? 82 : 55, date: start + Double(p) * 120,
                             lat: 41.31, lon: 69.28, limitKmh: 60)
            }
            history.append(TripRecord(id: start.timeIntervalSince1970, startedAt: start, endedAt: start + 3600,
                                      distanceMeters: 25_000, maxSpeedKmh: 90, passed: passes, track: track,
                                      jams: jams, overLimit: OverLimitTally(knownMeters: 20_000, overMeters: 3000,
                                                                            runs: runs)))
        }
        var days = TripDayBook.rebuilt(from: history)
        for back in 30..<730 {
            var day = TripDay(day: Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(back) * 86_400)))
            day.trips = 2
            day.cleanPasses = 3
            day.overPasses = back % 9 == 0 ? 1 : 0
            days.append(day)
        }
        return (history, days.sorted { $0.day > $1.day })
    }

    func testItogiScreenWithNewCardsBudget() {
        let data = heavyHistory()
        let clock = ContinuousClock()
        let start = clock.now
        for period in [StatsPeriod.week, .month, .week, .month, .day] {
            _ = ItogiScreen.build(days: data.days, history: data.history, period: period, anchor: now, now: now)
        }
        let spent = clock.now - start
        // Пять пересборок экрана (смена периода) — меньше секунды вместе.
        XCTAssertLessThan(spent, .seconds(1), "экран Итогов 31E деградировал: \(spent) на 5 сборок")
    }

    func testJamsAtFinishBudget() {
        // Трасса 300 км: точка каждые 30 м — 10 000 точек, со стоянками.
        let count = 10_000
        let points = (0..<count).map { TrackPoint(lat: 41.0 + Double($0) * 0.00027, lon: 69.0, speedKmh: 60) }
        var times: [Double] = []
        var clockTime = 1_800_000_000.0
        for index in 0..<count {
            // Каждые 50 точек — 10 медленных (пробка), остальные бодро.
            clockTime += index % 50 < 10 ? 40 : 2
            times.append(clockTime)
        }
        let stops: [ClosedRange<Date>] = (0..<5).map { (k: Int) -> ClosedRange<Date> in
            let from = Date(timeIntervalSince1970: 1_800_000_000 + Double(k) * 3000)
            return from...from.addingTimeInterval(600)
        }
        let clock = ContinuousClock()
        let start = clock.now
        _ = TrafficTime.jams(track: points, times: times, stops: stops)
        let spent = clock.now - start
        // Финиш поездки на главном потоке: 50 мс — потолок кадра с запасом.
        XCTAssertLessThan(spent, .milliseconds(50), "пробки на финише: \(spent) на \(count) точек")
    }

    func testRoadMemoryBudget() {
        var cells = RoadCells()
        let track: [(lat: Double, lon: Double)] = (0..<10_000).map { (index: Int) -> (lat: Double, lon: Double) in
            let lat: Double = 41.0 + Double(index) * 0.00027
            let lon: Double = 69.0 + Double(index % 7) * 0.0001
            return (lat, lon)
        }
        let clock = ContinuousClock()
        let start = clock.now
        cells.add(track, on: now)
        let points: [CameraNews.Point] = (0..<3500).map { (id: Int) -> CameraNews.Point in
            CameraNews.Point(id: id, lat: 41.0 + Double(id) * 0.0008, lon: 69.0)
        }
        _ = CameraNews.update(known: Array(0..<3400), current: points, roads: cells, now: now)
        let spent = clock.now - start
        XCTAssertLessThan(spent, .milliseconds(300), "память дорог: \(spent)")
    }
}
