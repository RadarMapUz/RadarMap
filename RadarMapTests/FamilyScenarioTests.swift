//
//  FamilyScenarioTests.swift
//  RadarMapTests
//
//  Края «Близкие видят прибытие» (22.4) целиком, через автомат FamilyTrip:
//  пассажир, магазин по дороге домой (склейка), прибытие с автозавершением,
//  таксист после смены («Еду домой»), «каждая поездка», пауза, сеть пропала,
//  закрыли, пока ответ шёл. Сеть и CLLocationManager не нужны: автомат
//  говорит, что отправить, тест проверяет каждое действие.
//

import XCTest
@testable import RadarMap

final class FamilyScenarioTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var mother = FamilyRecipient(name: "Мама", now: Date(timeIntervalSince1970: 1_799_000_000))
    private var father = FamilyRecipient(name: "Папа", mode: .everyTrip, now: Date(timeIntervalSince1970: 1_799_000_000))

    override func setUp() {
        super.setUp()
        mother.linkSentAt = t0
        father.linkSentAt = t0
    }

    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// Поездка с работы домой: призрак знает время.
    private func homeward(_ minutes: Double, arrival: Double = 40, continuation: Bool = false) -> FamilyShare.Context {
        FamilyShare.Context(isTripActive: true, commuteToHome: true, ghostArrival: at(arrival),
                            isContinuation: continuation)
    }

    /// Доставить всё «в пути», что автомат попросил отправить.
    private func deliver(_ actions: [FamilyTrip.Action], into trip: inout FamilyTrip, at now: Date) {
        for case let .drive(id, arrival, home) in actions {
            trip.delivered(id, arrival: arrival, home: home, at: now)
        }
    }

    func testPassengerSendsNothing() {
        var trip = FamilyTrip()
        let circle = FamilyCircle(recipients: [mother, father])
        trip.tripStarted()
        var context = homeward(0)
        context.isPassenger = true
        XCTAssertEqual(trip.update(circle, context: context, now: at(0)), [], "«Я пассажир» — ни одного запроса")
        XCTAssertEqual(trip.tripEnded(.passenger, arrivedHome: true, now: at(30)), [])
    }

    func testPassengerMidTripClosesWhatWasOpen() {
        var trip = FamilyTrip()
        let circle = FamilyCircle(recipients: [mother])
        trip.tripStarted()
        deliver(trip.update(circle, context: homeward(0), now: at(0)), into: &trip, at: at(0))
        XCTAssertEqual(trip.tripEnded(.passenger, arrivedHome: false, now: at(2)),
                       [.close(mother.id, .ended, home: true)])
        XCTAssertNil(trip.holdUntil, "пассажир — не склейка")
    }

    /// Магазин по дороге домой: автостоп у магазина не говорит маме «не в
    /// пути»; склеенная поездка продолжает ту же — без закрытия и без
    /// второго «первого» сообщения, только новое время.
    func testShopOnTheWayHomeKeepsTheStatusContinuous() {
        var trip = FamilyTrip()
        let circle = FamilyCircle(recipients: [mother])
        trip.tripStarted()
        let first = trip.update(circle, context: homeward(0), now: at(0))
        XCTAssertEqual(first, [.drive(mother.id, arrival: at(40), home: true)])
        deliver(first, into: &trip, at: at(0))
        XCTAssertEqual(trip.live, [mother.id])

        XCTAssertEqual(trip.tripEnded(.auto, arrivedHome: false, now: at(15)), [], "у магазина — тишина")
        XCTAssertNotNil(trip.holdUntil)
        XCTAssertEqual(trip.update(circle, context: FamilyShare.Context(), now: at(25)), [],
                       "стоим в магазине — ожидание не вышло")

        trip.tripStarted()
        let resumed = trip.update(circle, context: homeward(35, arrival: 55, continuation: true), now: at(35))
        XCTAssertEqual(resumed, [.drive(mother.id, arrival: at(55), home: true)],
                       "та же поездка: ни «не в пути», ни нового начала — новое время")
        XCTAssertNil(trip.holdUntil)
        deliver(resumed, into: &trip, at: at(35))
        XCTAssertEqual(trip.tripEnded(.auto, arrivedHome: true, now: at(55)),
                       [.close(mother.id, .arrived, home: true)], "«дома»")
    }

    /// Остановка, после которой TripMerge начал новую поездку (уехали
    /// далеко, другой день): прошлая закрыта «не в пути», новая — с нуля.
    func testNotMergedAfterTheStopStartsFresh() {
        var trip = FamilyTrip()
        let circle = FamilyCircle(recipients: [mother])
        trip.tripStarted()
        deliver(trip.update(circle, context: homeward(0), now: at(0)), into: &trip, at: at(0))
        _ = trip.tripEnded(.auto, arrivedHome: false, now: at(15))
        trip.tripStarted()
        let actions = trip.update(circle, context: homeward(30, arrival: 70), now: at(30))
        XCTAssertEqual(actions, [.close(mother.id, .ended, home: true),
                                 .drive(mother.id, arrival: at(70), home: true)])
    }

    func testHoldExpiresIntoNotOnTheWay() {
        var trip = FamilyTrip()
        let circle = FamilyCircle(recipients: [mother])
        trip.tripStarted()
        deliver(trip.update(circle, context: homeward(0), now: at(0)), into: &trip, at: at(0))
        _ = trip.tripEnded(.auto, arrivedHome: false, now: at(15))
        let late = at(15 + AppConfig.familyHoldSeconds / 60 + 1)
        XCTAssertEqual(trip.update(circle, context: FamilyShare.Context(), now: late),
                       [.close(mother.id, .ended, home: true)])
        XCTAssertNil(trip.holdUntil)
    }

    /// Прибытие к цели-Дому: поездку закрыл ArrivalFinish (автостоп у цели) —
    /// «дома», а не ожидание склейки.
    func testArrivalAutoFinishSaysHome() {
        var trip = FamilyTrip()
        let circle = FamilyCircle(recipients: [mother, father])
        trip.tripStarted()
        let context = FamilyShare.Context(isTripActive: true, routeToHome: true, routeArrival: at(25))
        let actions = trip.update(circle, context: context, now: at(0))
        XCTAssertEqual(Set(actions), [.drive(mother.id, arrival: at(25), home: true),
                                      .drive(father.id, arrival: at(25), home: true)])
        deliver(actions, into: &trip, at: at(0))
        let end = trip.tripEnded(.auto, arrivedHome: true, now: at(25))
        XCTAssertEqual(Set(end), [.close(mother.id, .arrived, home: true), .close(father.id, .arrived, home: true)])
        XCTAssertNil(trip.holdUntil)
        XCTAssertTrue(trip.live.isEmpty)
    }

    func testManualStopClosesAtOnce() {
        var trip = FamilyTrip()
        let circle = FamilyCircle(recipients: [mother])
        trip.tripStarted()
        deliver(trip.update(circle, context: homeward(0), now: at(0)), into: &trip, at: at(0))
        XCTAssertEqual(trip.tripEnded(.manual, arrivedHome: false, now: at(5)),
                       [.close(mother.id, .ended, home: true)], "«Стоп» рукой — склейки не будет")
    }

    /// Таксист после смены: призрака нет (AppEnvironment не даёт признаков
    /// дороги в режиме «Работаю водителем»), «Еду домой» — одно касание; без
    /// маршрута — «едет домой» без времени, построил маршрут домой — время.
    func testWorkDriverTapsGoingHome() {
        var trip = FamilyTrip()
        let circle = FamilyCircle(recipients: [mother])
        trip.tripStarted()
        let shift = FamilyShare.Context(isTripActive: true)
        XCTAssertEqual(trip.update(circle, context: shift, now: at(0)), [], "рейсы смены мама не видит")
        trip.goingHome()
        let tapped = trip.update(circle, context: shift, now: at(1))
        XCTAssertEqual(tapped, [.drive(mother.id, arrival: nil, home: true)], "«едет домой», без выдуманного времени")
        deliver(tapped, into: &trip, at: at(1))
        let routed = FamilyShare.Context(isTripActive: true, routeToHome: true, routeArrival: at(30))
        XCTAssertEqual(trip.update(circle, context: routed, now: at(2)),
                       [.drive(mother.id, arrival: at(30), home: true)], "время появилось — сразу")
    }

    func testEveryTripSeesTheShopRideAndHomeModeDoesNot() {
        var trip = FamilyTrip()
        let circle = FamilyCircle(recipients: [mother, father])
        trip.tripStarted()
        let errand = FamilyShare.Context(isTripActive: true, routeArrival: at(12))
        XCTAssertEqual(trip.update(circle, context: errand, now: at(0)),
                       [.drive(father.id, arrival: at(12), home: false)], "в магазин — только «каждая поездка»")
    }

    func testPauseThisTripSurvivesTheMerge() {
        var trip = FamilyTrip()
        let circle = FamilyCircle(recipients: [mother])
        trip.tripStarted()
        deliver(trip.update(circle, context: homeward(0), now: at(0)), into: &trip, at: at(0))
        XCTAssertEqual(trip.pause(), [.close(mother.id, .ended, home: true)])
        XCTAssertEqual(trip.update(circle, context: homeward(1), now: at(1)), [], "пауза — до конца поездки")
        _ = trip.tripEnded(.auto, arrivedHome: false, now: at(10))
        trip.tripStarted()
        XCTAssertEqual(trip.update(circle, context: homeward(20, continuation: true), now: at(20)), [],
                       "склеенная — та же поездка, пауза держится")
        _ = trip.tripEnded(.manual, arrivedHome: false, now: at(30))
        trip.tripStarted()
        XCTAssertEqual(trip.update(circle, context: homeward(60, arrival: 100), now: at(60)),
                       [.drive(mother.id, arrival: at(100), home: true)], "новая поездка — без паузы")
    }

    /// Без сети: «в пути» не дошло — повтор после короткой паузы, а не ждёт
    /// десять минут живости — и не на каждом фиксе (запрос в секунду всю
    /// поездку без сети).
    func testFailedSendIsRetried() {
        var trip = FamilyTrip()
        let circle = FamilyCircle(recipients: [mother])
        trip.tripStarted()
        XCTAssertEqual(trip.update(circle, context: homeward(0), now: at(0)).count, 1)
        XCTAssertEqual(trip.update(circle, context: homeward(0.1), now: at(0.1)), [], "ответ ещё не пришёл")
        trip.failed(mother.id, now: at(0.1))
        XCTAssertEqual(trip.update(circle, context: homeward(0.12), now: at(0.12)), [],
                       "следующий фикс — ещё пауза, не новый запрос")
        let retry = at(0.1).addingTimeInterval(AppConfig.familyRetrySeconds)
        XCTAssertEqual(trip.update(circle, context: homeward(0.5), now: retry),
                       [.drive(mother.id, arrival: at(40), home: true)])
        XCTAssertTrue(trip.live.isEmpty, "не доставлено — капсулы «Видят» нет")
    }

    /// Неудачи подряд — пауза растёт вдвое до предела; доставка её сбрасывает.
    func testRetryBacksOffAndResetsOnDelivery() {
        XCTAssertEqual(FamilyTrip.retryDelay(afterFailures: 1), AppConfig.familyRetrySeconds)
        XCTAssertEqual(FamilyTrip.retryDelay(afterFailures: 2), AppConfig.familyRetrySeconds * 2)
        XCTAssertEqual(FamilyTrip.retryDelay(afterFailures: 50), AppConfig.familyRetryMaxSeconds)
        var trip = FamilyTrip()
        let circle = FamilyCircle(recipients: [mother])
        trip.tripStarted()
        var now = at(0)
        for _ in 0..<3 {
            XCTAssertEqual(trip.update(circle, context: homeward(0), now: now).count, 1)
            trip.failed(mother.id, now: now)
            now = trip.retryAt[mother.id]!
        }
        XCTAssertEqual(trip.failures[mother.id], 3)
        XCTAssertEqual(trip.update(circle, context: homeward(0), now: now).count, 1)
        trip.delivered(mother.id, arrival: at(40), home: true, at: now)
        XCTAssertNil(trip.retryAt[mother.id], "дошло — пауз больше нет")
        XCTAssertNil(trip.failures[mother.id])
    }

    /// Закрыли, пока ответ «в пути» шёл: ссылка не воскресает (правило 12).
    func testCloseWhileInFlightDoesNotRevive() {
        var trip = FamilyTrip()
        let circle = FamilyCircle(recipients: [mother])
        trip.tripStarted()
        let actions = trip.update(circle, context: homeward(0), now: at(0))
        XCTAssertEqual(trip.pause(), [.close(mother.id, .ended, home: true)], "в пути — тоже закрыть")
        deliver(actions, into: &trip, at: at(0.2))
        XCTAssertTrue(trip.live.isEmpty)
    }

    func testDisablingOneRecipientClosesOnlyThem() {
        var trip = FamilyTrip()
        var circle = FamilyCircle(recipients: [mother, father])
        trip.tripStarted()
        deliver(trip.update(circle, context: homeward(0), now: at(0)), into: &trip, at: at(0))
        circle.recipients[1].enabled = false
        XCTAssertEqual(trip.update(circle, context: homeward(1), now: at(1)),
                       [.close(father.id, .ended, home: true)])
        XCTAssertEqual(trip.live, [mother.id])
    }

    func testForgetReturnsWhatWasSentLast() {
        var trip = FamilyTrip()
        let circle = FamilyCircle(recipients: [father])
        trip.tripStarted()
        deliver(trip.update(circle, context: FamilyShare.Context(isTripActive: true), now: at(0)),
                into: &trip, at: at(0))
        XCTAssertFalse(trip.forget(father.id), "последним ушло «не домой»")
        XCTAssertTrue(trip.open.isEmpty)
        XCTAssertTrue(trip.forget(mother.id), "ничего не слали — по умолчанию «домой»")
    }
}
