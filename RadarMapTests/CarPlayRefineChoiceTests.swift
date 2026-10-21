//
//  CarPlayRefineChoiceTests.swift
//  RadarMapTests
//
//  Уточнение «Радар!» кнопками в баннере (25.H1, iOS 27): все типы —
//  одним баннером или прежний путь с сеткой; «Отменить» — последним и
//  только если влезает.
//

import XCTest
@testable import RadarMap

final class CarPlayRefineChoiceTests: XCTestCase {

    func testKindsAreThePhoneSetWithoutRadar() {
        XCTAssertEqual(CarPlayRefineChoice.kinds, [.tripod, .post, .accident])
        XCTAssertFalse(CarPlayRefineChoice.kinds.contains(.radar))
    }

    func testAllKindsFitInOneBanner() {
        XCTAssertEqual(CarPlayRefineChoice.actions(maximum: 3, cancellable: false),
                       [.kind(.tripod), .kind(.post), .kind(.accident)])
        XCTAssertEqual(CarPlayRefineChoice.actions(maximum: 8, cancellable: false),
                       [.kind(.tripod), .kind(.post), .kind(.accident)])
    }

    /// Тип важнее отзыва: на три места «Отменить» не встаёт.
    func testCancelOnlyWhenThereIsRoom() {
        XCTAssertEqual(CarPlayRefineChoice.actions(maximum: 3, cancellable: true),
                       [.kind(.tripod), .kind(.post), .kind(.accident)])
        XCTAssertEqual(CarPlayRefineChoice.actions(maximum: 4, cancellable: true),
                       [.kind(.tripod), .kind(.post), .kind(.accident), .cancelOwn])
        XCTAssertEqual(CarPlayRefineChoice.actions(maximum: 4, cancellable: false)?.last, .kind(.accident))
    }

    /// Кнопок меньше, чем типов, — не обрезаем (пропавший «ДТП» хуже второго
    /// касания), а уходим на прежний путь.
    func testTooFewButtonsFallsBackToTheGrid() {
        XCTAssertNil(CarPlayRefineChoice.actions(maximum: 2, cancellable: true))
        XCTAssertNil(CarPlayRefineChoice.actions(maximum: 0, cancellable: false))
    }
}
