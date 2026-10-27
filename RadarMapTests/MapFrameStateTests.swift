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

    /// Карточка предупреждения о камере в навигации поднимает нижнюю кромку
    /// карты: «я» и камера над ней, а не под ней (ревью 19.10).
    func testAlertCardRaisesTheBottomEdge() {
        XCTAssertEqual(MapFrameState.bottomEdge(panel: 700, overlay: nil), 700)
        XCTAssertEqual(MapFrameState.bottomEdge(panel: 700, overlay: 480), 480)
        XCTAssertEqual(MapFrameState.bottomEdge(panel: 700, overlay: 760), 700, "ниже панели — панель")
        XCTAssertEqual(MapFrameState.bottomEdge(panel: 0, overlay: 480), 480, "панель ещё не мерили")
        XCTAssertEqual(MapFrameState.bottomEdge(panel: 700, overlay: 0), 700)
    }

    /// Верхняя карточка предупреждения при выборе маршрута (28.K): «я» и
    /// начало маршрута — под нижней из двух кромок.
    func testTopEdgeTakesTheLowerOfPanelAndAlertCard() {
        XCTAssertEqual(MapFrameState.topEdge(panel: 120, overlay: nil), 120)
        XCTAssertEqual(MapFrameState.topEdge(panel: 120, overlay: 230), 230)
        XCTAssertEqual(MapFrameState.topEdge(panel: 260, overlay: 230), 260, "панель ниже — панель")
        XCTAssertEqual(MapFrameState.topEdge(panel: 0, overlay: 230), 230, "панель ещё не мерили")
        XCTAssertEqual(MapFrameState.topEdge(panel: 120, overlay: 0), 120)
    }
}
