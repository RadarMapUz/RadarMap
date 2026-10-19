//
//  NetworkRhythmTests.swift
//  RadarMapTests
//
//  Ритм сети в поездке (аудит энергии 19.10): пробки реже при погашенном
//  экране без маршрута и вместе с уже разбуженным радио.
//

import XCTest
@testable import RadarMap

final class NetworkRhythmTests: XCTestCase {
    func testTrafficIsFrequentOnlyWhenSomeoneUsesIt() {
        XCTAssertEqual(NetworkRhythm.trafficInterval(screenOn: true, hasRoute: false), AppConfig.trafficRefreshInterval)
        XCTAssertEqual(NetworkRhythm.trafficInterval(screenOn: false, hasRoute: true), AppConfig.trafficRefreshInterval,
                       "время в пути по маршруту считается и с погашенным экраном")
        XCTAssertEqual(NetworkRhythm.trafficInterval(screenOn: false, hasRoute: false), AppConfig.trafficQuietInterval)
        XCTAssertGreaterThan(AppConfig.trafficQuietInterval, AppConfig.trafficRefreshInterval)
    }

    func testTrafficJoinsTheRadioOnlyWhenItsTimeIsNear() {
        let interval = AppConfig.trafficRefreshInterval
        XCTAssertTrue(NetworkRhythm.joinsAwakeRadio(sinceLast: interval - AppConfig.radioJoinSlackSeconds,
                                                    interval: interval))
        XCTAssertFalse(NetworkRhythm.joinsAwakeRadio(sinceLast: 10, interval: interval),
                       "только что ходили — ещё раз незачем")
        XCTAssertTrue(NetworkRhythm.joinsAwakeRadio(sinceLast: 10_000, interval: interval))
    }
}
