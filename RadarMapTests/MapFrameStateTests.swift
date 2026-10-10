//
//  MapFrameStateTests.swift
//  RadarMapTests
//
//  Поля карты главного экрана: какую долю высоты закрывают панели. Стерегут
//  поломку 11.10 — высоту вида ставила только вью схемы, схему убрали, и поля
//  навсегда остались нулевыми: «я» на карте движка стоял под нижней панелью.
//

import XCTest
@testable import RadarMap

final class MapFrameStateTests: XCTestCase {

    /// Без высоты вида полей нет: делить кромки панелей не на что.
    func testNoHeightMeansNoInsets() {
        XCTAssertEqual(MapFrameState.insets(viewHeight: 0, panelTop: 120, panelBottom: 700),
                       .none)
    }

    /// Высота есть — поля в долях: сверху до кромки верхней стопки, снизу от
    /// кромки нижней до низа экрана.
    func testPanelsBecomeShares() {
        let insets = MapFrameState.insets(viewHeight: 800, panelTop: 160, panelBottom: 600)
        XCTAssertEqual(insets.top, 0.2, accuracy: 1e-9)
        XCTAssertEqual(insets.bottom, 0.25, accuracy: 1e-9)
        XCTAssertTrue(insets.meY > insets.top && insets.meY < 1 - insets.bottom,
                      "«я» обязан стоять в видимой полосе между панелями, а не под ними")
    }

    /// Ноль снизу — «ещё не мерили», а не «панель во весь экран»: иначе
    /// первый кадр сжимался бы в треть экрана.
    func testUnmeasuredBottomIsEmpty() {
        let insets = MapFrameState.insets(viewHeight: 800, panelTop: 160, panelBottom: 0)
        XCTAssertEqual(insets.bottom, 0)
    }
}
