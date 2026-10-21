//
//  CarPlayClusterTests.swift
//  RadarMapTests
//
//  Приборка (25.H2): что машина разрешила рисовать, когда в окне кластера
//  живёт карта и чем приборка легче экрана машины.
//

import CarPlay
import XCTest
@testable import RadarMap

final class CarPlayClusterTests: XCTestCase {

    private typealias Cluster = CarPlayCluster

    // MARK: - Знак лимита и компас — по слову машины

    func testCarThatDrawsItsOwnLimitGetsNoSecondSign() {
        // Два знака рядом читаются как два разных лимита.
        XCTAssertFalse(Cluster.drawsSpeedLimit(.disabled, limitsEnabled: true))
    }

    func testLimitFollowsTheAppSettingOtherwise() {
        for setting: Cluster.Setting in [.enabled, .unspecified, .userPreference] {
            XCTAssertTrue(Cluster.drawsSpeedLimit(setting, limitsEnabled: true), "\(setting)")
            XCTAssertFalse(Cluster.drawsSpeedLimit(setting, limitsEnabled: false),
                           "выключенные лимиты не появляются и на приборке: \(setting)")
        }
    }

    func testCompassOnlyWhenTheCarAsks() {
        XCTAssertTrue(Cluster.drawsCompass(.enabled))
        for setting: Cluster.Setting in [.disabled, .unspecified, .userPreference] {
            XCTAssertFalse(Cluster.drawsCompass(setting), "\(setting)")
        }
    }

    func testCarPlaySettingMapsOneToOne() {
        XCTAssertEqual(Cluster.Setting(CPInstrumentClusterSetting.enabled), .enabled)
        XCTAssertEqual(Cluster.Setting(CPInstrumentClusterSetting.disabled), .disabled)
        XCTAssertEqual(Cluster.Setting(CPInstrumentClusterSetting.userPreference), .userPreference)
        XCTAssertEqual(Cluster.Setting(CPInstrumentClusterSetting.unspecified), .unspecified)
    }

    // MARK: - Когда в окне живёт карта

    func testContentOnlyInAVisibleWindowOfAnActiveApp() {
        XCTAssertTrue(Cluster.installsContent(windowConnected: true, onScreen: true, appInBackground: false))
        XCTAssertFalse(Cluster.installsContent(windowConnected: false, onScreen: true, appInBackground: false),
                       "окна нет — ставить некуда")
        XCTAssertFalse(Cluster.installsContent(windowConnected: true, onScreen: false, appInBackground: false),
                       "приборку переключили на приборы машины — карту никто не видит")
        XCTAssertFalse(Cluster.installsContent(windowConnected: true, onScreen: true, appInBackground: true),
                       "MapLibre, созданный в фоне, стартует спящим")
    }

    func testHotPhoneDropsTheClusterMapFirst() {
        XCTAssertTrue(Cluster.showsMap(onScreen: true, performance: .full))
        XCTAssertTrue(Cluster.showsMap(onScreen: true, performance: .reduced))
        XCTAssertFalse(Cluster.showsMap(onScreen: true, performance: .minimal))
        XCTAssertFalse(Cluster.showsMap(onScreen: false, performance: .full))
    }

    func testInactiveDescriptionPromisesWarningsOnlyOnATrip() {
        let trip = Cluster.inactiveDescription(tripActive: true)
        let idle = Cluster.inactiveDescription(tripActive: false)
        for variants in [trip, idle] {
            XCTAssertFalse(variants.isEmpty)
            XCTAssertFalse(variants.contains(where: \.isEmpty))
            // От длинной к короткой: машина берёт первую, что влезает.
            XCTAssertEqual(variants.map(\.count), variants.map(\.count).sorted(by: >))
        }
        let warns = String(localized: "Предупреждаю о камерах")
        XCTAssertTrue(trip.contains(warns))
        XCTAssertFalse(idle.contains { $0.localizedCaseInsensitiveContains(warns) },
                       "без поездки не обещаем предупреждений")
    }

    // MARK: - Приборка легче экрана машины

    func testClusterIsFlatHouselessDeclutteredAndSlow() {
        let cluster = CarPlaySurface.cluster
        for mode: PerformanceMode in [.full, .reduced, .minimal] {
            XCTAssertFalse(cluster.pitchAllowed(performance: mode), "наклон тянет тайлы у горизонта")
        }
        XCTAssertFalse(cluster.houses(setting: true))
        XCTAssertTrue(cluster.alwaysDeclutter)
        XCTAssertTrue(cluster.lowFrameRate)
        XCTAssertFalse(cluster.interactive, "у приборки нет «к себе»")
        XCTAssertEqual(cluster.healthTag, "приборка")
        XCTAssertEqual(cluster.fixedMeY, AppConfig.carPlayClusterMeY)
    }

    func testCarAndDashboardKeepTheirBehaviour() {
        // Экран машины: наклон и дома — как до 25.H2.
        XCTAssertTrue(CarPlaySurface.car.pitchAllowed(performance: .full))
        XCTAssertFalse(CarPlaySurface.car.pitchAllowed(performance: .reduced), "горячий телефон — плоско")
        XCTAssertTrue(CarPlaySurface.car.houses(setting: true))
        XCTAssertFalse(CarPlaySurface.car.houses(setting: false))
        XCTAssertTrue(CarPlaySurface.car.interactive)
        XCTAssertFalse(CarPlaySurface.car.lowFrameRate)
        XCTAssertFalse(CarPlaySurface.car.alwaysDeclutter)
        XCTAssertNil(CarPlaySurface.car.fixedMeY)
        XCTAssertEqual(CarPlaySurface.car.healthTag, "машина")
        // Плитка — только взгляд, «я» на своей доле.
        XCTAssertFalse(CarPlaySurface.dashboard.interactive)
        XCTAssertTrue(CarPlaySurface.dashboard.pitchAllowed(performance: .full))
        XCTAssertEqual(CarPlaySurface.dashboard.fixedMeY, AppConfig.carPlayDashboardMeY)
        XCTAssertEqual(CarPlaySurface.dashboard.healthTag, "плитка")
    }

    /// Три метки журнала разные — по строке здоровья видно, какая карта легла.
    func testHealthTagsAreDistinct() {
        let tags = [CarPlaySurface.car, .dashboard, .cluster].map(\.healthTag)
        XCTAssertEqual(Set(tags).count, tags.count)
    }
}
