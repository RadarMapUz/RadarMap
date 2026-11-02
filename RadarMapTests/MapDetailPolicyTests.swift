//
//  MapDetailPolicyTests.swift
//  RadarMapTests
//
//  «Только нужное сейчас» (29.H): что видно на ходу, стоя, у цели, на
//  трассе, без маршрута, на плитке и приборке; гистерезис подъезда к цели;
//  и главное — камеры, маршрут, события дороги и пробки решению недоступны.
//

import XCTest
@testable import RadarMap

final class MapDetailPolicyTests: XCTestCase {

    private typealias P = MapDetailPolicy

    private func car(standing: Bool = false, route: Bool = true, remaining: Double? = 5_000,
                     seconds: Double? = 600, routeMeters: Double = 8_000,
                     wasArriving: Bool = false) -> P.Context {
        P.Context(surface: .car, tripActive: true, standing: standing, hasRoute: route,
                  remainingMeters: route ? remaining : nil, remainingSeconds: route ? seconds : nil,
                  routeMeters: route ? routeMeters : 0, wasArriving: wasArriving)
    }

    private func phone(_ c: P.Context) -> P.Context {
        var c = c
        c.surface = .phone
        return c
    }

    // MARK: - Режимы

    func testCarOnTheMoveShowsOnlyRoadAndFuelAhead() {
        let d = P.decide(car())
        XCTAssertEqual(d.mode, .moving)
        XCTAssertFalse(d.decor)
        XCTAssertEqual(d.places, .none, "на ходу без кафе и магазинов")
        XCTAssertFalse(d.houseNumbers)
        XCTAssertEqual(d.fuel, .ahead(AppConfig.mapDetailFuelAheadCar), "АЗС только по пути")
        XCTAssertEqual(d.parking, .hidden)
        XCTAssertEqual(d.destination, .flag)
        XCTAssertFalse(d.keepDestination)
    }

    func testStandingShowsNeighbourhood() {
        let d = P.decide(car(standing: true))
        XCTAssertEqual(d.mode, .standing)
        XCTAssertTrue(d.decor)
        XCTAssertEqual(d.places, .none, "в машине стоя — заправки и парковки, без кафе и магазинов")
        XCTAssertEqual(d.fuel, .nearby)
        XCTAssertEqual(d.parking, .nearby)
    }

    func testPhoneStandingShowsOnlyTheFirstRow() {
        // 29.D: со вторым рядом на остановке у развилки было десять подписей.
        XCTAssertEqual(P.decide(phone(car(standing: true))).places, .top)
        XCTAssertEqual(P.decide(phone(car(standing: false))).places, .none, "на ходу — только дорога")
        XCTAssertEqual(MapDetailLayers.tripPlaceRows(P.decide(phone(car(standing: true)))), ["poi-level-1"],
                       "вернувшийся ряд карта держит не под «я» (EngineStopDetail)")
        var hot = phone(car(standing: true))
        hot.hot = true
        XCTAssertEqual(P.decide(hot).places, .none, "горячий телефон — нет")
        var outside = phone(car(standing: true))
        outside.tripActive = false
        XCTAssertTrue(MapDetailLayers.tripPlaceRows(P.decide(outside)).isEmpty, "вне поездки — без круга у машины")
    }

    func testArrivalShowsDestinationParkingsAndHouseNumbers() {
        let d = P.decide(car(remaining: 900, seconds: 140))
        XCTAssertEqual(d.mode, .arrival)
        XCTAssertTrue(d.houseNumbers, "у цели — найти дом")
        XCTAssertEqual(d.parking, .destination(AppConfig.mapDetailArrivalParkingsCar))
        XCTAssertEqual(d.destination, .arrival)
        XCTAssertTrue(d.keepDestination)
        XCTAssertEqual(d.fuel, .hidden, "у цели заправки — лишнее")
        XCTAssertEqual(d.places, .none)
        XCTAssertFalse(d.decor)
        XCTAssertEqual(P.decide(phone(car(remaining: 900, seconds: 140))).parking,
                       .destination(AppConfig.mapDetailArrivalParkingsPhone), "телефон — плотнее")
    }

    func testArrivalStandingBringsNeighbourhoodBack() {
        let d = P.decide(car(standing: true, remaining: 300, seconds: 60))
        XCTAssertEqual(d.mode, .arrival, "стоя у цели — всё ещё прибытие")
        XCTAssertTrue(d.decor)
        XCTAssertEqual(d.places, .none, "в машине значков заведений нет и у цели")
        XCTAssertEqual(P.decide(phone(car(standing: true, remaining: 300, seconds: 60))).places, .top)
    }

    func testLongRouteShowsOnlyNearestAlongTheWay() {
        let moving = P.decide(car(remaining: 250_000, seconds: 10_000, routeMeters: 280_000))
        XCTAssertEqual(moving.mode, .longRoute)
        XCTAssertEqual(moving.corridor, AppConfig.mapDetailCorridorCar)
        XCTAssertFalse(moving.corridorFood, "на ходу — только топливо")
        XCTAssertEqual(moving.fuel, .hidden, "городских значков по линии на трассе нет")
        XCTAssertEqual(moving.places, .none)
        let standing = P.decide(car(standing: true, remaining: 250_000, seconds: 10_000, routeMeters: 280_000))
        XCTAssertEqual(standing.mode, .standing)
        XCTAssertTrue(standing.corridorFood, "стоя — и кафе с гостиницами")
        XCTAssertEqual(P.decide(phone(car(remaining: 250_000, seconds: 10_000, routeMeters: 280_000))).corridor,
                       AppConfig.mapDetailCorridorPhone)
    }

    func testWithoutRouteFuelNearbyNoNoise() {
        let d = P.decide(car(route: false))
        XCTAssertEqual(d.mode, .free)
        XCTAssertEqual(d.fuel, .nearby)
        XCTAssertEqual(d.places, .none)
        XCTAssertEqual(d.parking, .hidden)
        XCTAssertEqual(d.destination, .none)
    }

    func testDashboardAndClusterShowOnlyRouteAndCameras() {
        for surface in [P.Surface.dashboard, .cluster] {
            var c = car(standing: true, remaining: 500, seconds: 60)
            c.surface = surface
            let d = P.decide(c)
            XCTAssertEqual(d.mode, .glance)
            XCTAssertFalse(d.decor)
            XCTAssertEqual(d.places, .none)
            XCTAssertFalse(d.houseNumbers)
            XCTAssertEqual(d.fuel, .hidden)
            XCTAssertEqual(d.parking, .hidden)
            XCTAssertEqual(d.corridor, 0)
            XCTAssertEqual(d.destination, .flag, "флаг — конец маршрута, без ореола и парковок")
            XCTAssertTrue(MapDetailPlaces.marks(d, found: Self.found).isEmpty)
        }
    }

    func testPhoneOutsideTripIsUnchanged() {
        var c = phone(car(standing: false))
        c.tripActive = false
        XCTAssertEqual(P.decide(c), .browse)
        XCTAssertTrue(MapDetailLayers.hidden(.browse).isEmpty, "вне поездки ничего не прячем")
    }

    // MARK: - Ночь, жара, тревога, бак

    func testNightAndHotThinOut() {
        var c = phone(car(standing: true))
        c.night = true
        XCTAssertEqual(P.decide(c).places, .none, "ночью стоя — на ряд меньше: без значков")
        var a = phone(car(remaining: 500, seconds: 60))
        a.night = true
        XCTAssertEqual(P.decide(a).parking, .destination(AppConfig.mapDetailArrivalParkingsPhone - 1))
        a.night = false
        a.hot = true
        let hot = P.decide(a)
        XCTAssertEqual(hot.parking, .destination(AppConfig.mapDetailHotLimit))
        XCTAssertEqual(hot.places, .none)
        var m = car()
        m.hot = true
        XCTAssertLessThanOrEqual(P.decide(m).fuel.aheadLimit, AppConfig.mapDetailHotLimit)
    }

    func testCameraAlertCoverHidesPlaces() {
        var c = phone(car(standing: true))
        c.covered = true
        XCTAssertEqual(P.decide(c).places, .none)
    }

    func testLowFuelIsNeverInvented() {
        let unknown = P.decide(car(remaining: 250_000, seconds: 10_000, routeMeters: 280_000))
        XCTAssertEqual(unknown.fuel, .hidden, "нет данных о баке — не выдумываем")
        var low = car(remaining: 250_000, seconds: 10_000, routeMeters: 280_000)
        low.fuelLow = true
        XCTAssertGreaterThan(P.decide(low).fuel.aheadLimit, 0, "бак на исходе — заправки по пути и на трассе")
    }

    // MARK: - Подъезд к цели: гистерезис

    func testArrivalEntersByDistanceOrByTimeOnlyNearby() {
        XCTAssertTrue(P.isArriving(car(remaining: 1_500, seconds: 400)))
        XCTAssertFalse(P.isArriving(car(remaining: 1_600, seconds: 400)))
        XCTAssertTrue(P.isArriving(car(remaining: 2_200, seconds: 170)), "пробка у цели — по времени")
        XCTAssertFalse(P.isArriving(car(remaining: 4_500, seconds: 170)), "три минуты трассы — ещё рано")
    }

    func testArrivalDoesNotFlickerAtTheEdge() {
        XCTAssertTrue(P.isArriving(car(remaining: 1_700, seconds: 300, wasArriving: true)),
                      "между порогами — держим")
        XCTAssertFalse(P.isArriving(car(remaining: 1_900, seconds: 300, wasArriving: true)))
        XCTAssertTrue(P.isArriving(car(remaining: 1_900, seconds: 200, wasArriving: true)),
                      "далеко, но минуты — ещё прибытие")
    }

    func testNoArrivalWithoutRoute() {
        XCTAssertFalse(P.isArriving(car(route: false)))
        XCTAssertFalse(P.isArriving(car(route: false, wasArriving: true)), "цель есть только с маршрутом")
    }

    func testRerouteAtDestinationKeepsArrival() {
        // Перестроение у цели: остаток застыл или маршрута на миг нет —
        // решение не отскакивает в «на ходу» ни на одно перестроение.
        var rerouting = car(remaining: 0, seconds: 0, wasArriving: true)
        rerouting.routePending = true
        XCTAssertEqual(P.decide(rerouting).mode, .arrival)
        var rebuilding = car(route: false, wasArriving: true)
        rebuilding.routePending = true
        XCTAssertEqual(P.decide(rebuilding).mode, .arrival)
        // Не было прибытия — перестроение его не включает.
        var fresh = car(remaining: 9_000, seconds: 900)
        fresh.routePending = true
        XCTAssertNotEqual(P.decide(fresh).mode, .arrival)
    }

    func testArrivalSequenceAlongTheDrive() {
        var arriving = false
        var modes: [P.Mode] = []
        for (meters, seconds) in [(3_000.0, 360.0), (1_600, 200), (1_400, 170), (1_700, 210), (900, 120),
                                  (200, 40)] {
            let d = P.decide(car(remaining: meters, seconds: seconds, wasArriving: arriving))
            arriving = d.isArrival
            modes.append(d.mode)
        }
        XCTAssertEqual(modes, [.moving, .moving, .arrival, .arrival, .arrival, .arrival])
    }

    // MARK: - Слои

    func testCamerasRouteAndRoadEventsAreNeverManaged() {
        let untouchable = ["camera-halo", "camera-dot", "camera-icons", "camera-badges", "camera-label",
                           "route", "route-case", "route-core", "route-traveled", "route-maneuver",
                           "route-arrows", "route-traffic", "traffic", "road-events", "marks",
                           "radar-camera-zone", "user-location", "traffic-signals",
                           EngineModernStyleIDs.trafficLight]
        for id in untouchable {
            XCTAssertFalse(MapDetailLayers.managed.contains(id), "\(id) решению недоступен")
        }
    }

    func testLayersFollowDecision() {
        let moving = P.decide(car())
        let hidden = MapDetailLayers.hidden(moving)
        XCTAssertTrue(hidden.contains("poi-level-1"))
        XCTAssertTrue(hidden.contains("radar-poi-fuel"), "по пути — наши значки, слой тайлов прячется")
        XCTAssertTrue(hidden.contains("trees"))
        let arrival = P.decide(car(remaining: 500, seconds: 60))
        let shown = MapDetailLayers.shown(arrival)
        XCTAssertTrue(shown.contains("housenumber"))
        XCTAssertTrue(shown.contains("radar-parking"), "контуры стоянок у цели")
        XCTAssertFalse(shown.contains("radar-poi-parking"), "значки — наши, ближайшая крупнее")
        XCTAssertTrue(MapDetailLayers.shown(arrival, destinationParkingsKnown: false).contains("radar-poi-parking"),
                      "своих данных нет — значки тайлов, а не пустота")
    }

    func testCarHidesPathsAlwaysAndOnewayOnTheMove() {
        // 40J (D11–D12): переходы и дорожки в машине не мигают на светофорах,
        // стрелки одностороннего — только стоя.
        let moving = MapDetailLayers.carHidden(P.decide(car()))
        let standing = MapDetailLayers.carHidden(P.decide(car(standing: true, route: false)))
        XCTAssertTrue(moving.contains("radar-oneway"))
        XCTAssertFalse(standing.contains("radar-oneway"))
        for id in ["tunnel-path", "highway-path", "bridge-path"] {
            XCTAssertTrue(moving.contains(id), id)
            XCTAssertTrue(standing.contains(id), id)
        }
        XCTAssertTrue(Set(MapDetailLayers.carPaths).isSubset(of: Set(MapDetailLayers.decor)))
        let untouchable = ["camera-icons", "camera-label", "route", "traffic", "road-events", "radar-camera-zone"]
        for id in untouchable {
            XCTAssertFalse(moving.contains(id), id)
            XCTAssertFalse(MapDetailLayers.carManaged.contains(id), id)
        }
    }

    // MARK: - Значки

    private static let found = MapDetailPlaces.Found(
        fuelAhead: (0..<4).map { Venue(kind: .fuel, name: "F\($0)", point: .init(latitude: 41.3 + Double($0) * 0.01, longitude: 69.2)) },
        parkings: (0..<6).map { Venue(kind: .parking, name: "P\($0)", point: .init(latitude: 41.32, longitude: 69.2 + Double($0) * 0.001)) },
        corridor: [Venue(kind: .food, name: "Kafe", point: .init(latitude: 41.0, longitude: 68.0)),
                   Venue(kind: .fuel, name: "AZS", point: .init(latitude: 40.9, longitude: 67.9)),
                   Venue(kind: .hotel, name: "Hotel", point: .init(latitude: 40.8, longitude: 67.8))])

    func testMarksRespectLimitsAndRank() {
        let arrival = MapDetailPlaces.marks(P.decide(car(remaining: 500, seconds: 60)), found: Self.found)
        XCTAssertEqual(arrival.count, AppConfig.mapDetailArrivalParkingsCar)
        XCTAssertEqual(arrival.map(\.rank), [0, 1, 2], "ближайшая к цели — главная")
        XCTAssertTrue(arrival.allSatisfy { $0.kind == .parking })
        let moving = MapDetailPlaces.marks(P.decide(car()), found: Self.found)
        XCTAssertEqual(moving.count, AppConfig.mapDetailFuelAheadCar)
        let long = MapDetailPlaces.marks(P.decide(car(remaining: 250_000, seconds: 10_000, routeMeters: 280_000)),
                                         found: Self.found)
        XCTAssertEqual(long.map(\.kind), [.fuel], "на ходу по трассе — только топливо из «По пути»")
    }
}

/// Имя светофора приложения — то же, что ставит стиль.
private enum EngineModernStyleIDs {
    static let trafficLight = "radar-traffic-light"
}
