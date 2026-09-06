//
//  OverspeedThresholdTests.swift
//  RadarMapTests
//
//  Порог превышения. Правило выросло из фразы водителя: «на 60 месте если
//  проезжать 66, то на радар можешь попасть».
//

import XCTest
@testable import RadarMap

final class OverspeedThresholdTests: XCTestCase {

    /// Вдали от камер порог — настройка человека: это совет, а не риск.
    func testAwayFromCamerasTheUserSettingRules() {
        XCTAssertEqual(OverspeedThreshold.kmh(cameraAhead: false, userTolerance: 5), 5)
        XCTAssertEqual(OverspeedThreshold.kmh(cameraAhead: false, userTolerance: 0), 0)
    }

    /// У камеры порог жёстче штрафного — иначе предупреждение приходит вместе
    /// со штрафом и не даёт ничего сделать.
    func testNearACameraTheThresholdIsTighterThanTheFine() {
        let threshold = OverspeedThreshold.kmh(cameraAhead: true, userTolerance: 5)
        XCTAssertLessThan(threshold, FineSchedule.toleranceKmh)
        XCTAssertEqual(threshold, 3)
    }

    /// Тот самый случай целиком: зона 60.
    func testTheSixtyZone() {
        let limit = 60.0
        let near = OverspeedThreshold.kmh(cameraAhead: true, userTolerance: 5)
        // 63 — уже предупреждаем, газ ещё можно отпустить.
        XCTAssertGreaterThan(63 - limit, near)
        // 66 — штраф уже заработан.
        XCTAssertTrue(OverspeedThreshold.isFineEarned(speedKmh: 66, limitKmh: 60))
        // 65 — ровно на границе допуска, штрафа ещё нет.
        XCTAssertFalse(OverspeedThreshold.isFineEarned(speedKmh: 65, limitKmh: 60))
        // Но предупредить о 65 у камеры мы обязаны: до штрафа один километр.
        XCTAssertGreaterThan(65 - limit, near)
    }

    /// Тот, кто попросил говорить раньше, не должен получить позже.
    func testCameraNeverRelaxesAStricterSetting() {
        XCTAssertEqual(OverspeedThreshold.kmh(cameraAhead: true, userTolerance: 0), 0)
        XCTAssertEqual(OverspeedThreshold.kmh(cameraAhead: true, userTolerance: 1), 1)
    }
}
