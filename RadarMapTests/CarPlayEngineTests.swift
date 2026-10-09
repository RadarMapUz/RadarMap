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
        model.isFollowing = following
        model.zoomBias = 0
        model.carIsDark = nil
        return model
    }

    func testZoomWhileFollowingShiftsAutoZoomWithinLimits() {
        let model = model()
        let command = model.zoomCommand
        model.zoom(in: true, engine: true)
        XCTAssertEqual(model.zoomBias, 1)
        XCTAssertEqual(model.zoomCommand, command, "при слежении вид не двигается — меняется автозум")
        for _ in 0..<10 { model.zoom(in: true, engine: true) }
        XCTAssertEqual(model.zoomBias, AppConfig.carPlayZoomBiasLimit)
        for _ in 0..<20 { model.zoom(in: false, engine: true) }
        XCTAssertEqual(model.zoomBias, -AppConfig.carPlayZoomBiasLimit)
    }

    func testZoomOnFreeMapMovesTheView() {
        let model = model(following: false)
        let command = model.zoomCommand
        model.zoom(in: false, engine: true)
        XCTAssertEqual(model.zoomCommand, command + 1)
        XCTAssertEqual(model.zoomDelta, -1)
        XCTAssertEqual(model.zoomBias, 0)
    }

    func testZoomWithoutEngineGoesToMapKitCounters() {
        let model = model()
        let zoomIn = model.zoomInRequests, bias = model.zoomBias
        model.zoom(in: true, engine: false)
        XCTAssertEqual(model.zoomInRequests, zoomIn + 1)
        XCTAssertEqual(model.zoomBias, bias)
    }

    func testPanReleasesFollowingAndRecenterReturnsIt() {
        let model = model()
        let command = model.panCommand
        model.pan(by: CGSize(width: 30, height: -12))
        XCTAssertEqual(model.panCommand, command + 1)
        XCTAssertEqual(model.panTranslation, CGSize(width: 30, height: -12))
        XCTAssertFalse(model.isFollowing)
        let recenter = model.recenterRequests
        model.recenter()
        XCTAssertTrue(model.isFollowing)
        XCTAssertEqual(model.recenterRequests, recenter + 1)
    }

    func testZeroPanIsNotAGesture() {
        let model = model()
        let command = model.panCommand
        model.pan(by: .zero)
        XCTAssertEqual(model.panCommand, command)
        XCTAssertTrue(model.isFollowing, "пустой сдвиг не уводит карту в осмотр")
    }

    func testCarThemeBeatsSunOnlyInAuto() {
        let model = model()
        // Полдень в Ташкенте: солнце сказало бы «день».
        model.carIsDark = true
        model.refreshDaylight(appearance: .auto, coordinate: CLLocationCoordinate2D(latitude: 41.31, longitude: 69.28))
        XCTAssertFalse(model.isDaylight, "в «Авто» фары машины старше таблицы восходов")
        model.refreshDaylight(appearance: .light, coordinate: nil)
        XCTAssertTrue(model.isDaylight, "ручной выбор старше машины")
        model.carIsDark = false
        model.refreshDaylight(appearance: .dark, coordinate: nil)
        XCTAssertFalse(model.isDaylight)
    }

    #if canImport(MapLibre)
    func testMeSitsInTheFreeFieldAboveTheDock() {
        let size = CGSize(width: 800, height: 420)
        let safe = EdgeInsets(top: 60, leading: 0, bottom: 0, trailing: 0)
        let meY = CarPlayEngineLayer.meY(size: size, safe: safe)
        let full = 480.0
        let dockTop = (full - Double(AppConfig.carPlayDockReserve) - 12) / full
        XCTAssertGreaterThan(meY, 72 / full, "ниже бара CarPlay")
        XCTAssertLessThan(meY, dockTop, "выше приборной панели")
        XCTAssertGreaterThan(meY, 0.5, "впереди видно больше, чем позади")
    }

    func testDegenerateWindowFallsBackToDefault() {
        XCTAssertEqual(CarPlayEngineLayer.meY(size: .zero, safe: EdgeInsets()), RoadSketch.meY)
        XCTAssertEqual(CarPlayEngineLayer.meY(size: CGSize(width: 300, height: 100),
                                              safe: EdgeInsets()), RoadSketch.meY)
    }
    #endif
}
