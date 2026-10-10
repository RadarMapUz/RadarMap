//
//  GPSTiersTests.swift
//  RadarMapTests
//
//  Тиры точности GPS: стоянка бьёт близость (но не ближе 150 м к камере),
//  выход из стоянки мгновенный. Порядок правил — политика, и она закреплена здесь, а не
//  чтением LocationService рядом с живым CLLocationManager.
//

import XCTest
@testable import RadarMap

final class GPSTiersTests: XCTestCase {

    private func situation(nearest: Double = 5000, speed: Double = 60,
                           idle: TimeInterval = 0) -> GPSTiers.Situation {
        .init(nearestTargetMeters: nearest, speedKmh: speed, idleSeconds: idle)
    }

    func testBaseTiersByDistance() {
        XCTAssertEqual(GPSTiers.tier(situation(nearest: 300)), 0, "финал: Best")
        XCTAssertEqual(GPSTiers.tier(situation(nearest: 900)), 1, "подъезд")
        XCTAssertEqual(GPSTiers.tier(situation(nearest: 5000)), 2, "крейсер")
    }

    /// Главная правка нагрева: светофор РЯДОМ с камерой (300 м — в Ташкенте
    /// это почти любой перекрёсток) больше не держит Best-GPS всю стоянку.
    func testStandstillRelaxesEvenNearCamera() {
        XCTAssertEqual(GPSTiers.tier(situation(nearest: 300, speed: 0, idle: 25)), 3)
        XCTAssertEqual(GPSTiers.tier(situation(nearest: 900, speed: 1.5, idle: 25)), 3,
                       "ползание в пробке — тоже стоянка")
    }

    /// Предохранитель близости: очередь ползком у самой камеры (зона замера
    /// проезда 80 м + запас) пишет проезд с полной точностью, как и раньше.
    func testQueueAtCameraStaysPrecise() {
        XCTAssertEqual(GPSTiers.tier(situation(nearest: 100, speed: 0, idle: 300)), 0)
        XCTAssertEqual(GPSTiers.tier(situation(nearest: 149, speed: 2, idle: 60)), 0)
    }

    /// Выход мгновенный: первый же фикс с движением возвращает тир по
    /// дистанции — уровни тревоги успевают отработать как обычно.
    func testMovementExitsStandstillInstantly() {
        XCTAssertEqual(GPSTiers.tier(situation(nearest: 300, speed: 20, idle: 0)), 0)
        XCTAssertEqual(GPSTiers.tier(situation(nearest: 5000, speed: 20, idle: 0)), 2)
    }

    /// До выдержки стоянка не считается стоянкой (шумной остановке на
    /// «стоп-линии» не наступает).
    func testIdleThresholdGuardsFlicker() {
        XCTAssertEqual(GPSTiers.tier(situation(nearest: 5000, speed: 0, idle: 10)), 2)
    }

    /// «Стою» — скорость ниже порога дольше GPS-ной выдержки. Затемнение
    /// приборки со своей, более длинной выдержкой ушло вместе со спидометром.
    func testIsStandingDefinition() {
        XCTAssertTrue(GPSTiers.isStanding(speedKmh: 0, idleSeconds: 25))
        XCTAssertFalse(GPSTiers.isStanding(speedKmh: 0, idleSeconds: 15))
        XCTAssertFalse(GPSTiers.isStanding(speedKmh: 10, idleSeconds: 100))
    }


    // MARK: - Энергосбережение (обзор батареи)

    /// Самая дорогая ступень в энергосбережении недоступна.
    func testLowPowerForbidsTheMostExpensiveTier() {
        let atCamera = situation(nearest: 50)
        XCTAssertEqual(GPSTiers.tier(atCamera), 0, "без экономии у камеры — точнее некуда")
        XCTAssertEqual(GPSTiers.tier(atCamera, lowPower: true), 1,
                       "в экономии «Best» уступает десяти метрам")
    }

    /// А самая ДЕШЁВАЯ — доступна, и это главное.
    ///
    /// Прежний код выключал лестницу в энергосбережении целиком, и вместо неё
    /// на всю поездку вставали фиксированные десять метров. На стоянке чип
    /// работал ВДВОЕ точнее, чем без экономии: режим, включённый ради батареи,
    /// запрещал самую большую экономию.
    func testLowPowerKeepsTheCheapestTier() {
        let parked = situation(nearest: 4000, speed: 0, idle: 600)
        XCTAssertEqual(GPSTiers.tier(parked), 3)
        XCTAssertEqual(GPSTiers.tier(parked, lowPower: true), 3,
                       "стоянка обязана оставаться самой дешёвой и в экономии")
    }

    /// Без энергосбережения решение не меняется ни в одном случае.
    func testWithoutLowPowerNothingChanges() {
        for nearest in [30.0, 200, 900, 5000] {
            for speed in [0.0, 40, 90] {
                let s = situation(nearest: nearest, speed: speed,
                                  idle: speed == 0 ? 600 : 0)
                XCTAssertEqual(GPSTiers.tier(s, lowPower: false), GPSTiers.tier(s))
            }
        }
    }
}
