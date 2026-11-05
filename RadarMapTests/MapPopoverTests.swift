//
//  MapPopoverTests.swift
//  RadarMapTests
//
//  Меню на карте (20.10): открыта одна карточка, касание мимо закрывает её,
//  а запоздавшее «своё» закрытие одной карточки не трогает другую.
//

import XCTest
@testable import RadarMap

final class MapPopoverTests: XCTestCase {

    func testButtonOpensAndSecondTapCloses() {
        for card in MapPopover.allCases {
            XCTAssertEqual(MapPopover.next(nil, on: .toggle(card)), card)
            XCTAssertNil(MapPopover.next(card, on: .toggle(card)))
        }
    }

    /// Вторая карточка встаёт вместо первой, а не поверх неё.
    func testOpeningAnotherCardReplacesTheFirst() {
        XCTAssertEqual(MapPopover.next(.layers, on: .toggle(.quickToggles)), .quickToggles)
        XCTAssertEqual(MapPopover.next(.quickToggles, on: .toggle(.layers)), .layers)
    }

    /// Касание мимо, лист, старт или конец поездки, фон — закрывают любую.
    func testOutsideTouchAndContextChangesCloseAnyCard() {
        let closing: [MapPopover.Event] = [.outsideTouch, .sheetOpened, .tripStateChanged, .background]
        for card in MapPopover.allCases {
            for event in closing {
                XCTAssertNil(MapPopover.next(card, on: event), "\(event) не закрыл \(card)")
            }
        }
        for event in closing {
            XCTAssertNil(MapPopover.next(nil, on: event), "\(event) открыл карточку из ничего")
        }
    }

    /// Таймер простоя слоёв, сработавший после того, как открыли
    /// «Оповещения», не закрывает их: это не его карточка.
    func testOwnDismissClosesOnlyThatCard() {
        XCTAssertNil(MapPopover.next(.layers, on: .dismissed(.layers)))
        XCTAssertEqual(MapPopover.next(.quickToggles, on: .dismissed(.layers)), .quickToggles)
        XCTAssertEqual(MapPopover.next(.layers, on: .dismissed(.quickToggles)), .layers)
        XCTAssertNil(MapPopover.next(nil, on: .dismissed(.layers)))
    }

    /// Камера впереди закрывает плитки «Ещё» внизу, а меню сверху оставляет.
    func testCameraClosesOnlyTheTileMenu() {
        XCTAssertNil(MapPopover.next(.tripMenu, on: .cameraAlert))
        XCTAssertEqual(MapPopover.next(.quickToggles, on: .cameraAlert), .quickToggles)
        XCTAssertEqual(MapPopover.next(.layers, on: .cameraAlert), .layers)
    }

    /// Ни одно событие, кроме кнопки карточки, не открывает меню само.
    func testOnlyTheCardButtonOpensACard() {
        let events: [MapPopover.Event] = [.outsideTouch, .sheetOpened, .tripStateChanged, .background,
                                          .cameraAlert, .dismissed(.layers), .dismissed(.quickToggles)]
        for event in events {
            XCTAssertNil(MapPopover.next(nil, on: event))
        }
    }
}
