//
//  QuietAlertGateTests.swift
//  RadarMapTests
//
//  Тихий фон (26.1): уведомление о камере вне поездки — только с
//  доказательством езды. Дома с дрожанием Wi-Fi — тишина; настоящий подъезд
//  на машине — уведомление; пешком мимо — тишина; одна камера — не чаще окна.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class QuietAlertGateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// Камера на перекрёстке, дом — в 550 м к югу (снимок владельца 21.10).
    private let camera = CLLocationCoordinate2D(latitude: 41.3000, longitude: 69.2800)
    private var home: CLLocationCoordinate2D { offset(camera, north: -550) }

    private func offset(_ c: CLLocationCoordinate2D, north: Double, east: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: c.latitude + north / 111_320,
                               longitude: c.longitude + east / (111_320 * cos(c.latitude * .pi / 180)))
    }

    private func fix(_ c: CLLocationCoordinate2D, accuracy: Double, speedKmh: Double = -1,
                     ago: TimeInterval, speedAccuracyKmh: Double = -1) -> LocationFilter.Fix {
        LocationFilter.Fix(lat: c.latitude, lon: c.longitude, horizontalAccuracy: accuracy,
                           speed: speedKmh < 0 ? -1 : speedKmh / 3.6,
                           speedAccuracy: speedAccuracyKmh < 0 ? -1 : speedAccuracyKmh / 3.6,
                           course: -1, courseAccuracy: -1,
                           timestamp: now.addingTimeInterval(-ago))
    }

    private func situation(fixes: [LocationFilter.Fix] = [],
                           motion: QuietAlertGate.Motion = .unknown,
                           zones: [CLLocationCoordinate2D] = [],
                           lastNotified: Date? = nil,
                           requiresCarLink: Bool = false,
                           carLinked: Bool = false) -> QuietAlertGate.Situation {
        .init(now: now, cameraLat: camera.latitude, cameraLon: camera.longitude, radius: 550,
              fixes: fixes, motion: motion, quietZones: zones, lastNotifiedAt: lastNotified,
              requiresCarLink: requiresCarLink, carLinked: carLinked)
    }

    /// Wi-Fi-координаты дома: скорости нет, точность 65 м, прыжки на 300 м.
    private var homeJitter: [LocationFilter.Fix] {
        [fix(home, accuracy: 65, ago: 200),
         fix(offset(home, north: 300), accuracy: 65, ago: 120),
         fix(offset(home, north: 150, east: 120), accuracy: 65, ago: 5)]
    }

    // MARK: - Дома

    /// Снимок владельца: телефон лежит, CoreMotion «стоим» — тишина.
    func testHomeJitterWithPhoneLyingIsSilent() {
        XCTAssertEqual(QuietAlertGate.decide(situation(fixes: homeJitter, motion: .stationary)),
                       .silence(.standing))
    }

    /// Без CoreMotion (нет разрешения) — у Дома тоже тишина.
    func testHomeJitterWithoutMotionInHomeZoneIsSilent() {
        XCTAssertEqual(QuietAlertGate.decide(situation(fixes: homeJitter, zones: [home])),
                       .silence(.atHomeOrWork))
    }

    /// Дом не задан и не выучен, CoreMotion молчит: дрожание 300 м — не путь.
    func testHomeJitterWithoutAnyContextIsNoProof() {
        XCTAssertEqual(QuietAlertGate.decide(situation(fixes: homeJitter)), .silence(.noProof))
    }

    /// Вход без единого фикса и без CoreMotion — молчим (доказательства нет).
    func testEntryWithNothingKnownIsSilent() {
        XCTAssertEqual(QuietAlertGate.decide(situation()), .silence(.noProof))
    }

    // MARK: - В машине

    /// Настоящий подъезд: CoreMotion видит машину.
    func testCarApproachByMotionNotifies() {
        let approach = [fix(offset(camera, north: -500), accuracy: 30, speedKmh: 50, ago: 2)]
        XCTAssertEqual(QuietAlertGate.decide(situation(fixes: approach, motion: .automotive)), .notify)
        XCTAssertEqual(QuietAlertGate.decide(situation(motion: .automotive)), .notify,
                       "машина по CoreMotion — достаточно и без фикса")
    }

    /// Без CoreMotion: спутниковый фикс одноразового запроса со скоростью машины.
    func testCarApproachByDopplerNotifies() {
        let fixes = [fix(offset(camera, north: -520), accuracy: 10, speedKmh: 55, ago: 3,
                         speedAccuracyKmh: 2)]
        XCTAssertEqual(QuietAlertGate.decide(situation(fixes: fixes)), .notify)
    }

    /// Без CoreMotion и без доплера: два фикса значимых перемещений — 1 км за минуту.
    func testCarApproachByDisplacementNotifies() {
        let fixes = [fix(offset(camera, north: -1500), accuracy: 65, ago: 70),
                     fix(offset(camera, north: -500), accuracy: 65, ago: 10)]
        XCTAssertEqual(QuietAlertGate.decide(situation(fixes: fixes)), .notify)
    }

    /// Отъезд от дома на машине мимо этой камеры — уведомление есть: зона
    /// Дома глушит только тогда, когда машины не видел CoreMotion.
    func testLeavingHomeByCarNotifies() {
        let fixes = [fix(offset(home, north: 50), accuracy: 30, speedKmh: 30, ago: 3)]
        XCTAssertEqual(QuietAlertGate.decide(situation(fixes: fixes, motion: .automotive, zones: [home])),
                       .notify)
    }

    /// Машина на светофоре: последний сэмпл «стоим», машина была минуту назад.
    func testRedLightCountsAsCar() {
        let samples = [QuietAlertGate.MotionSample(start: now.addingTimeInterval(-600), automotive: true),
                       QuietAlertGate.MotionSample(start: now.addingTimeInterval(-40), stationary: true)]
        XCTAssertEqual(QuietAlertGate.motion(from: samples, now: now), .automotive)
    }

    // MARK: - Пешком

    func testWalkingPastIsSilent() {
        let fixes = [fix(offset(camera, north: -400), accuracy: 8, speedKmh: 5, ago: 2)]
        XCTAssertEqual(QuietAlertGate.decide(situation(fixes: fixes, motion: .onFoot)),
                       .silence(.onFoot))
        XCTAssertEqual(QuietAlertGate.decide(situation(fixes: fixes)), .silence(.noProof),
                       "без CoreMotion пешая скорость — не доказательство")
    }

    // MARK: - Повтор, ложный вход, «Только в машине»

    /// Одна камера — не чаще окна, даже если едем.
    func testSameCameraRepeatIsSilent() {
        XCTAssertEqual(QuietAlertGate.decide(situation(motion: .automotive,
                                                       lastNotified: now.addingTimeInterval(-300))),
                       .silence(.repeatCamera))
        XCTAssertEqual(QuietAlertGate.decide(situation(
            motion: .automotive,
            lastNotified: now.addingTimeInterval(-AppConfig.quietAlertRepeatSeconds - 1))), .notify)
    }

    /// Свежий точный фикс в 1,5 км от камеры — система ошиблась со входом.
    func testPreciseFixFarAwayIsFalseEntry() {
        let fixes = [fix(offset(camera, north: -1500), accuracy: 10, speedKmh: 40, ago: 2)]
        XCTAssertEqual(QuietAlertGate.decide(situation(fixes: fixes, motion: .automotive)),
                       .silence(.outsideRegion))
    }

    func testCarOnlyModeNeedsLink() {
        XCTAssertEqual(QuietAlertGate.decide(situation(motion: .automotive, requiresCarLink: true)),
                       .silence(.notInCar))
        XCTAssertEqual(QuietAlertGate.decide(situation(motion: .automotive, requiresCarLink: true,
                                                       carLinked: true)), .notify)
    }

    func testFinalReasons() {
        XCTAssertTrue(QuietAlertGate.Reason.standing.isFinal)
        XCTAssertFalse(QuietAlertGate.Reason.noProof.isFinal, "одноразовый фикс ещё может прийти")
    }

    // MARK: - CoreMotion

    func testMotionSummary() {
        let past = now.addingTimeInterval(-3 * 3600)
        XCTAssertEqual(QuietAlertGate.motion(from: [], now: now), .unknown)
        XCTAssertEqual(QuietAlertGate.motion(
            from: [.init(start: past, stationary: true)], now: now), .stationary,
                       "телефон лежит с утра — один сэмпл многочасовой давности")
        XCTAssertEqual(QuietAlertGate.motion(
            from: [.init(start: past, automotive: true),
                   .init(start: now.addingTimeInterval(-60), walking: true)], now: now), .onFoot,
                       "вышли из машины")
        XCTAssertEqual(QuietAlertGate.motion(
            from: [.init(start: now.addingTimeInterval(-30), automotive: true, confident: false),
                   .init(start: past, stationary: true)], now: now), .stationary,
                       "неуверенная «машина» не считается")
    }

    func testLogPruning() {
        let log = [1: now.addingTimeInterval(-60), 2: now.addingTimeInterval(-AppConfig.quietAlertRepeatSeconds - 5)]
        XCTAssertEqual(Set(QuietAlertGate.pruned(log, now: now).keys), [1])
    }
}
