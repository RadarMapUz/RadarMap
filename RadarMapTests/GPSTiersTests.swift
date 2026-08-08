//
//  GPSTiersTests.swift
//  RadarMapTests
//
//  Тиры точности GPS: стоянка бьёт близость (но не ближе 150 м к камере),
//  буст схемы — только с крейсера и на холодном телефоне, выход из стоянки
//  мгновенный. Порядок правил — политика, и она закреплена здесь, а не
//  чтением LocationService рядом с живым CLLocationManager.
//

import XCTest
@testable import RadarMap

final class GPSTiersTests: XCTestCase {

    private func situation(nearest: Double = 5000, speed: Double = 60,
                           idle: TimeInterval = 0, sketch: Bool = false,
                           foreground: Bool = true, cold: Bool = true) -> GPSTiers.Situation {
        .init(nearestTargetMeters: nearest, speedKmh: speed, idleSeconds: idle,
              sketchVisible: sketch, isForeground: foreground, thermalIsFull: cold)
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

    /// Буст плавности схемы: только с крейсера, только на переднем плане и
    /// только на холодном телефоне; стоянку не трогает — стоя анимировать нечего.
    func testSketchBoostRules() {
        XCTAssertEqual(GPSTiers.tier(situation(sketch: true)), 1, "крейсер + схема → подъезд")
        XCTAssertEqual(GPSTiers.tier(situation(sketch: true, cold: false)), 2,
                       "в перегрев буст выключен")
        XCTAssertEqual(GPSTiers.tier(situation(sketch: true, foreground: false)), 2,
                       "в фоне глазами на схему не смотрят")
        XCTAssertEqual(GPSTiers.tier(situation(nearest: 5000, speed: 0, idle: 25,
                                               sketch: true)), 3,
                       "стоянка старше буста")
        XCTAssertEqual(GPSTiers.tier(situation(nearest: 900, sketch: true)), 1,
                       "подъезд бустом не трогается — он и так точный")
    }

    /// Одна дефиниция «стою» на тир GPS и стояночное затемнение приборки.
    func testIsStandingSharedDefinition() {
        XCTAssertTrue(GPSTiers.isStanding(speedKmh: 0, idleSeconds: 25))
        XCTAssertFalse(GPSTiers.isStanding(speedKmh: 0, idleSeconds: 15))
        XCTAssertFalse(GPSTiers.isStanding(speedKmh: 10, idleSeconds: 100))
        // Затемнение ждёт дольше GPS (30 с против 20): гаснуть на каждом
        // коротком светофоре — мигать.
        XCTAssertFalse(GPSTiers.isStanding(speedKmh: 0, idleSeconds: 25,
                                           idleAfter: AppConfig.dashboardDimIdleSeconds))
        XCTAssertTrue(GPSTiers.isStanding(speedKmh: 0, idleSeconds: 35,
                                          idleAfter: AppConfig.dashboardDimIdleSeconds))
    }
}
