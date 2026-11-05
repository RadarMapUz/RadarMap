//
//  TouchFeedbackTests.swift
//  RadarMapTests
//
//  Отклик касания: сила вибрации — по роли кнопки, «Уменьшение движения» —
//  без масштаба.
//

import XCTest
@testable import RadarMap

final class TouchFeedbackTests: XCTestCase {

    /// Главное действие ощущается сильнее обычного, отказ — по-своему.
    func testHapticByRole() {
        XCTAssertEqual(TouchResponse.of(.regular, reduceMotion: false).haptic, .light)
        XCTAssertEqual(TouchResponse.of(.primary, reduceMotion: false).haptic, .medium)
        XCTAssertEqual(TouchResponse.of(.cancel, reduceMotion: false).haptic, .soft)
        XCTAssertEqual(TouchResponse.of(.choice, reduceMotion: false).haptic, .selection)
        XCTAssertEqual(TouchResponse.of(.row, reduceMotion: false).haptic, .selection)
        XCTAssertEqual(TouchResponse.of(.card, reduceMotion: false).haptic, .light)
    }

    /// Действие, которое отвечает само (взвод «Стопа», экран оповещения), не
    /// получает второй вибрации от стиля.
    func testOwnFeedbackIsSilent() {
        XCTAssertEqual(TouchResponse.of(.ownFeedback, reduceMotion: false).haptic, .none)
        XCTAssertEqual(TouchResponse.of(.ownFeedback, reduceMotion: true).haptic, .none)
    }

    /// «Уменьшение движения»: ни одна роль не масштабирует, нажатие видно
    /// затемнением.
    func testReduceMotionNeverScales() {
        for role in TouchRole.allCases {
            let response = TouchResponse.of(role, reduceMotion: true)
            XCTAssertEqual(response.pressedScale, 1, "\(role)")
            XCTAssertLessThan(response.pressedOpacity, 1, "\(role)")
        }
    }

    /// Настройка про движение, не про осязание: сила вибрации та же.
    func testReduceMotionKeepsHaptic() {
        for role in TouchRole.allCases {
            XCTAssertEqual(TouchResponse.of(role, reduceMotion: true).haptic,
                           TouchResponse.of(role, reduceMotion: false).haptic, "\(role)")
        }
    }

    /// Обычное движение: кнопки сжимаются и не тускнеют; строка списка — без
    /// сжатия, только затемнение.
    func testPressShapeWithMotion() {
        for role in TouchRole.allCases where role != .row {
            let response = TouchResponse.of(role, reduceMotion: false)
            XCTAssertLessThan(response.pressedScale, 1, "\(role)")
            XCTAssertGreaterThanOrEqual(response.pressedScale, 0.9, "\(role)")
            XCTAssertEqual(response.pressedOpacity, 1, "\(role)")
        }
        let row = TouchResponse.of(.row, reduceMotion: false)
        XCTAssertEqual(row.pressedScale, 1)
        XCTAssertLessThan(row.pressedOpacity, 1)
    }

    /// Широкая главная кнопка сжимается меньше круга: 5 % от 340 pt — уже рывок.
    func testPrimaryScalesLessThanRegular() {
        XCTAssertGreaterThan(TouchResponse.of(.primary, reduceMotion: false).pressedScale,
                             TouchResponse.of(.regular, reduceMotion: false).pressedScale)
    }

    /// Системная роль отмены превращает обычную кнопку в отказ, но не
    /// переписывает роль, выбранную явно.
    func testCancelButtonRole() {
        XCTAssertEqual(TouchRole.resolve(.regular, isCancelButton: true), .cancel)
        XCTAssertEqual(TouchRole.resolve(.regular, isCancelButton: false), .regular)
        XCTAssertEqual(TouchRole.resolve(.primary, isCancelButton: true), .primary)
        XCTAssertEqual(TouchRole.resolve(.ownFeedback, isCancelButton: true), .ownFeedback)
    }
}
