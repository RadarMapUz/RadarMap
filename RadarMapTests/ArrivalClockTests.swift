//
//  ArrivalClockTests.swift
//  RadarMapTests
//
//  Одни часы прибытия (37): ближайшая минута с удержанием, остаток для машины
//  до той же минуты — и сквозная поездка (движение, шесть минут в пробке,
//  снова движение), где на каждом шаге панель, оценки CarPlay, тело
//  «Поделиться прибытием» и время близких называют одну минуту.
//

import CarPlay
import CoreLocation
import XCTest
@testable import RadarMap

final class ArrivalClockTests: XCTestCase {
    /// 15.01.2027 13:20:00 по Ташкенту — ровно минута.
    private let minute = Date(timeIntervalSince1970: 1_800_001_200)

    func testRoundsToTheNearestMinute() {
        XCTAssertEqual(ArrivalClock.rounded(minute.addingTimeInterval(29)), minute)
        XCTAssertEqual(ArrivalClock.rounded(minute.addingTimeInterval(30)), minute.addingTimeInterval(60))
        XCTAssertEqual(ArrivalClock.rounded(minute.addingTimeInterval(-29)), minute)
        XCTAssertEqual(ArrivalClock.rounded(minute), minute)
    }

    func testNoRouteMeansNoClock() {
        XCTAssertNil(ArrivalClock.next(shown: minute, raw: nil, sameRoute: true))
    }

    /// Сырое время у границы полминуты не мигает 13:20/13:21 на каждом фиксе.
    func testShownMinuteHoldsAtTheHalfMinuteBoundary() {
        var shown = ArrivalClock.next(shown: nil, raw: minute.addingTimeInterval(29), sameRoute: false)
        XCTAssertEqual(shown, minute)
        for offset in [31.0, 29, 33, 27, 35, 30] {
            shown = ArrivalClock.next(shown: shown, raw: minute.addingTimeInterval(offset), sameRoute: true)
            XCTAssertEqual(shown, minute, "+\(offset) с — минута держится")
        }
        shown = ArrivalClock.next(shown: shown, raw: minute.addingTimeInterval(AppConfig.arrivalClockHoldSeconds),
                                  sameRoute: true)
        XCTAssertEqual(shown, minute.addingTimeInterval(60), "ушли дальше удержания — следующая минута")
        shown = ArrivalClock.next(shown: shown, raw: minute.addingTimeInterval(-15), sameRoute: true)
        XCTAssertEqual(shown, minute, "и назад так же")
    }

    func testNewRouteIsNotHeldByTheOldMinute() {
        XCTAssertEqual(ArrivalClock.next(shown: minute, raw: minute.addingTimeInterval(35), sameRoute: false),
                       minute.addingTimeInterval(60))
    }

    func testHoldIsBetweenHalfAMinuteAndAMinute() {
        XCTAssertGreaterThan(AppConfig.arrivalClockHoldSeconds, 30)
        XCTAssertLessThan(AppConfig.arrivalClockHoldSeconds, 60)
        XCTAssertGreaterThan(AppConfig.arrivalClockCarMarginSeconds, 0)
        XCTAssertLessThan(AppConfig.arrivalClockCarMarginSeconds, 30)
    }

    /// Машина прибавляет остаток к своим часам — и при отбрасывании секунд, и
    /// при округлении выходит та же минута, что на телефоне; доля секунды
    /// между расчётом и показом её не сдвигает.
    func testCarSecondsLandOnTheSameMinuteEitherWay() {
        let arrival = minute.addingTimeInterval(25 * 60)
        for lag in [0.0, 0.2, 0.9, 3] {
            for fraction in [0.0, 0.37, 0.999, 17.4] {
                let now = minute.addingTimeInterval(fraction)
                let seen = now.addingTimeInterval(ArrivalClock.secondsUntil(arrival, now: now) + lag)
                XCTAssertEqual(floor(seen.timeIntervalSince1970 / 60) * 60, arrival.timeIntervalSince1970,
                               "отбрасывание: сейчас +\(fraction) с, задержка \(lag) с")
                XCTAssertEqual(ArrivalClock.rounded(seen), arrival, "округление")
            }
        }
        XCTAssertEqual(ArrivalClock.secondsUntil(minute, now: minute.addingTimeInterval(90)),
                       AppConfig.arrivalClockCarMarginSeconds, "минута в прошлом — не отрицательный остаток")
    }

    /// Варианты маршрута в машине (выбор до «Поехали») — то же правило минуты.
    func testCarVariantSecondsFollowTheSameMinute() {
        let now = minute.addingTimeInterval(12)
        let seconds = ArrivalClock.secondsUntil(remaining: 25 * 60 + 20, now: now)
        XCTAssertEqual(ArrivalClock.rounded(now.addingTimeInterval(seconds)), minute.addingTimeInterval(26 * 60))
    }

    /// Экран и сервер пишут «HH:mm» — у времени ровно на минуте не бывает
    /// спора «округлить или отбросить» (сервер отбрасывает, `%H:%M`).
    func testShownTimeMatchesTheServerClock() {
        let arrival = ArrivalClock.rounded(minute.addingTimeInterval(25 * 60 + 31))
        let tashkent = TimeZone(secondsFromGMT: 5 * 3600)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tashkent
        let parts = calendar.dateComponents([.hour, .minute, .second], from: arrival)
        XCTAssertEqual(parts.second, 0)
        XCTAssertEqual(String(format: "%02d:%02d", parts.hour ?? -1, parts.minute ?? -1), "13:46",
                       "13:45:31 — ближайшая минута 13:46, и сервер напишет ровно её")
    }
}

/// Сквозной тест: одна поездка на настоящем RouteService с подменёнными
/// часами — движение, 6 мин стояния в пробке (фиксов нет, только таймер),
/// снова движение. На каждом шаге все потребители читают одну минуту.
@MainActor
final class ArrivalClockFlowTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_001_200 + 17)   // 13:20:17
    private let key = "d3JpdGUta2V5LWZvci1hcnJpdmFsLWNsb2Nr"

    /// Прямая на север, ~10 км, точка через ~100 м; по маршруту 15 минут.
    private let path = (0...100).map {
        CLLocationCoordinate2D(latitude: 41.30 + Double($0) * 0.0009, longitude: 69.24)
    }

    func testOneArrivalForEveryoneThroughAJam() async {
        let route = RouteService()
        var now = start
        route.clock = { now }
        var changes = 0
        route.onArrivalChanged = { changes += 1 }
        await route.seedRoute(name: "Дом", path: path, seconds: 900)
        XCTAssertTrue(route.isActive)
        guard let first = route.arrival else { return XCTFail("маршрут есть — прибытие есть") }
        XCTAssertEqual(first, ArrivalClock.rounded(start.addingTimeInterval(900)), "13:35:17 → 13:35")
        assertEveryoneAgrees(route, now: now)

        // Движение по графику: точка в 9 с — прибытие не мигает.
        let pace = 900.0 / Double(path.count - 1)
        changes = 0
        for index in 1...30 {
            now = start.addingTimeInterval(pace * Double(index))
            route.notePace(speedKmh: 40, at: now)
            route.updateProgress(coordinate: path[index], cameras: [], announce: false, speedKmh: 40)
            assertEveryoneAgrees(route, now: now)
        }
        XCTAssertEqual(route.arrival, first, "по графику — та же минута")
        XCTAssertEqual(changes, 0, "ни одного лишнего сообщения выходам")

        // Пробка: 6 минут стоим, фиксов нет — прибытие ведёт таймер раз в 30 с.
        let jamStart = now
        changes = 0
        for tick in 1...12 {
            now = jamStart.addingTimeInterval(AppConfig.arrivalClockTickSeconds * Double(tick))
            route.notePace(speedKmh: 0, at: now)
            route.refreshArrival()
            assertEveryoneAgrees(route, now: now)
        }
        guard let jammed = route.arrival else { return XCTFail() }
        XCTAssertEqual(jammed.timeIntervalSince(first), 6 * 60, accuracy: 60,
                       "шесть минут стояния — прибытие на шесть минут позже, а не застыло")
        XCTAssertLessThanOrEqual(changes, 12, "не чаще раза в 30 с")
        XCTAssertGreaterThanOrEqual(changes, 5, "минута в минуту")

        // Поехали снова — с того же места, по графику.
        changes = 0
        let moveOn = now
        for (step, index) in (31...45).enumerated() {
            now = moveOn.addingTimeInterval(pace * Double(step + 1))
            route.notePace(speedKmh: 40, at: now)
            route.updateProgress(coordinate: path[index], cameras: [], announce: false, speedKmh: 40)
            assertEveryoneAgrees(route, now: now)
        }
        XCTAssertEqual(route.arrival?.timeIntervalSince(jammed) ?? .infinity, 0, accuracy: 60,
                       "поехали по графику — прибытие держится у минуты пробки")
        route.clear()
        XCTAssertNil(route.arrival, "маршрут снят — часов нет")
        XCTAssertEqual(route.arrivalText, "—")
    }

    /// Каждый выход — тем путём, каким его читает приложение.
    private func assertEveryoneAgrees(_ route: RouteService, now: Date,
                                      file: StaticString = #filePath, line: UInt = #line) {
        guard let arrival = route.arrival else { return XCTFail("прибытия нет", file: file, line: line) }
        XCTAssertEqual(arrival.timeIntervalSince1970.truncatingRemainder(dividingBy: 60), 0,
                       "ровно на минуте", file: file, line: line)
        // Панель поездки, панель маршрута, CarPlay-оверлей и плитка, Siri.
        XCTAssertEqual(route.arrivalText, Formatting.clock(arrival), file: file, line: line)
        // CarPlay: машина прибавляет остаток к своим часам.
        let estimates = CarPlayGuidance.tripEstimates(meters: route.remainingDistance,
                                                      seconds: route.arrivalSeconds(now: now))
        let car = now.addingTimeInterval(estimates.timeRemaining)
        XCTAssertEqual(floor(car.timeIntervalSince1970 / 60) * 60, arrival.timeIntervalSince1970,
                       "машина — та же минута", file: file, line: line)
        // «Поделиться прибытием» — тело запроса.
        let share = EtaShare.payload(write: .secret(key), arrival: arrival,
                                     remainingMeters: route.remainingDistance, status: .driving)
        XCTAssertEqual(share["eta"] as? Double, arrival.timeIntervalSince1970, file: file, line: line)
        // Близкие: маршрут домой, призрак знает другое — уходит время маршрута.
        let context = FamilyShare.Context(isTripActive: true, routeToHome: true, commuteToHome: true,
                                          routeArrival: route.arrival,
                                          ghostArrival: arrival.addingTimeInterval(-7 * 60))
        let family = FamilyShare.payload(write: .secret(key), status: .driving,
                                         arrival: FamilyShare.arrival(context, headingHome: true, now: now),
                                         home: true, name: "Зафар", now: now)
        XCTAssertEqual(family["eta"] as? Double, arrival.timeIntervalSince1970, file: file, line: line)
    }
}
