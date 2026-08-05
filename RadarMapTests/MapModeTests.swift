//
//  MapModeTests.swift
//  RadarMapTests
//
//  Правила видимости главного экрана. Раньше это была россыпь `if` по вёрстке,
//  и «что показываем» нельзя было ни прочитать целиком, ни проверить.
//

import XCTest
@testable import RadarMap

final class MapModeTests: XCTestCase {

    func testModeFromState() {
        XCTAssertEqual(MapMode.current(isTripActive: false, hasRoute: false), .idle)
        // Маршрут построен, но не поехали — это ещё выбор цели, а не движение.
        XCTAssertEqual(MapMode.current(isTripActive: false, hasRoute: true), .idle)
        XCTAssertEqual(MapMode.current(isTripActive: true, hasRoute: false), .driving)
        XCTAssertEqual(MapMode.current(isTripActive: true, hasRoute: true), .navigating)
    }

    /// В покое экран про «куда поедем» — и ничего из ездового.
    func testIdleShowsDestinationTools() {
        let mode = MapMode.idle
        XCTAssertTrue(mode.showsQuickDestinations)
        XCTAssertTrue(mode.showsActionBar)
        XCTAssertTrue(mode.showsLegend)
        XCTAssertTrue(mode.showsRoutePanel)
        XCTAssertFalse(mode.showsTripBar)
        XCTAssertFalse(mode.showsReportButton)
        XCTAssertFalse(mode.showsManeuver)
        XCTAssertFalse(mode.followsHeading)
        XCTAssertEqual(mode.focus, .destination)
    }

    /// За рулём справочное и «куда поедем» с экрана уходит.
    func testDrivingHidesPlanningTools() {
        let mode = MapMode.driving
        XCTAssertFalse(mode.showsQuickDestinations)
        XCTAssertFalse(mode.showsActionBar)
        XCTAssertFalse(mode.showsLegend, "легенда типов за рулём — шум")
        XCTAssertTrue(mode.showsTripBar)
        XCTAssertTrue(mode.showsReportButton)
        XCTAssertFalse(mode.showsManeuver, "маршрута нет — поворачивать некуда")
        XCTAssertTrue(mode.followsHeading)
        XCTAssertEqual(mode.focus, .speed)
    }

    /// В навигации главный — манёвр, скорость уходит на второй план.
    func testNavigatingShowsManeuver() {
        let mode = MapMode.navigating
        XCTAssertTrue(mode.showsManeuver)
        XCTAssertTrue(mode.showsTripBar)
        XCTAssertFalse(mode.showsRoutePanel, "панель вариантов — до старта")
        XCTAssertFalse(mode.showsLegend)
        XCTAssertEqual(mode.focus, .maneuver)
    }

    /// Главный элемент ровно один в каждом режиме — на этом держится иерархия.
    func testFocusIsUniquePerMode() {
        let focuses = [MapMode.idle, .driving, .navigating].map(\.focus)
        XCTAssertEqual(Set(focuses).count, focuses.count)
    }
}

// MARK: - Палитра

final class ThemePaletteTests: XCTestCase {

    /// Одна ситуация — один цвет: правило состояния общее для HUD телефона,
    /// панели CarPlay, строк проездов и Итогов.
    func testSpeedLevelFollowsFineTiers() {
        // Лимита нет — оценивать нечего.
        XCTAssertEqual(Theme.speedLevel(speedKmh: 120, limitKmh: nil), .neutral)
        // В пределах допуска.
        XCTAssertEqual(Theme.speedLevel(speedKmh: 60, limitKmh: 60), .normal)
        XCTAssertEqual(Theme.speedLevel(speedKmh: 62, limitKmh: 60), .normal)
        // Выше допуска, но штрафа ещё нет (камеры прощают ~5 км/ч).
        XCTAssertEqual(Theme.speedLevel(speedKmh: 64, limitKmh: 60), .attention)
        // Попали в штрафную ступень.
        XCTAssertEqual(Theme.speedLevel(speedKmh: 67, limitKmh: 60), .alarm)
        XCTAssertEqual(Theme.speedLevel(speedKmh: 120, limitKmh: 60), .alarm)
    }

    func testToleranceIsRespected() {
        // Свой допуск из настроек: 5 км/ч сверх лимита ещё «норма».
        XCTAssertEqual(Theme.speedLevel(speedKmh: 65, limitKmh: 60, tolerance: 5), .normal)
        XCTAssertEqual(Theme.speedLevel(speedKmh: 65, limitKmh: 60, tolerance: 0), .attention)
    }

    /// Цвет типа камеры не должен совпадать с цветом тревоги: иначе красный
    /// маркер читается как «ты нарушаешь». Ровно эта ошибка и была в палитре.
    func testCameraTypeTintIsNotAlarmColor() {
        XCTAssertNotEqual(CameraType.stationaryCamera.tint, Theme.danger)
        XCTAssertNotEqual(CameraType.stationaryRadar.tint, Theme.warning)
        // Исключение — ДТП: это событие, а не характеристика точки.
        XCTAssertEqual(CameraType.accident.tint, Theme.danger)
    }
}
