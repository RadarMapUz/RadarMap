//
//  CarPlayDockLayoutTests.swift
//  RadarMapTests
//
//  Раскладка экрана машины по вертикали и горизонтали — числами, а не глазами.
//
//  Резерв под док для схемы (carPlayDockReserve против carPlayDockBottomInset)
//  ушёл вместе со схемой (11.10) и картой Apple; остались высота и ширина
//  самого дока — экран машины меряется ими.
//
//  Второе число — потолок ширины дока. Он обязан оставаться широким настолько,
//  чтобы ViewThatFits выбирал раскладку С ПРИБЫТИЕМ: слишком узкий потолок не
//  ломает ничего заметного, он просто молча роняет время в пути на маршруте.
//

import XCTest
@testable import RadarMap

final class CarPlayDockLayoutTests: XCTestCase {

    /// Экран настоящего головного устройства после safe area.
    private let headUnit = CGSize(width: 950, height: 475)

    /// Узкая голова — самый частый экран в машинах до 2020 года и главный
    /// записанный риск сборки 81: панель выросла на 12 точек в высоту и на 36
    /// в ширину, и съесть карту она может именно здесь.
    private let narrowHeadUnit = CGSize(width: 800, height: 480)

    /// Панель не имеет права съесть карту. Высота на экране машины — самый
    /// дорогой ресурс, и на самой тесной голове карте обязаны остаться две
    /// трети: ниже этого карта перестаёт показывать дорогу впереди.
    func testDockLeavesTheMapMostOfTheHeight() {
        // Док и его нижний отступ.
        let share = (narrowHeadUnit.height - AppConfig.carPlayDockHeight - 12) / narrowHeadUnit.height
        XCTAssertGreaterThanOrEqual(share, 0.66,
                                    "карте осталось \(Int(share * 100)) % высоты")
    }

    /// …и остаётся островом даже на узком экране: потолок ширины дока обязан
    /// оставить поля с обеих сторон, иначе плашка превращается в ленту во всю
    /// ширину — ровно то, от чего потолок и заводился.
    func testDockKeepsMarginsOnANarrowHeadUnit() {
        XCTAssertLessThanOrEqual(AppConfig.carPlayDockMaxWidth,
                                 narrowHeadUnit.width - 48)
    }

    /// Потолок ширины дока обязан вмещать три зоны с разделителями, иначе
    /// ViewThatFits тихо выберет раскладку без прибытия.
    func testDockCapFitsThreeZones() {
        let inner = AppConfig.carPlayDockMaxWidth - 36
        XCTAssertGreaterThanOrEqual(inner, 570)
    }

    /// …но остаётся островом: на широком экране полоса во всю ширину разносит
    /// две занятые зоны по разным краям дисплея.
    func testDockStaysAnIsland() {
        XCTAssertLessThan(AppConfig.carPlayDockMaxWidth, headUnit.width * 0.8)
    }
}
