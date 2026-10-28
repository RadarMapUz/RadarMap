//
//  EngineFramesTests.swift
//  RadarMapTests
//
//  Частота кадров карты — прямо батарея (аудит энергии 19.10: политика не
//  была покрыта тестом вовсе). С 36A частота в поездке — по ситуации:
//  ровный ход реже, поворот/масштаб/развилка/смена режима — полная, вниз с
//  гистерезисом, вверх сразу.
//

import XCTest
@testable import RadarMap

final class EngineFramesTests: XCTestCase {
    private typealias F = EngineFrames

    private func fps(browsing: Bool = false, settled: Bool = false, covered: Bool = false,
                     performance: PerformanceMode = .full, lowPower: Bool = false,
                     driving: Bool = true, steady: Bool = false) -> Int {
        F.framesPerSecond(F.Situation(browsing: browsing, settled: settled, covered: covered,
                                      performance: performance, lowPower: lowPower,
                                      driving: driving, steady: steady))
    }

    // MARK: - Частота по ситуации

    func testFollowingTheCarIsSmoothUntilTheRoadIsProvenSteady() {
        XCTAssertEqual(fps(), AppConfig.engineFollowFPS)
        XCTAssertEqual(fps(driving: false, steady: true), AppConfig.engineFollowFPS,
                       "без поездки ровный ход не снижает частоту")
    }

    func testSteadyDriveDrawsLess() {
        XCTAssertEqual(fps(steady: true), AppConfig.engineSteadyFPS)
        XCTAssertLessThan(AppConfig.engineSteadyFPS, AppConfig.engineFollowFPS)
        XCTAssertGreaterThan(AppConfig.engineSteadyFPS, AppConfig.engineHotFPS,
                             "ровный ход — не горячий телефон: скольжение должно остаться гладким")
    }

    func testHandsOnTheMapGetFullRateUnlessHot() {
        XCTAssertEqual(fps(browsing: true, steady: true), 0)
        XCTAssertEqual(fps(browsing: true, performance: .reduced), AppConfig.engineWarmFPS)
    }

    /// Карта дорисована и стоит — редкий такт при любом режиме (аудит 26.10:
    /// таймер движка будил главный поток 30 раз в секунду при нуле кадров).
    /// Ниже даже горячего телефона, но не ноль: ноль у движка значит «максимум».
    func testSettledMapTicksRarelyInAnyMode() {
        for browsing in [false, true] {
            for performance in [PerformanceMode.full, .reduced, .minimal] {
                for steady in [false, true] {
                    XCTAssertEqual(fps(browsing: browsing, settled: true, performance: performance, steady: steady),
                                   AppConfig.engineSettledFPS)
                }
            }
        }
        XCTAssertGreaterThan(AppConfig.engineSettledFPS, 0)
        XCTAssertLessThan(AppConfig.engineSettledFPS, AppConfig.engineHotFPS)
        XCTAssertEqual(fps(), AppConfig.engineFollowFPS, "движение возвращает обычную частоту")
    }

    /// Прежние режимы — сохранены: окно оповещения и приборка 15, горячий
    /// телефон 15/20, энергосбережение 20 — и ровный ход ниже их не опускает.
    func testCoveredHotAndLowPowerKeepTheirRates() {
        for steady in [false, true] {
            XCTAssertEqual(fps(covered: true, steady: steady), AppConfig.engineHotFPS)
            XCTAssertEqual(fps(performance: .minimal, steady: steady), AppConfig.engineHotFPS)
            XCTAssertEqual(fps(performance: .reduced, steady: steady), AppConfig.engineWarmFPS)
            XCTAssertEqual(fps(lowPower: true, steady: steady), AppConfig.engineWarmFPS)
        }
    }

    // MARK: - «Картинка меняется»

    private func step(zoom: Double = 0, pitch: Double = 0, heading: Double = 0, seconds: Double = 1) -> F.CameraStep {
        F.CameraStep(zoom: zoom, pitch: pitch, heading: heading, seconds: seconds)
    }

    func testStraightRoadWithCourseNoiseIsCalm() {
        XCTAssertFalse(F.cameraBusy(step()))
        XCTAssertFalse(F.cameraBusy(step(heading: 2)), "±2° за фикс — шум курса на прямой")
        XCTAssertFalse(F.cameraBusy(step(zoom: 0.03)), "доводка масштаба на сотые — не смена вида")
        XCTAssertFalse(F.cameraBusy(step(pitch: 1)))
    }

    func testTurnZoomAndPitchAreBusy() {
        XCTAssertTrue(F.cameraBusy(step(heading: 15)), "поворот на перекрёстке")
        XCTAssertTrue(F.cameraBusy(step(zoom: -0.25)), "Smoother догоняет новый масштаб")
        XCTAssertTrue(F.cameraBusy(step(pitch: 8)), "наклон после старта со светофора")
    }

    /// Два шага в один кадр SwiftUI — один фикс, а не «поворот 40°/с».
    func testRateIsNotInflatedByBackToBackSteps() {
        XCTAssertFalse(F.cameraBusy(step(heading: 2, seconds: 0.05)))
        XCTAssertTrue(F.cameraBusy(step(heading: 2, seconds: 0.05)) == F.cameraBusy(step(heading: 2, seconds: 1)))
    }

    func testManeuverWindowFollowsDriveCamera() {
        XCTAssertTrue(F.nearManeuver(meters: 100, speedMps: 0), "ближе нижней границы окна — всегда")
        XCTAssertTrue(F.nearManeuver(meters: 200, speedMps: 14), "50 км/ч × 15 с = 210 м")
        XCTAssertFalse(F.nearManeuver(meters: 300, speedMps: 14))
        XCTAssertTrue(F.nearManeuver(meters: 440, speedMps: 40), "трасса: окно до 450 м")
        XCTAssertFalse(F.nearManeuver(meters: 460, speedMps: 40))
        XCTAssertFalse(F.nearManeuver(meters: nil, speedMps: 14), "нет маршрута — нет развилки")
        XCTAssertFalse(F.nearManeuver(meters: -5, speedMps: 14))
    }

    func testBusySignals() {
        XCTAssertFalse(F.busy(F.Signals(speedMps: 14)))
        XCTAssertTrue(F.busy(F.Signals(cameraBusy: true)))
        XCTAssertTrue(F.busy(F.Signals(entering: true)), "вход в ведение — одна плавная дуга")
        XCTAssertTrue(F.busy(F.Signals(sinceModeChange: 0.5)), "первые секунды после смены режима")
        XCTAssertFalse(F.busy(F.Signals(sinceModeChange: AppConfig.engineSteadyModeSeconds + 0.1)))
        XCTAssertTrue(F.busy(F.Signals(maneuverMeters: 150, speedMps: 14)))
    }

    // MARK: - Гистерезис

    func testDownWithHysteresisUpInstantly() {
        var pace = F.Pace()
        XCTAssertFalse(pace.steady(busy: false, now: 0), "спокойствие ещё не подтверждено")
        XCTAssertFalse(pace.steady(busy: false, now: AppConfig.engineSteadyCalmSeconds - 0.1))
        XCTAssertTrue(pace.steady(busy: false, now: AppConfig.engineSteadyCalmSeconds))
        XCTAssertTrue(pace.steady(busy: false, now: 30))
        XCTAssertFalse(pace.steady(busy: true, now: 30.2), "поворот — полная частота в тот же шаг")
        XCTAssertFalse(pace.steady(busy: false, now: 31), "после поворота — снова выдержка")
        XCTAssertFalse(pace.steady(busy: false, now: 31 + AppConfig.engineSteadyCalmSeconds - 0.1))
        XCTAssertTrue(pace.steady(busy: false, now: 31 + AppConfig.engineSteadyCalmSeconds))
    }

    /// Один шумный фикс посреди прямой сбивает выдержку целиком — частота не
    /// мигает 20/30/20 на каждом шаге.
    func testNoisyStepRestartsTheCalmWindow() {
        var pace = F.Pace()
        _ = pace.steady(busy: false, now: 0)
        XCTAssertTrue(pace.steady(busy: false, now: 5))
        _ = pace.steady(busy: true, now: 6)
        var rates: [Bool] = []
        for t in stride(from: 7.0, through: 12, by: 1) { rates.append(pace.steady(busy: false, now: t)) }
        XCTAssertEqual(rates, [false, false, false, true, true, true])
    }
}
