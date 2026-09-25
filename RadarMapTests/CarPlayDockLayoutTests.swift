//
//  CarPlayDockLayoutTests.swift
//  RadarMapTests
//
//  Раскладка экрана машины по вертикали и горизонтали — числами, а не глазами.
//
//  Поломка, ради которой тесты написаны, глазами и ловилась: приборная панель
//  занимала 88 точек, а схема резервировала под неё 140 — резерв считался по
//  carPlayDockBottomInset, взятому с запасом ради служебных подписей MKMapView,
//  и сверху к нему добавлялся ещё и зазор. Сорок точек высоты уходили в чёрное
//  поле, а на экране машины высота — самый дорогой ресурс: схема считает
//  масштаб именно от неё.
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

    /// Ширина, остающаяся схеме после полей экрана, ленты «что впереди» и
    /// зазора между ними. Формула одна на оба устройства намеренно: разъехаться
    /// они должны по числам, а не по разной арифметике в двух тестах.
    private func widthLeftToSketch(on screen: CGSize) -> CGFloat {
        let ahead = screen.width > AppConfig.carPlayWidePointsThreshold
            ? AppConfig.carPlayAheadPanelWidth : 0
        return screen.width - 24 - ahead - 14
    }

    private func heightLeftToSketch(on screen: CGSize) -> CGFloat {
        screen.height - AppConfig.carPlayDockReserve - AppConfig.carPlayContentGap
    }

    /// Резерв под панель обязан её вмещать — иначе схема заедет под цифры.
    func testReserveCoversTheDock() {
        XCTAssertGreaterThanOrEqual(AppConfig.carPlayDockReserve, AppConfig.carPlayDockHeight)
    }

    /// …и не превышать инсет карты: тот взят с запасом под служебные подписи,
    /// и считать по нему высоту схемы — это и есть та самая потеря сорока точек.
    func testReserveIsNotThePaddedMapInset() {
        XCTAssertLessThan(AppConfig.carPlayDockReserve, AppConfig.carPlayDockBottomInset)
    }

    /// Схема должна занимать свою половину целиком. Ограничение по пропорции
    /// (carPlaySketchMaxAspect) не должно оказываться жёстче, чем место,
    /// оставшееся после ленты «что впереди»: разница — это мёртвое поле по
    /// бокам схемы, ряд домов, вставший не на своё место.
    func testSketchFillsItsShareOnAHeadUnit() {
        let byAspect = heightLeftToSketch(on: headUnit) * AppConfig.carPlaySketchMaxAspect
        let available = widthLeftToSketch(on: headUnit)
        XCTAssertLessThanOrEqual(available - byAspect, 12,
                                 "схема не добирает \(available - byAspect) точек ширины")
    }

    /// То же на узкой голове. Здесь пропорция заведомо не должна связывать:
    /// ширины и так мало, и если схему обрежет ещё и она — мёртвое поле
    /// появится там, где места меньше всего.
    func testAspectDoesNotStarveANarrowHeadUnit() {
        let byAspect = heightLeftToSketch(on: narrowHeadUnit) * AppConfig.carPlaySketchMaxAspect
        let available = widthLeftToSketch(on: narrowHeadUnit)
        XCTAssertGreaterThanOrEqual(byAspect, available,
                                    "на 800×480 ширину ограничивает пропорция, а не экран")
    }

    /// Панель не имеет права съесть карту. Высота на экране машины — самый
    /// дорогой ресурс, и на самой тесной голове карте обязаны остаться две
    /// трети: ниже этого схема перестаёт показывать дорогу впереди.
    func testDockLeavesTheMapMostOfTheHeight() {
        let share = heightLeftToSketch(on: narrowHeadUnit) / narrowHeadUnit.height
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
