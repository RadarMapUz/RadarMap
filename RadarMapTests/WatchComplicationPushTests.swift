//
//  WatchComplicationPushTests.swift
//  RadarMapTests
//
//  Толчок циферблату (14.5). Главное — чего НЕ должно быть: толчка на каждом
//  тике или на каждой ступени дистанции, толчка, который часы всё равно не
//  перерисуют (интервал, суточный предел), толчка, когда приложение часов и
//  так на экране или компликации нет на циферблате, — и выбранного бюджета к
//  концу поездки: «в пути» на циферблате после парковки.
//

import XCTest
@testable import RadarMap

final class WatchComplicationPushTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let noon = Date(timeIntervalSince1970: 1_799_971_200 + 43_200)   // 2027-01-15 12:00 UTC
    private let asleep = WatchComplicationPush.Link(complicationEnabled: true, watchAppRunning: false)

    private func key(_ cameraID: Int?, active: Bool = true) -> WatchComplicationPush.Key {
        WatchComplicationPush.key(isTripActive: active, cameraID: cameraID)
    }

    // MARK: - События

    func testOnlyTripEdgesAndAnotherCameraAreEvents() {
        XCTAssertEqual(WatchComplicationPush.event(for: key(1), delivered: nil), .tripEdge,
                       "первый снимок после запуска — как начало поездки")
        XCTAssertEqual(WatchComplicationPush.event(for: key(nil, active: false), delivered: key(1)), .tripEdge)
        XCTAssertEqual(WatchComplicationPush.event(for: key(1), delivered: key(nil, active: false)), .tripEdge)
        XCTAssertEqual(WatchComplicationPush.event(for: key(2), delivered: key(1)), .cameraChanged)
        XCTAssertEqual(WatchComplicationPush.event(for: key(nil), delivered: key(1)), .cameraChanged,
                       "камера позади, впереди пусто")
        XCTAssertEqual(WatchComplicationPush.event(for: key(1), delivered: key(nil)), .cameraChanged)
        XCTAssertNil(WatchComplicationPush.event(for: key(1), delivered: key(1)),
                     "та же камера — ступень дистанции не событие")
        XCTAssertNil(key(5, active: false).cameraID, "вне поездки камеры нет")
    }

    // MARK: - Путь

    func testContextIsEnoughWithoutComplicationOrWithTheAppOnScreen() {
        let ledger = WatchComplicationPush.Ledger()
        let off = WatchComplicationPush.Link(complicationEnabled: false, watchAppRunning: false)
        let running = WatchComplicationPush.Link(complicationEnabled: true, watchAppRunning: true)
        for event in [WatchComplicationPush.Event.tripEdge, .cameraChanged] {
            XCTAssertEqual(WatchComplicationPush.route(event, link: off, ledger: ledger, now: noon,
                                                       calendar: calendar), .context,
                           "компликации нет на активном циферблате — толчок не дойдёт")
            XCTAssertEqual(WatchComplicationPush.route(event, link: running, ledger: ledger, now: noon,
                                                       calendar: calendar), .context,
                           "приложение часов на экране — контекст дойдёт сразу")
        }
    }

    func testTripEdgesBypassIntervalAndCap() {
        var ledger = WatchComplicationPush.Ledger(delivered: key(1), lastAttemptAt: noon.addingTimeInterval(-1),
                                                  day: calendar.startOfDay(for: noon),
                                                  cameraPushes: WatchComplication.maxRoutineReloadsPerDay)
        XCTAssertEqual(WatchComplicationPush.route(.tripEdge, link: asleep, ledger: ledger, now: noon,
                                                   calendar: calendar), .push(.tripEdge))
        ledger.lastAttemptAt = nil
        XCTAssertEqual(WatchComplicationPush.route(.tripEdge, link: asleep, ledger: ledger, now: noon,
                                                   calendar: calendar), .push(.tripEdge))
    }

    func testCameraChangesWaitForTheWatchInterval() {
        let ledger = WatchComplicationPush.recording(.pushed(.tripEdge), key: key(1), ledger: .init(),
                                                     now: noon, calendar: calendar)
        XCTAssertEqual(WatchComplicationPush.route(.cameraChanged, link: asleep, ledger: ledger,
                                                   now: noon.addingTimeInterval(60), calendar: calendar), .later,
                       "часы не перерисуют раньше своего интервала — толчок был бы впустую")
        XCTAssertEqual(WatchComplicationPush.route(.cameraChanged, link: asleep, ledger: ledger,
                                                   now: noon.addingTimeInterval(WatchComplication.minReloadInterval),
                                                   calendar: calendar), .push(.cameraChanged))
        XCTAssertEqual(WatchComplicationPush.route(.cameraChanged, link: asleep, ledger: ledger,
                                                   now: noon.addingTimeInterval(-600), calendar: calendar),
                       .push(.cameraChanged), "часы назад — не повод молчать")
    }

    func testDailyCapMirrorsTheWatch() {
        let ledger = WatchComplicationPush.Ledger(delivered: key(1), lastAttemptAt: nil,
                                                  day: calendar.startOfDay(for: noon),
                                                  cameraPushes: WatchComplication.maxRoutineReloadsPerDay)
        XCTAssertEqual(WatchComplicationPush.route(.cameraChanged, link: asleep, ledger: ledger, now: noon,
                                                   calendar: calendar), .context,
                       "предел часов выбран — до завтра хватит контекста")
        let tomorrow = calendar.startOfDay(for: noon).addingTimeInterval(86_400 + 60)
        XCTAssertEqual(WatchComplicationPush.route(.cameraChanged, link: asleep, ledger: ledger, now: tomorrow,
                                                   calendar: calendar), .push(.cameraChanged))
        let fresh = WatchComplicationPush.recording(.pushed(.cameraChanged), key: key(2), ledger: ledger,
                                                    now: tomorrow, calendar: calendar)
        XCTAssertEqual(fresh.cameraPushes, 1, "счёт суток заново")
    }

    // MARK: - Бюджет

    func testBudgetKeepsAReserveForTripEdges() {
        let reserve = AppConfig.watchComplicationEdgeReserve
        XCTAssertGreaterThan(reserve, 1, "на конец этой поездки и хотя бы начало следующей")
        XCTAssertFalse(WatchComplicationPush.hasBudget(for: .cameraChanged, remaining: reserve))
        XCTAssertTrue(WatchComplicationPush.hasBudget(for: .cameraChanged, remaining: reserve + 1))
        XCTAssertTrue(WatchComplicationPush.hasBudget(for: .tripEdge, remaining: 1))
        XCTAssertFalse(WatchComplicationPush.hasBudget(for: .tripEdge, remaining: 0),
                       "0 — вызов ушёл бы обычным userInfo: в очередь, без пробуждения")
    }

    func testNoBudgetFallsBackToContextAndCountsAsAnAttempt() {
        let ledger = WatchComplicationPush.recording(.noBudget, key: key(2), ledger: .init(), now: noon,
                                                     calendar: calendar)
        XCTAssertEqual(ledger.delivered, key(2), "часы узнают из контекста — событие закрыто")
        XCTAssertNil(WatchComplicationPush.event(for: key(2), delivered: ledger.delivered))
        XCTAssertEqual(ledger.cameraPushes, 0)
        // Бюджет сессии не перечитываем чаще интервала.
        XCTAssertEqual(WatchComplicationPush.route(.cameraChanged, link: asleep, ledger: ledger,
                                                   now: noon.addingTimeInterval(30), calendar: calendar), .later)
    }

    // MARK: - День за рулём

    /// Сервис в миниатюре: тот же порядок, что WatchBridgeService.
    private struct Phone {
        var ledger = WatchComplicationPush.Ledger()
        var budget = 50
        var pushes: [(Date, WatchComplicationPush.Event)] = []

        mutating func send(_ key: WatchComplicationPush.Key, link: WatchComplicationPush.Link, now: Date,
                           calendar: Calendar) {
            guard let event = WatchComplicationPush.event(for: key, delivered: ledger.delivered) else { return }
            switch WatchComplicationPush.route(event, link: link, ledger: ledger, now: now, calendar: calendar) {
            case .later:
                return
            case .context:
                ledger = WatchComplicationPush.recording(.viaContext, key: key, ledger: ledger, now: now,
                                                         calendar: calendar)
            case .push(let event):
                guard WatchComplicationPush.hasBudget(for: event, remaining: budget) else {
                    ledger = WatchComplicationPush.recording(.noBudget, key: key, ledger: ledger, now: now,
                                                             calendar: calendar)
                    return
                }
                budget -= 1
                pushes.append((now, event))
                ledger = WatchComplicationPush.recording(.pushed(event), key: key, ledger: ledger, now: now,
                                                         calendar: calendar)
            }
        }
    }

    /// Три часовые поездки по городу, камера меняется каждые 30 с, тик —
    /// каждую секунду: конец каждой поездки дошёл толчком, толчки о камере
    /// не чаще интервала часов, бюджет системы не превышен.
    func testThreeCityTripsKeepEveryTripEnd() {
        var phone = Phone()
        var now = noon.addingTimeInterval(-6 * 3600)   // 06:00
        var tripEnds = 0
        for _ in 0..<3 {
            for second in 0..<3600 {
                now = now.addingTimeInterval(1)
                phone.send(key(second / 30), link: asleep, now: now, calendar: calendar)
            }
            now = now.addingTimeInterval(1)
            let before = phone.pushes.count
            phone.send(key(nil, active: false), link: asleep, now: now, calendar: calendar)
            if phone.pushes.count == before + 1, phone.pushes.last?.1 == .tripEdge { tripEnds += 1 }
            now = now.addingTimeInterval(3600)
        }
        XCTAssertEqual(tripEnds, 3, "конец каждой поездки — толчком, бюджет его дождался")
        XCTAssertLessThanOrEqual(phone.pushes.count, 50)
        XCTAssertGreaterThanOrEqual(phone.budget, 0)
        let camera = phone.pushes.filter { $0.1 == .cameraChanged }.map(\.0)
        XCTAssertGreaterThan(camera.count, 0)
        XCTAssertLessThanOrEqual(camera.count, WatchComplication.maxRoutineReloadsPerDay)
        for (a, b) in zip(camera, camera.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.timeIntervalSince(a), WatchComplication.minReloadInterval)
        }
    }

    /// Смена, придержанная интервалом, уходит позже — и стоя на светофоре,
    /// без новых событий; ступени дистанции толчков не дают.
    func testHeldChangeIsPushedLaterWithoutNewEvents() {
        var phone = Phone()
        phone.send(key(1), link: asleep, now: noon, calendar: calendar)                    // начало
        phone.send(key(2), link: asleep, now: noon.addingTimeInterval(30), calendar: calendar)
        XCTAssertEqual(phone.pushes.count, 1, "через 30 с — ждёт")
        for second in stride(from: 31, through: 300, by: 1) {
            phone.send(key(2), link: asleep, now: noon.addingTimeInterval(TimeInterval(second)), calendar: calendar)
        }
        XCTAssertEqual(phone.pushes.map(\.1), [.tripEdge, .cameraChanged])
        XCTAssertEqual(phone.pushes[1].0, noon.addingTimeInterval(WatchComplication.minReloadInterval))
    }

    func testAppOnScreenClosesTheEventWithoutSpending() {
        var phone = Phone()
        let running = WatchComplicationPush.Link(complicationEnabled: true, watchAppRunning: true)
        phone.send(key(1), link: running, now: noon, calendar: calendar)
        phone.send(key(2), link: running, now: noon.addingTimeInterval(200), calendar: calendar)
        XCTAssertTrue(phone.pushes.isEmpty)
        XCTAssertEqual(phone.budget, 50)
        // Приложение ушло с экрана — следующая камера уже толчком.
        phone.send(key(3), link: asleep, now: noon.addingTimeInterval(400), calendar: calendar)
        XCTAssertEqual(phone.pushes.map(\.1), [.cameraChanged])
    }
}
