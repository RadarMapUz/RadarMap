//
//  RouteCorridorTests.swift
//  RadarMapTests
//
//  Коридор длинного маршрута (19.3): какие области карты задевает полоса
//  вокруг линии и в каком порядке, какие клетки заведений, когда можно
//  качать по мобильной сети и когда предлагать «Скачать карту по пути».
//

import CoreLocation
import XCTest
@testable import RadarMap

final class RouteCorridorTests: XCTestCase {

    // MARK: - Каталог-полосы

    /// Каталог из вертикальных полос клеток z12: у каждой области свой
    /// диапазон долгот на широтах 40.5…41.5, у «северной» — клетки над 41.5.
    private func catalog() -> RegionCatalog {
        let zoom = 12
        func x(_ lon: Double) -> Int { RegionCatalog.cell(of: .init(latitude: 41, longitude: lon), zoom: zoom).x }
        func y(_ lat: Double) -> Int { RegionCatalog.cell(of: .init(latitude: lat, longitude: 69), zoom: zoom).y }
        func band(_ id: String, ys: ClosedRange<Int>, lons: (Double, Double)) -> RegionCatalog.Region {
            let rows = ys.map { [$0, x(lons.0), x(lons.1) - 1] }
            return RegionCatalog.Region(id: id, name: ["ru": id, "uz": id], bbox: [], cells: rows.count,
                                        rows: rows,
                                        files: ["mvt": .init(file: "\(id).pmtiles", bytes: 10_000_000, sha256: "")])
        }
        // y растёт к югу; строка y(41.5) — последняя у полос, «N» — над ней
        // (граница — северный край этой строки, ≈41.5086°).
        let south = y(41.5)...y(40.5)
        return RegionCatalog(version: 1, cellZoom: zoom, regions: [
            band("A", ys: south, lons: (68.0, 68.5)),
            band("B", ys: south, lons: (68.5, 69.0)),
            band("C", ys: south, lons: (69.0, 69.5)),
            band("N", ys: y(42.0)...(y(41.5) - 1), lons: (68.0, 69.5)),
        ])
    }

    private func line(lat: Double, from: Double, to: Double) -> [CLLocationCoordinate2D] {
        [.init(latitude: lat, longitude: from), .init(latitude: lat, longitude: to)]
    }

    func testRegionsComeInRouteOrder() {
        let east = RouteCorridor.regions(route: line(lat: 41.0, from: 68.1, to: 69.4), catalog: catalog())
        XCTAssertEqual(east.map(\.id), ["A", "B", "C"], "первой качается та, что раньше понадобится")
        let west = RouteCorridor.regions(route: line(lat: 41.0, from: 69.4, to: 68.1), catalog: catalog())
        XCTAssertEqual(west.map(\.id), ["C", "B", "A"])
    }

    func testRoadAlongTheBorderTakesTheNeighbour() {
        // ~1,5 км южнее границы с «N»: карта по ту сторону дороги — уже N.
        let near = RouteCorridor.regions(route: line(lat: 41.495, from: 68.6, to: 68.9), catalog: catalog())
        XCTAssertEqual(Set(near.map(\.id)), ["B", "N"])
        // 16 км от границы — соседняя не нужна.
        let far = RouteCorridor.regions(route: line(lat: 41.36, from: 68.6, to: 68.9), catalog: catalog())
        XCTAssertEqual(far.map(\.id), ["B"])
    }

    func testRouteOutsideTheCatalogHasNoRegions() {
        XCTAssertTrue(RouteCorridor.regions(route: line(lat: 45.0, from: 60.0, to: 60.5),
                                            catalog: catalog()).isEmpty)
    }

    func testSamplesAreDenseOnLongStraights() {
        let points = RouteCorridor.samples(line(lat: 41.0, from: 69.0, to: 69.12), step: 1_000)
        XCTAssertGreaterThanOrEqual(points.count, 11, "10 км прямой — проба на каждый километр")
        for (a, b) in zip(points, points.dropFirst()) {
            XCTAssertLessThanOrEqual(GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude), 1_001)
        }
        XCTAssertTrue(RouteCorridor.samples([], step: 1_000).isEmpty)
    }

    // MARK: - Клетки заведений

    func testVenueCellsAlongTheRouteInOrder() {
        let cells = RouteCorridor.venueCells(route: line(lat: 41.25, from: 68.6, to: 69.9))
        XCTAssertEqual(cells.map(\.key), ["262_497_v", "262_498_v", "262_499_v"])
        // Точка клетки даёт ту же клетку — по ней файл и просят.
        for cell in cells { XCTAssertEqual(VenueBook.key(for: cell.point), cell.key) }
    }

    func testVenueCellsCatchTheNeighbourWithinTheCorridor() {
        // 1 км севернее границы 41.0: полоса в 2 км задевает клетку южнее.
        let cells = RouteCorridor.venueCells(route: line(lat: 41.009, from: 69.1, to: 69.3))
        XCTAssertEqual(Set(cells.map(\.key)), ["262_498_v", "261_498_v"])
    }

    func testCellularNeedsConsent() {
        XCTAssertTrue(RouteCorridor.mayFetchCells(online: true, expensiveNetwork: false, consented: false),
                      "по Wi-Fi — сами")
        XCTAssertFalse(RouteCorridor.mayFetchCells(online: true, expensiveNetwork: true, consented: false),
                       "по мобильной сети молча радио не будим")
        XCTAssertTrue(RouteCorridor.mayFetchCells(online: true, expensiveNetwork: true, consented: true))
        XCTAssertFalse(RouteCorridor.mayFetchCells(online: false, expensiveNetwork: false, consented: true),
                       "без связи — только с диска")
    }

    // MARK: - Предложение

    private var long: RouteCorridor.Situation {
        RouteCorridor.Situation(routeMeters: 300_000, online: true, expensiveNetwork: false,
                                moving: false, answered: false, questionShown: false)
    }

    func testOfferKeepsCorridorOrderAndSumsTheSize() {
        let regions = catalog().regions
        let offer = RouteCorridor.offer(corridor: [regions[2], regions[0], regions[1]],
                                        isMissing: { $0.id != "A" }, graphBytes: 5_000_000)
        XCTAssertEqual(offer.regions.map(\.id), ["C", "B"], "скачанная A не предлагается, порядок коридора")
        XCTAssertEqual(offer.totalBytes, 25_000_000)
        XCTAssertFalse(offer.isEmpty)
        XCTAssertTrue(RouteCorridor.offer(corridor: regions, isMissing: { _ in false }, graphBytes: nil).isEmpty)
        // Граф один — уже повод: без него на трассе нет маршрута без сети.
        XCTAssertFalse(RouteCorridor.offer(corridor: regions, isMissing: { _ in false }, graphBytes: 1).isEmpty)
    }

    func testOfferOnlyInTheCalmMoment() {
        let offer = RouteCorridor.Offer(regions: Array(catalog().regions.prefix(1)), graphBytes: nil)
        XCTAssertTrue(RouteCorridor.shouldOffer(long, offer: offer))

        var s = long
        s.routeMeters = 100_000
        XCTAssertFalse(RouteCorridor.shouldOffer(s, offer: offer), "город из конца в конец — не дальняя дорога")
        s = long; s.expensiveNetwork = true
        XCTAssertFalse(RouteCorridor.shouldOffer(s, offer: offer), "сотни мегабайт по мобильной — не предлагаем")
        s = long; s.online = false
        XCTAssertFalse(RouteCorridor.shouldOffer(s, offer: offer))
        s = long; s.moving = true
        XCTAssertFalse(RouteCorridor.shouldOffer(s, offer: offer), "решение про мегабайты на ходу не принимают")
        s = long; s.answered = true
        XCTAssertFalse(RouteCorridor.shouldOffer(s, offer: offer), "один раз на маршрут")
        s = long; s.questionShown = true
        XCTAssertFalse(RouteCorridor.shouldOffer(s, offer: offer), "вопрос «Радар ещё стоял?» старше")
        XCTAssertFalse(RouteCorridor.shouldOffer(long, offer: .init(regions: [], graphBytes: nil)),
                       "всё скачано — не о чем спрашивать")
    }

    func testCardNeverPushesTheFixedButtonsUnder() {
        // SE, обычный шрифт, покой с маршрутом: просвет 242 pt — четыре места.
        // Карточка в 120 pt одна не встаёт (останется два места)…
        XCTAssertFalse(CorridorOfferPlacement.fits(room: 242, cardHeight: 120, shown: false))
        // …а на месте бара в 70 pt — встаёт: колонке остаются три обязательных.
        XCTAssertTrue(CorridorOfferPlacement.fits(room: 242, cardHeight: 120, shown: false, freed: 70))
        // SE, крупный шрифт: просвет 182, карточка 150, бар 97 — не встаёт и
        // на месте бара: ждёт «Поехали».
        XCTAssertFalse(CorridorOfferPlacement.fits(room: 182, cardHeight: 150, shown: false, freed: 97))
        // Поездка: строка поездки низкая, просвет 420 — встаёт.
        XCTAssertTrue(CorridorOfferPlacement.fits(room: 420, cardHeight: 150, shown: false))
        // Уже на экране: просвет мерен с ней — держится, пока обязательным хватает.
        XCTAssertTrue(CorridorOfferPlacement.fits(room: 160, cardHeight: 150, shown: true))
        XCTAssertFalse(CorridorOfferPlacement.fits(room: 140, cardHeight: 150, shown: true),
                       "выросла панель маршрута — карточка уступает кнопкам")
        XCTAssertFalse(CorridorOfferPlacement.fits(room: nil, cardHeight: 150, shown: false), "не измерено — ждём кадр")
        XCTAssertFalse(CorridorOfferPlacement.fits(room: 600, cardHeight: nil, shown: false))
    }

    func testStandingUpNeverMeansLeavingNextFrame() {
        // Решение «встать» по спрятанной обязано выдержать пересчёт просвета
        // уже с карточкой (и без бара): иначе карточка мигала бы туда-обратно.
        for room in stride(from: CGFloat(100), through: 700, by: 3.5) {
            for height in stride(from: CGFloat(40), through: 260, by: 7) {
                for freed in [CGFloat(0), 70, 97] {
                    guard CorridorOfferPlacement.fits(room: room, cardHeight: height, shown: false,
                                                      freed: freed) else { continue }
                    let spacing = AppConfig.bottomStackSpacing
                    // Мерка после кадра может разойтись на долю пункта.
                    let after = room - height - spacing + (freed > 0 ? freed + spacing : 0) - 0.5
                    XCTAssertTrue(CorridorOfferPlacement.fits(room: after, cardHeight: height, shown: true),
                                  "просвет \(room), карточка \(height), бар \(freed)")
                }
            }
        }
    }

    func testRouteKeyIsTheDestination() {
        let a = RouteCorridor.routeKey(destination: .init(latitude: 39.65421, longitude: 66.95973))
        let b = RouteCorridor.routeKey(destination: .init(latitude: 39.65438, longitude: 66.95961))
        XCTAssertEqual(a, b, "перестроение и заезд — та же цель")
        XCTAssertNotEqual(a, RouteCorridor.routeKey(destination: .init(latitude: 40.38, longitude: 71.78)))
    }

    func testShortRegionNamesStayDistinct() {
        XCTAssertEqual(RouteCorridor.shortNames(["Джизакская область", "Республика Каракалпакстан"]),
                       ["Джизакская", "Каракалпакстан"])
        XCTAssertEqual(RouteCorridor.shortNames(["Navoiy Viloyati", "Qoraqalpogʻiston Respublikasi"]),
                       ["Navoiy", "Qoraqalpogʻiston"])
        // «Toshkent» и «Toshkent viloyati» укоротились бы в одно слово — оба полные.
        XCTAssertEqual(RouteCorridor.shortNames(["Toshkent", "Toshkent viloyati", "Sirdaryo viloyati"]),
                       ["Toshkent", "Toshkent viloyati", "Sirdaryo"])
    }
}
