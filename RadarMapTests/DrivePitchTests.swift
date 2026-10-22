//
//  DrivePitchTests.swift
//  RadarMapTests
//
//  Наклон камеры поездки (25.D, 21.10): «у Яндекса богато под наклоном».
//  Стоя и ползком (0–10 км/ч) — лёгкий наклон 35° (27.L, 22.10: «наклон в
//  CarPlay есть, а на телефоне нет» — до него стоя было строго сверху); вид
//  сверху (≤ 20°) — только вплотную у развилки; в городе на 15–40 км/ч и
//  дальше — таблица 25.D до AppConfig.engineMapPitchDegrees; горячий телефон
//  и приборка — плоско, как раньше. Переходы — без скачка и без «поклонов» у
//  светофора. Масштаб здесь не проверяется (его ведёт DriveCameraTests и
//  25.A) — кроме того, что узел «ползком» его не сдвинул.
//

import QuartzCore
import XCTest
@testable import RadarMap

final class DrivePitchTests: XCTestCase {

    private typealias Cam = DriveCamera
    private let tashkent = 41.31

    private func frame(_ kmh: Double, turn: Double? = nil, screen: Cam.Screen,
                       pitch: Bool = true) -> Cam.Frame {
        Cam.target(speedKmh: kmh, maneuverDistance: turn, pitchAllowed: pitch, screen: screen,
                   viewHeight: screen == .car ? 382 : 760, latitude: tashkent, carY: { _ in 0.7 })
    }

    func testStandingAndCrawlingAreSlightlyPitched() {
        // Прежний тест закреплял «сверху ≤ 5 км/ч» (25.D). С 27.L стоя — не
        // чертёж: лёгкий наклон, одинаковый в узлах 0, 5 и 10 км/ч на обоих
        // экранах, в пределах 30–38° (перекрёсток впереди ещё крупный).
        XCTAssertGreaterThanOrEqual(Cam.standingPitch, 30)
        XCTAssertLessThanOrEqual(Cam.standingPitch, 38)
        for screen in [Cam.Screen.phone, .car] {
            for kmh in [0.0, 2, 4, 5, 7.5, 10] {
                XCTAssertEqual(frame(kmh, screen: screen).pitchDegrees, Cam.standingPitch,
                               "\(screen) \(kmh) км/ч")
                XCTAssertEqual(Cam.profile(speedKmh: kmh, pitchAllowed: true, screen: screen).pitchDegrees,
                               Cam.standingPitch, "\(screen) \(kmh) км/ч, узел таблицы")
            }
        }
    }

    func testPhoneAndCarAgreeStanding() {
        // Жалоба 22.10 — расхождение экранов: стоя они одинаковы.
        for kmh in [0.0, 5, 10] {
            XCTAssertEqual(frame(kmh, screen: .phone).pitchDegrees, frame(kmh, screen: .car).pitchDegrees)
        }
    }

    func testPitchIsContinuousInSpeed() {
        // Ни одного скачка по скорости: прежний 0 → 30° между 5 и 10 км/ч
        // давал 6°/км/ч — шум GPS на светофоре «кланял» карту.
        for screen in [Cam.Screen.phone, .car] {
            var previous = frame(0, screen: screen).pitchDegrees
            for kmh in stride(from: 0.5, through: 130, by: 0.5) {
                let pitch = frame(kmh, screen: screen).pitchDegrees
                XCTAssertLessThanOrEqual(abs(pitch - previous), 1.0 + 1e-9, "\(screen) \(kmh) км/ч")
                previous = pitch
            }
        }
    }

    func testTownSpeedsArePitched() {
        // Город на 10–40 км/ч — не чертёж сверху (снимки владельца 21.10).
        for screen in [Cam.Screen.phone, .car] {
            for kmh in stride(from: 10.0, through: 40, by: 5) {
                XCTAssertGreaterThanOrEqual(frame(kmh, screen: screen).pitchDegrees, 20,
                                            "\(screen) \(kmh) км/ч")
            }
            XCTAssertGreaterThanOrEqual(frame(30, screen: screen).pitchDegrees, 45, "\(screen) 30 км/ч")
        }
    }

    func testPitchGrowsWithSpeedUpToTheCeiling() {
        for screen in [Cam.Screen.phone, .car] {
            var previous = -1.0
            for kmh in stride(from: 0.0, through: 200, by: 2.5) {
                let pitch = frame(kmh, screen: screen).pitchDegrees
                XCTAssertGreaterThanOrEqual(pitch, previous, "\(screen) \(kmh) км/ч")
                XCTAssertLessThanOrEqual(pitch, AppConfig.engineMapPitchDegrees + 1e-9)
                previous = pitch
            }
            XCTAssertGreaterThanOrEqual(previous, 55, "на трассе — как у Яндекса, 55–60°")
        }
    }

    func testCeilingStaysBelowTheEngineLimit() {
        // 60° — предел MapLibre; выше 58 верх телефона уходит к горизонту.
        XCTAssertGreaterThanOrEqual(AppConfig.engineMapPitchDegrees, 55)
        XCTAssertLessThan(AppConfig.engineMapPitchDegrees, 60)
        XCTAssertLessThanOrEqual(AppConfig.engineOverviewPitchDegrees, AppConfig.engineMapPitchDegrees)
    }

    func testHotPhoneStaysFlat() {
        // Откат: горячий телефон (thermal ≠ .full) — плоская таблица, как до
        // 25.D, и стоя тоже (наклон стоя 27.L — только у холодного).
        for screen in [Cam.Screen.phone, .car] {
            for mode in [PerformanceMode.reduced, .minimal] {
                XCTAssertFalse(CarPlaySurface.car.pitchAllowed(performance: mode))
                XCTAssertEqual(frame(0, screen: screen, pitch: CarPlaySurface.car.pitchAllowed(performance: mode))
                    .pitchDegrees, 0)
            }
            for kmh in stride(from: 0.0, through: 130, by: 10) {
                XCTAssertEqual(frame(kmh, screen: screen, pitch: false).pitchDegrees, 0)
            }
        }
    }

    func testTopDownOnlyRightAtTheManeuver() {
        // Стоя у светофора: развилка далеко — наклон стоя; вплотную (80 м и
        // ближе) — вид развилки сверху; между — плавный спуск, не ступень.
        for screen in [Cam.Screen.phone, .car] {
            XCTAssertEqual(frame(0, turn: 400, screen: screen).pitchDegrees, Cam.standingPitch, "\(screen)")
            XCTAssertEqual(frame(0, turn: 140, screen: screen).pitchDegrees, Cam.standingPitch, "\(screen)")
            for d in [0.0, 30, 60, 80] {
                XCTAssertLessThanOrEqual(frame(0, turn: d, screen: screen).pitchDegrees,
                                         Cam.maneuverPitch + 1e-9, "\(screen) стоя, \(d) м")
            }
            var previous = Cam.maneuverPitch
            for d in stride(from: 80.0, through: 140, by: 1) {
                let pitch = frame(0, turn: d, screen: screen).pitchDegrees
                XCTAssertGreaterThanOrEqual(pitch, previous - 1e-9, "\(screen) \(d) м")
                XCTAssertLessThanOrEqual(pitch - previous, 0.5, "\(screen) \(d) м — спуск, а не ступень")
                previous = pitch
            }
        }
    }

    func testPositionNoiseAtTheLightDoesNotRockTheView() {
        // Стоим в 80–130 м до поворота, позиция дрожит ±5 м: наклон гуляет
        // не больше ±2° (до 27.L спуск 35 → 20° занимал 10 м — вся разница).
        for screen in [Cam.Screen.phone, .car] {
            for d in stride(from: 85.0, through: 125, by: 5) {
                let a = frame(0, turn: d - 5, screen: screen).pitchDegrees
                let b = frame(0, turn: d + 5, screen: screen).pitchDegrees
                XCTAssertLessThanOrEqual(abs(a - b), 4, "\(screen) \(d) м ±5")
            }
        }
    }

    func testStopAndGoDoesNotNodTheMap() {
        // Светофор и пробка: скорость скачет 5 ↔ 12 км/ч каждую секунду.
        // Через Smoother кадр стоит в узкой полосе, без рывков.
        for screen in [Cam.Screen.phone, .car] {
            var smoother = Cam.Smoother()
            let t0 = Date(timeIntervalSince1970: 10_000)
            var shown: [Double] = []
            for i in 0...60 {
                let kmh = i % 2 == 0 ? 5.0 : 12
                let f = smoother.step(toward: frame(kmh, screen: screen), at: t0.addingTimeInterval(Double(i)))
                if i >= 10 { shown.append(f.pitchDegrees) }
            }
            let range = (shown.max() ?? 0) - (shown.min() ?? 0)
            XCTAssertLessThanOrEqual(range, 1.5, "\(screen): наклон гуляет на \(range)°")
            for (a, b) in zip(shown, shown.dropFirst()) {
                XCTAssertLessThanOrEqual(abs(a - b), 1.0, "\(screen) рывок")
            }
        }
    }

    func testMovingOffGlidesIntoThePitch() {
        // Трогаемся: 0 → 40 км/ч за 10 с. Наклон растёт ровно, без скачка у
        // 5 км/ч (прежняя ступень сверху → 30°) и без перелёта.
        for screen in [Cam.Screen.phone, .car] {
            var smoother = Cam.Smoother()
            let t0 = Date(timeIntervalSince1970: 20_000)
            var previous = smoother.step(toward: frame(0, screen: screen), at: t0).pitchDegrees
            XCTAssertEqual(previous, Cam.standingPitch)
            let goal = frame(40, screen: screen).pitchDegrees
            for i in 1...100 {
                let t = Double(i) * 0.25
                let kmh = min(40, t * 4)
                let f = smoother.step(toward: frame(kmh, screen: screen), at: t0.addingTimeInterval(t))
                XCTAssertGreaterThanOrEqual(f.pitchDegrees, previous - 1e-9, "\(screen) \(t) с")
                XCTAssertLessThanOrEqual(f.pitchDegrees - previous, 1.5, "\(screen) \(t) с — рывок")
                XCTAssertLessThanOrEqual(f.pitchDegrees, goal + 1e-9, "\(screen) перелёт")
                previous = f.pitchDegrees
            }
        }
    }

    func testClusterStaysFlat() {
        // Приборка (CarPlaySurface.cluster) — плоско при любом нагреве.
        for mode in [PerformanceMode.full, .reduced, .minimal] {
            let allowed = CarPlaySurface.cluster.pitchAllowed(performance: mode)
            for kmh in [0.0, 5, 10, 40] {
                XCTAssertEqual(frame(kmh, screen: .car, pitch: allowed).pitchDegrees, 0, "\(mode) \(kmh)")
            }
        }
    }

    func testCloseToTheTurnPitchDropsToTheJunctionView() {
        for screen in [Cam.Screen.phone, .car] {
            for kmh in [20.0, 40, 60] {
                for d in [0.0, 40, 80] {
                    XCTAssertLessThanOrEqual(frame(kmh, turn: d, screen: screen).pitchDegrees,
                                             Cam.maneuverPitch + 1e-9, "\(screen) \(kmh) км/ч, \(d) м")
                }
            }
        }
    }

    func testCrawlKnotDoesNotMoveZoomOrCar() {
        // Узлы 5 и 10 км/ч добавлены ради наклона: остальные столбцы на нём лежат
        // на прямой 0…15, и масштаб, обзор и место машины не меняются.
        for screen in [Cam.Screen.phone, .car] {
            let a = Cam.profile(speedKmh: 0, pitchAllowed: true, screen: screen)
            let b = Cam.profile(speedKmh: 15, pitchAllowed: true, screen: screen)
            for kmh in [3.0, 5, 7.5, 10, 12] {
                let p = Cam.profile(speedKmh: kmh, pitchAllowed: true, screen: screen)
                let t = kmh / 15
                XCTAssertEqual(p.lookaheadSeconds, a.lookaheadSeconds + (b.lookaheadSeconds - a.lookaheadSeconds) * t,
                               accuracy: 1e-9, "\(screen) \(kmh)")
                XCTAssertEqual(p.minZoom, a.minZoom + (b.minZoom - a.minZoom) * t, accuracy: 1e-9)
                XCTAssertEqual(p.maxZoom, a.maxZoom + (b.maxZoom - a.maxZoom) * t, accuracy: 1e-9)
                XCTAssertEqual(p.carShare, a.carShare + (b.carShare - a.carShare) * t, accuracy: 1e-9)
            }
        }
    }
}

/// Значок «я» под наклоном (25.D): сверху — прежний плоский поворот; под
/// наклоном — ложится на дорогу долей наклона, с перспективой, чуть крупнее.
final class CursorTiltTests: XCTestCase {

    @MainActor func testTopDownIsThePlainRotation() {
        let t = EngineMapView.Coordinator.cursorTransform(angle: 0.7, pitchDegrees: 0)
        XCTAssertTrue(CATransform3DEqualToTransform(t, CATransform3DMakeRotation(0.7, 0, 0, 1)))
    }

    @MainActor func testPitchedCursorLeansBackWithPerspective() {
        let t = EngineMapView.Coordinator.cursorTransform(angle: 0, pitchDegrees: AppConfig.engineMapPitchDegrees)
        XCTAssertLessThan(t.m34, 0, "перспектива есть")
        // Нос (верх значка) уходит вдаль: точка (0, -10) после преобразования ближе к центру.
        let w = -10 * t.m24 + t.m44
        let y = (-10 * t.m22 + t.m42) / w
        XCTAssertGreaterThan(y, -10 * (1 + AppConfig.engineCursorPitchGrow), "нос не вырос")
        XCTAssertLessThan(abs(y), 10 * (1 + AppConfig.engineCursorPitchGrow))
        // Не блин: высота значка — не меньше 80 % (наклон — доля, а не весь).
        XCTAssertGreaterThan(abs(y) / 10, 0.8)
    }

    func testTiltIsAShareNotTheWholePitch() {
        XCTAssertGreaterThan(AppConfig.engineCursorTiltShare, 0)
        XCTAssertLessThanOrEqual(AppConfig.engineCursorTiltShare, 0.6)
        XCTAssertLessThanOrEqual(AppConfig.engineCursorPitchGrow, 0.2)
    }
}
