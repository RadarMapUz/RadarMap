//
//  LocationAccessStepTests.swift
//  RadarMapTests
//
//  Кнопка доступа к геопозиции не бывает мёртвой: при каждом статусе она либо
//  зовёт окно, которое iOS ещё покажет, либо ведёт в Настройки.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class LocationAccessStepTests: XCTestCase {

    func testFirstTapAsksWhenInUse() {
        XCTAssertEqual(LocationAccessStep.next(status: .notDetermined, alwaysAsked: false), .askWhenInUse)
        XCTAssertEqual(LocationAccessStep.next(status: .notDetermined, alwaysAsked: true), .askWhenInUse)
    }

    /// «При использовании»: окно «Всегда» — один раз, дальше только Настройки.
    func testAlwaysIsAskedOnceThenSettings() {
        XCTAssertEqual(LocationAccessStep.next(status: .authorizedWhenInUse, alwaysAsked: false), .askAlways)
        XCTAssertEqual(LocationAccessStep.next(status: .authorizedWhenInUse, alwaysAsked: true), .openSettings)
    }

    /// Отказ: окна не будет — ведём в Настройки, а не молчим.
    func testRefusalLeadsToSettings() {
        for asked in [false, true] {
            XCTAssertEqual(LocationAccessStep.next(status: .denied, alwaysAsked: asked), .openSettings)
        }
    }

    /// Родительский контроль и выключенные Службы геолокации: «Всегда» на
    /// странице приложения не выбрать — подсказка про устройство.
    func testDeviceLimits() {
        XCTAssertEqual(LocationAccessStep.next(status: .restricted, alwaysAsked: false), .deviceLimited)
        XCTAssertEqual(LocationAccessStep.next(status: .denied, alwaysAsked: true, servicesEnabled: false),
                       .deviceLimited)
        XCTAssertEqual(LocationAccessStep.next(status: .authorizedWhenInUse, alwaysAsked: true,
                                               servicesEnabled: false), .openSettings)
    }

    func testAlwaysNeedsNothing() {
        XCTAssertEqual(LocationAccessStep.next(status: .authorizedAlways, alwaysAsked: false), .done)
        XCTAssertEqual(LocationAccessStep.next(status: .authorizedAlways, alwaysAsked: true), .done)
    }

    /// Подсказка — только там, где выбирать придётся в Настройках, и своя
    /// для ограничения устройства.
    func testHints() {
        XCTAssertEqual(LocationAccessStep.openSettings.hint, .pickAlways)
        XCTAssertEqual(LocationAccessStep.deviceLimited.hint, .deviceLimited)
        XCTAssertNil(LocationAccessStep.askWhenInUse.hint)
        XCTAssertNil(LocationAccessStep.askAlways.hint)
        XCTAssertNil(LocationAccessStep.done.hint)
    }
}
