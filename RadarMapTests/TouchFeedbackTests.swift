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

    /// Генератор по силе: отказ — мягкий удар вполсилы, выбор — щелчок,
    /// «без вибрации» — ничего.
    func testGeneratorBySeverity() {
        XCTAssertEqual(TouchHaptic.none.generator, .none)
        XCTAssertEqual(TouchHaptic.selection.generator, .selection)
        XCTAssertEqual(TouchHaptic.light.generator, .impact(.light, intensity: 1))
        XCTAssertEqual(TouchHaptic.medium.generator, .impact(.medium, intensity: 1))
        XCTAssertEqual(TouchHaptic.soft.generator, .impact(.soft, intensity: 0.6))
    }

    /// По роли до генератора: главное — средний удар, обычное — лёгкий,
    /// `.ownFeedback` — генератор не играет вовсе.
    func testGeneratorByRole() {
        XCTAssertEqual(TouchResponse.of(.primary, reduceMotion: false).haptic.generator,
                       .impact(.medium, intensity: 1))
        XCTAssertEqual(TouchResponse.of(.regular, reduceMotion: true).haptic.generator,
                       .impact(.light, intensity: 1))
        XCTAssertEqual(TouchResponse.of(.row, reduceMotion: false).haptic.generator, .selection)
        XCTAssertEqual(TouchResponse.of(.ownFeedback, reduceMotion: false).haptic.generator, .none)
    }

    /// Недоступная кнопка приглушена, но видна.
    func testDisabledOpacity() {
        XCTAssertGreaterThan(TouchResponse.disabledOpacity, 0.3)
        XCTAssertLessThan(TouchResponse.disabledOpacity, 0.6)
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
