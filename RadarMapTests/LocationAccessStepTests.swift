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

    /// Отказ и ограничение: окна не будет — ведём в Настройки, а не молчим.
    func testRefusalLeadsToSettings() {
        for asked in [false, true] {
            XCTAssertEqual(LocationAccessStep.next(status: .denied, alwaysAsked: asked), .openSettings)
            XCTAssertEqual(LocationAccessStep.next(status: .restricted, alwaysAsked: asked), .openSettings)
        }
    }

    func testAlwaysNeedsNothing() {
        XCTAssertEqual(LocationAccessStep.next(status: .authorizedAlways, alwaysAsked: false), .done)
        XCTAssertEqual(LocationAccessStep.next(status: .authorizedAlways, alwaysAsked: true), .done)
    }

    /// Подсказка «что выбрать» — только там, где выбирать придётся в Настройках.
    func testSettingsHintOnlyForSettings() {
        XCTAssertTrue(LocationAccessStep.openSettings.needsSettingsHint)
        XCTAssertFalse(LocationAccessStep.askWhenInUse.needsSettingsHint)
        XCTAssertFalse(LocationAccessStep.askAlways.needsSettingsHint)
        XCTAssertFalse(LocationAccessStep.done.needsSettingsHint)
    }
}
