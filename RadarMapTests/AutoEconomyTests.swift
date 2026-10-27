//
//  AutoEconomyTests.swift
//  RadarMapTests
//
//  Автоэконом (12.3): когда карта урезается ради батареи — и чего он не
//  делает никогда.
//

import XCTest
@testable import RadarMap

final class AutoEconomyTests: XCTestCase {

    func testLowBatteryWithoutChargerSaves() {
        XCTAssertTrue(AutoEconomy.savesBattery(percent: 19, isCharging: false, wasSaving: false))
        XCTAssertFalse(AutoEconomy.savesBattery(percent: 20, isCharging: false, wasSaving: false),
                       "порог — меньше 20 %, ровно 20 — ещё полная карта")
    }

    /// Провод воткнули — карта возвращается сразу, без ожидания порога выхода.
    func testChargerAlwaysRestores() {
        XCTAssertFalse(AutoEconomy.savesBattery(percent: 5, isCharging: true, wasSaving: false))
        XCTAssertFalse(AutoEconomy.savesBattery(percent: 5, isCharging: true, wasSaving: true))
    }

    /// На пороге 19/20 % карта не мигает между двумя видами.
    func testHysteresisKeepsSavingUntilExitThreshold() {
        XCTAssertTrue(AutoEconomy.savesBattery(percent: 21, isCharging: false, wasSaving: true))
        XCTAssertTrue(AutoEconomy.savesBattery(percent: AppConfig.autoEconomyExitPercent - 1,
                                               isCharging: false, wasSaving: true))
        XCTAssertFalse(AutoEconomy.savesBattery(percent: AppConfig.autoEconomyExitPercent,
                                                isCharging: false, wasSaving: true))
        XCTAssertLessThan(AppConfig.autoEconomyEnterPercent, AppConfig.autoEconomyExitPercent)
    }

    /// Симулятор и всё, где заряда не знаем: не знаем — не урезаем.
    func testUnknownBatteryNeverSaves() {
        XCTAssertFalse(AutoEconomy.savesBattery(percent: nil, isCharging: false, wasSaving: true))
    }

    /// Батарея — ступень перегрева: плоско, 20 к/с, без декора. И не выше:
    /// горячий телефон батарея не «улучшает».
    func testBatteryMapsToTheHeatStepAndNeverRelievesHeat() {
        XCTAssertEqual(AutoEconomy.mode(thermal: .full, savingBattery: true), .reduced)
        XCTAssertEqual(AutoEconomy.mode(thermal: .minimal, savingBattery: true), .minimal)
        XCTAssertEqual(AutoEconomy.mode(thermal: .reduced, savingBattery: false), .reduced)
        XCTAssertEqual(AutoEconomy.mode(thermal: .full, savingBattery: false), .full)
    }

    /// Что даёт ступень — тем же механизмом, что перегрев: 2D (наклон только
    /// на .full), 20 к/с в ведении, декор скрыт (`performance != .full`).
    func testEconomyStepIsFlatTwentyFramesNoDecor() {
        let mode = AutoEconomy.mode(thermal: .full, savingBattery: true)
        XCTAssertFalse(CarPlaySurface.car.pitchAllowed(performance: mode), "2D")
        #if canImport(MapLibre)
        XCTAssertEqual(EngineMapView.Coordinator.framesPerSecond(browsing: false, performance: mode,
                                                                 lowPower: false), AppConfig.engineWarmFPS)
        #endif
        XCTAssertTrue((15...20).contains(AppConfig.engineWarmFPS), "15–20 к/с по плану 12.3")
        XCTAssertNotEqual(mode, .full, "декор прячется при performance != .full")
    }

    /// Камера не пропадает ни на одной ступени: бюджет маркеров не ноль.
    func testCamerasNeverVanish() {
        let mode = AutoEconomy.mode(thermal: .full, savingBattery: true)
        XCTAssertGreaterThan(mode.annotationBudget, 0)
        XCTAssertGreaterThan(mode.carPlayAnnotationBudget, 0)
    }

    /// Перегрев объясняет себя сам и старше батареи.
    func testReasonPrefersHeat() {
        XCTAssertEqual(AutoEconomy.reason(thermal: .reduced, savingBattery: true), .heat)
        XCTAssertEqual(AutoEconomy.reason(thermal: .full, savingBattery: true), .battery)
        XCTAssertNil(AutoEconomy.reason(thermal: .full, savingBattery: false))
    }
}
