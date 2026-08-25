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
        let sketchHeight = headUnit.height - AppConfig.carPlayDockReserve
            - AppConfig.carPlayContentGap
        let byAspect = sketchHeight * AppConfig.carPlaySketchMaxAspect
        let available = headUnit.width - 24 - AppConfig.carPlayAheadPanelWidth - 14
        XCTAssertLessThanOrEqual(available - byAspect, 12,
                                 "схема не добирает \(available - byAspect) точек ширины")
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
