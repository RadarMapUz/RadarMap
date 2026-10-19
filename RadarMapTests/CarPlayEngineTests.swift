//
//  CarPlayEngineTests.swift
//  RadarMapTests
//
//  Наша карта на экране машины: команды от шаблона CarPlay и день/ночь.
//
//  Касаний в окне CarPlay нет — панораму, «+/−» и «к себе» присылает шаблон,
//  и всё, что водитель может сделать с картой в машине, проходит через
//  CarPlayMapModel. Отсюда и тесты: что значит каждая команда при слежении и
//  на свободной карте, и откуда берётся тема (машина старше солнца, человек
//  старше машины).
//

import CoreLocation
import SwiftUI
import XCTest
@testable import RadarMap

@MainActor
final class CarPlayEngineTests: XCTestCase {

    /// Одна модель на класс — как в CarPlayModeTests: освобождение
    /// @MainActor-класса посреди теста роняет рантайм.
    private static let shared = CarPlayMapModel()

    private func model(following: Bool = true) -> CarPlayMapModel {
        let model = Self.shared
        model.setFollowingForTesting(following)
        model.zoomBias = 0
        model.carIsDark = nil
        return model
    }

    func testZoomWhileFollowingShiftsAutoZoomWithinLimits() {
        let model = model()
        let command = model.zoomCommand
        model.zoom(in: true)
        XCTAssertEqual(model.zoomBias, 1)
        XCTAssertEqual(model.zoomCommand, command, "при слежении вид не двигается — меняется автозум")
        for _ in 0..<10 { model.zoom(in: true) }
        XCTAssertEqual(model.zoomBias, AppConfig.carPlayZoomBiasLimit)
        for _ in 0..<20 { model.zoom(in: false) }
        XCTAssertEqual(model.zoomBias, -AppConfig.carPlayZoomBiasLimit)
    }

    func testZoomOnFreeMapMovesTheView() {
        let model = model(following: false)
        let command = model.zoomCommand
        model.zoom(in: false)
        XCTAssertEqual(model.zoomCommand, command + 1)
        XCTAssertEqual(model.zoomDelta, -1)
        XCTAssertEqual(model.zoomBias, 0)
    }

    func testPanReleasesFollowingAndRecenterReturnsIt() {
        let model = model()
        let before = model.panTotal
        model.pan(by: CGSize(width: 30, height: -12))
        model.pan(by: CGSize(width: 5, height: 2))
        XCTAssertEqual(model.panTotal, CGSize(width: before.width + 35, height: before.height - 10),
                       "шаги копятся: два шага между кадрами оба доезжают")
        XCTAssertFalse(model.isFollowing)
        let recenter = model.recenterRequests
        model.recenter()
        XCTAssertTrue(model.isFollowing)
        XCTAssertEqual(model.recenterRequests, recenter + 1)
    }

    func testZeroPanIsNotAGesture() {
        let model = model()
        let before = model.panTotal
        model.pan(by: .zero)
        XCTAssertEqual(model.panTotal, before)
        XCTAssertTrue(model.isFollowing, "пустой сдвиг не уводит карту в осмотр")
    }

    func testCarThemeBeatsSunOnlyInAuto() {
        let model = model()
        // Полдень в Ташкенте: солнце сказало бы «день».
        model.carIsDark = true
        model.refreshDaylight(appearance: .auto, sunDay: true)
        XCTAssertFalse(model.isDaylight, "в «Авто» фары машины старше таблицы восходов")
        model.refreshDaylight(appearance: .light, sunDay: false)
        XCTAssertTrue(model.isDaylight, "ручной выбор старше машины")
        model.carIsDark = false
        model.refreshDaylight(appearance: .dark, sunDay: true)
        XCTAssertFalse(model.isDaylight)
        // Машина молчит — солнце из общего источника.
        model.carIsDark = nil
        model.refreshDaylight(appearance: .auto, sunDay: true)
        XCTAssertTrue(model.isDaylight)
    }

    #if canImport(MapLibre)
    func testMeSitsInTheFreeFieldBelowTheBar() {
        let size = CGSize(width: 800, height: 420)
        let safe = EdgeInsets(top: 60, leading: 0, bottom: 0, trailing: 0)
        let full = 480.0
        let slow = CarPlayEngineLayer.meY(size: size, safe: safe, share: 0.58)
        let fast = CarPlayEngineLayer.meY(size: size, safe: safe, share: 0.74)
        XCTAssertGreaterThan(slow, 72 / full, "ниже бара CarPlay")
        XCTAssertLessThan(fast, (full - 12) / full, "выше нижнего края")
        XCTAssertGreaterThan(slow, 0.5, "впереди видно больше, чем позади")
        XCTAssertGreaterThan(fast, slow, "на скорости машина ниже — дорога впереди длиннее")
    }

    func testDegenerateWindowFallsBackToDefault() {
        XCTAssertEqual(CarPlayEngineLayer.meY(size: .zero, safe: EdgeInsets()), MapViewport.meY)
        let tiny = CarPlayEngineLayer.meY(size: CGSize(width: 300, height: 100), safe: EdgeInsets())
        XCTAssertTrue((0...1).contains(tiny))
    }
    #endif
}

/// Третья зона дока (прибытие) — по ширине экрана, решается без раскладки.
final class CarPlayDockZonesTests: XCTestCase {
    func testRouteZoneFitsOnUsualAndWideScreensOnly() {
        XCTAssertFalse(CarPlayOverlay.fitsRoute(hudWidth: 0), "до первого замера — две зоны")
        XCTAssertFalse(CarPlayOverlay.fitsRoute(hudWidth: 560), "узкий экран — без прибытия")
        XCTAssertTrue(CarPlayOverlay.fitsRoute(hudWidth: 760))
        XCTAssertTrue(CarPlayOverlay.fitsRoute(hudWidth: 1800), "широкий: док упирается в потолок острова")
    }
}
