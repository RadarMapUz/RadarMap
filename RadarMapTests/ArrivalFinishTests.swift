//
//  ArrivalFinishTests.swift
//  RadarMapTests
//
//  «Вы на месте!» — и поездка закрывается сама: встали у цели или заглушили
//  машину. Поездка 21.10: шесть минут на стоянке у цели, поездка шла, пока
//  её не закрыли рукой.
//

import XCTest
@testable import RadarMap

final class ArrivalFinishTests: XCTestCase {

    private let destination = ArrivalFinish.Point(lat: 41.3000, lon: 69.2800)
    private let arrivedAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// ~1 м по широте в градусах.
    private func north(_ meters: Double, of point: ArrivalFinish.Point) -> ArrivalFinish.Point {
        ArrivalFinish.Point(lat: point.lat + meters / 111_195, lon: point.lon)
    }

    private func situation(after seconds: TimeInterval,
                           lastMovementAfter moved: TimeInterval = 0,
                           speedKmh: Double = 0,
                           here: ArrivalFinish.Point? = nil,
                           metersAway: Double = 20,
                           tripActive: Bool = true,
                           startsByItself: Bool = true,
                           newRoute: Bool = false,
                           arrivalPoint: ArrivalFinish.Point? = nil,
                           carPlayDisconnected: Bool = false) -> ArrivalFinish.Situation {
        var arrival = ArrivalFinish.Arrival(at: arrivedAt, destination: destination,
                                            point: arrivalPoint)
        arrival.carPlayDisconnected = carPlayDisconnected
        return ArrivalFinish.Situation(
            arrival: arrival,
            now: arrivedAt.addingTimeInterval(seconds),
            isTripActive: tripActive,
            startsByItself: startsByItself,
            hasNewRoute: newRoute,
            speedKmh: speedKmh,
            lastMovementAt: arrivedAt.addingTimeInterval(moved),
            here: here ?? north(metersAway, of: destination))
    }

    // MARK: - Закрываем

    /// Ровно случай владельца: приехали, стоим у цели — через полторы минуты
    /// поездка закрыта сама, без кнопки.
    func testParkedAtDestinationLongEnoughFinishes() {
        XCTAssertEqual(ArrivalFinish.decide(situation(after: AppConfig.arrivalAutoFinishSeconds)),
                       .finish(.parked))
        XCTAssertEqual(ArrivalFinish.decide(situation(after: 6 * 60)), .finish(.parked),
                       "шесть минут на стоянке (21.10) — тем более")
    }

    /// Стоим, но ещё мало — ждём, и таймер на остаток: на стоянке фиксов нет.
    func testParkedNotLongEnoughWaitsForTheRest() {
        XCTAssertEqual(ArrivalFinish.decide(situation(after: 30)),
                       .wait(recheckIn: AppConfig.arrivalAutoFinishSeconds - 30))
    }

    /// Отсчёт — от последнего движения после прибытия: докатились до места
    /// за минуту после «Вы прибыли» — полторы минуты считаются оттуда.
    func testCountdownStartsAtTheLastMovement() {
        let s = situation(after: AppConfig.arrivalAutoFinishSeconds + 10, lastMovementAfter: 60)
        XCTAssertEqual(ArrivalFinish.decide(s), .wait(recheckIn: 50),
                       "после движения в 60 с стоим на 50 с меньше срока")
        XCTAssertEqual(ArrivalFinish.decide(situation(after: 60 + AppConfig.arrivalAutoFinishSeconds,
                                                      lastMovementAfter: 60)),
                       .finish(.parked))
    }

    /// Заглушили машину у цели — CarPlay отключился: закрываем сразу, не
    /// дожидаясь полутора минут.
    func testCarPlayDisconnectAfterArrivalFinishes() {
        XCTAssertEqual(ArrivalFinish.decide(situation(after: 10, carPlayDisconnected: true)),
                       .finish(.carPlayDisconnected))
    }

    /// «Проехали финиш по линии» срабатывает до 250 м от точки цели (цель в
    /// глубине квартала): стоянка у точки прибытия — тоже «у цели».
    func testParkedAtTheArrivalPointCountsAsAtDestination() {
        let arrivalPoint = north(230, of: destination)
        let s = situation(after: AppConfig.arrivalAutoFinishSeconds,
                          here: north(10, of: arrivalPoint), arrivalPoint: arrivalPoint)
        XCTAssertEqual(ArrivalFinish.decide(s), .finish(.parked))
    }

    // MARK: - Не закрываем

    /// На ходу — никогда: паркуемся, объезжаем квартал.
    func testMovingNeverFinishes() {
        let s = situation(after: 10 * 60, speedKmh: 12)
        guard case .wait = ArrivalFinish.decide(s) else {
            return XCTFail("на ходу поездка не закрывается")
        }
        let unplugged = situation(after: 10 * 60, speedKmh: 12, carPlayDisconnected: true)
        guard case .wait = ArrivalFinish.decide(unplugged) else {
            return XCTFail("и с отключённым CarPlay на ходу — тоже нет")
        }
    }

    /// Отключили CarPlay, ещё катясь по парковке, — встали, и поездка
    /// закрывается сразу: защёлка держит отключение.
    func testDisconnectWhileRollingFinishesOnceStopped() {
        XCTAssertEqual(ArrivalFinish.decide(situation(after: 40, lastMovementAfter: 35,
                                                      carPlayDisconnected: true)),
                       .finish(.carPlayDisconnected))
    }

    /// Новая цель — едем дальше, прибытие кончилось.
    func testNewRouteDropsTheWatch() {
        XCTAssertEqual(ArrivalFinish.decide(situation(after: 10 * 60, newRoute: true)), .drop)
        XCTAssertEqual(ArrivalFinish.decide(situation(after: 10, newRoute: true, carPlayDisconnected: true)),
                       .drop)
    }

    /// Уехали от цели — это уже обычная поездка (её закроет автостоп).
    func testFarFromDestinationDropsTheWatch() {
        XCTAssertEqual(ArrivalFinish.decide(situation(after: 10 * 60,
                                                      metersAway: AppConfig.arrivalAutoFinishRadiusMeters + 50)),
                       .drop)
        XCTAssertEqual(ArrivalFinish.decide(situation(after: 10 * 60, metersAway: 900,
                                                      carPlayDisconnected: true)),
                       .drop, "заглушили в 900 м от цели — не у цели")
    }

    /// Поездку уже закрыли (рукой, автостопом) — закрывать нечего.
    func testNoTripDropsTheWatch() {
        XCTAssertEqual(ArrivalFinish.decide(situation(after: 10 * 60, tripActive: false)), .drop)
    }

    /// «Ручной»: поездку открывает и закрывает только человек — закрытую
    /// нами поездку там не поднял бы никто, и дорога дальше не записалась бы.
    func testManualStartModeIsLeftToTheDriver() {
        XCTAssertEqual(ArrivalFinish.decide(situation(after: 10 * 60, startsByItself: false)), .drop)
    }

    /// Без позиции «у цели» не доказано — ждём, а не закрываем.
    func testNoPositionWaits() {
        let arrival = ArrivalFinish.Arrival(at: arrivedAt, destination: nil, point: nil)
        let s = ArrivalFinish.Situation(arrival: arrival, now: arrivedAt.addingTimeInterval(600),
                                        isTripActive: true, startsByItself: true, hasNewRoute: false,
                                        speedKmh: 0, lastMovementAt: arrivedAt, here: destination)
        XCTAssertEqual(ArrivalFinish.decide(s), .wait(recheckIn: AppConfig.arrivalAutoFinishRecheckSeconds))
    }

    // MARK: - CoreMotion после закрытия у цели

    /// Закрыли у цели, а мотор работает: «в машине, стоим» — не старт (иначе
    /// поездка поднялась бы тут же, на стоянке); поехали — старт.
    func testAfterArrivalOnlyRealMovementStartsAgain() {
        XCTAssertFalse(MotionService.countsAsDriving(automotive: true, stationary: true,
                                                     lowConfidence: false, needsMovement: true))
        XCTAssertTrue(MotionService.countsAsDriving(automotive: true, stationary: false,
                                                    lowConfidence: false, needsMovement: true))
        XCTAssertTrue(MotionService.countsAsDriving(automotive: true, stationary: true,
                                                    lowConfidence: false, needsMovement: false),
                      "обычные правила: сели в машину — старт и стоя, как раньше")
        XCTAssertFalse(MotionService.countsAsDriving(automotive: true, stationary: false,
                                                     lowConfidence: true, needsMovement: false))
        XCTAssertFalse(MotionService.countsAsDriving(automotive: false, stationary: false,
                                                     lowConfidence: false, needsMovement: false))
    }
}
