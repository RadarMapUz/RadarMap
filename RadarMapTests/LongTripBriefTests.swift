//
//  LongTripBriefTests.swift
//  RadarMapTests
//
//  «Перед дальней дорогой» (12.4): камеры и посты по порядку вдоль пути и
//  одним местом — одной строкой; в плане только наши, впереди и живые;
//  самый длинный отрезок без своего топлива считается от машины до цели и
//  НЕ обещается, когда данных о заведениях на весь путь нет; области по
//  ходу со своим состоянием.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class LongTripBriefTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func camera(_ id: Int, _ type: String = "Стационар радар", expires: Date? = nil) -> Camera {
        Camera(id: id, region: "Сырдарьинская область", city: "", location: "М39, \(id)",
               lat: 40.5, lon: 68.7, type: type, violations: [], needsReview: nil,
               mobileConfirmed: expires == nil ? nil : true, mobileExpires: expires)
    }

    private func marker(_ id: Int, _ along: Double, _ type: String = "Стационар радар",
                        oncoming: Bool = false, expires: Date? = nil) -> LongTripBrief.Marker {
        LongTripBrief.Marker(camera: camera(id, type, expires: expires), along: along, oncoming: oncoming)
    }

    private func item(_ kind: Venue.Kind, _ along: Double, offset: Double = 100, name: String = "") -> CorridorVenues.Item {
        CorridorVenues.Item(venue: Venue(kind: kind, name: name,
                                         point: CLLocationCoordinate2D(latitude: 40 + along / 1e7, longitude: 68)),
                            along: along, offset: offset)
    }

    // MARK: - Камеры и посты

    func testOrderAlongTheRouteAndOnePlaceOneRow() {
        let markers = [marker(4, 5_000), marker(1, 1_000), marker(2, 1_100, "Пост ДПС"), marker(3, 1_250)]
        let points = LongTripBrief.checkpoints(markers, progress: 0, now: now)
        XCTAssertEqual(points.map { $0.cameras.map(\.id) }, [[1, 2, 3], [4]],
                       "три точки у поста — одна строка, следующая через 4 км — своя")
        XCTAssertEqual(points[0].along, 1_000, "километр строки — первая точка места")
        XCTAssertEqual(points[0].lead.id, 2, "пост ДПС — заголовок места, хоть он и не первый по ходу")
        XCTAssertEqual(points[0].others, 2)
        XCTAssertEqual(points[0].category, .post)
    }

    func testGroupIsMeasuredFromItsStartNotChained() {
        // 0 → 250 → 500 → 750: цепочкой «каждая в 250 м от соседней» склеилась
        // бы в одну строку на 750 м; группа меряется от своего начала.
        let markers = [0.0, 250, 500, 750].enumerated().map { marker($0.offset + 1, $0.element) }
        let points = LongTripBrief.checkpoints(markers, progress: 0, now: now, groupMeters: 300)
        XCTAssertEqual(points.map { $0.cameras.map(\.id) }, [[1, 2], [3, 4]])
    }

    func testCrowdOutranksCameraButNotPost() {
        let points = LongTripBrief.checkpoints([marker(1, 100), marker(2, 150, "Тренога", expires: now + 3_600)],
                                               progress: 0, now: now)
        XCTAssertEqual(points.first?.lead.id, 2, "отметка водителей ищется глазами раньше камеры")
        XCTAssertEqual(points.first?.category, .crowd)
    }

    func testOnlyOursAheadAndAlive() {
        let markers = [marker(1, 500),                                    // позади машины
                       marker(2, 3_000, oncoming: true),                  // доказанно встречная
                       marker(3, 4_000, "ДТП"),                           // живёт час
                       marker(4, 5_000, "Передвижной радар", expires: now - 60), // срок вышел
                       marker(5, 6_000, "Передвижной радар", expires: now + 600),
                       marker(6, 7_000)]
        let points = LongTripBrief.checkpoints(markers, progress: 1_000, now: now)
        XCTAssertEqual(points.map(\.id), [5, 6])
    }

    func testSameCameraTwiceIsOneRow() {
        let points = LongTripBrief.checkpoints([marker(1, 2_000), marker(1, 2_000), marker(2, 9_000)],
                                               progress: 0, now: now)
        XCTAssertEqual(points.map { $0.cameras.count }, [1, 1])
    }

    func testTallyCountsEveryPointOfEveryPlace() {
        let markers = [marker(1, 1_000), marker(2, 1_100, "Пост ДПС"), marker(3, 1_200, "Интеллектуал + радар"),
                       marker(4, 40_000, "Тренога", expires: now + 600), marker(5, 90_000, "Пост ДПС")]
        let tally = LongTripBrief.tally(LongTripBrief.checkpoints(markers, progress: 0, now: now))
        XCTAssertEqual(tally, LongTripBrief.Tally(cameras: 2, posts: 2, crowd: 1))
        XCTAssertTrue(LongTripBrief.Tally().isEmpty)
    }

    func testEmptyRouteHasNoCheckpoints() {
        XCTAssertTrue(LongTripBrief.checkpoints([], progress: 0, now: now).isEmpty)
    }

    // MARK: - Отрезок без заправки

    func testLongestGapBetweenStations() {
        let gap = LongTripBrief.longestGap([50_000, 60_000, 200_000], from: 0, to: 300_000)
        XCTAssertEqual(gap, LongTripBrief.Gap(from: 60_000, to: 200_000))
        XCTAssertEqual(gap?.meters, 140_000)
    }

    func testGapCountsFromTheCarAndToTheDestination() {
        XCTAssertEqual(LongTripBrief.longestGap([150_000], from: 0, to: 200_000),
                       LongTripBrief.Gap(from: 0, to: 150_000), "до первой заправки тоже надо доехать")
        XCTAssertEqual(LongTripBrief.longestGap([20_000], from: 0, to: 200_000),
                       LongTripBrief.Gap(from: 20_000, to: 200_000), "и от последней — до цели")
    }

    func testNoStationsIsTheWholeWayAndNoWayIsNoGap() {
        XCTAssertEqual(LongTripBrief.longestGap([], from: 10_000, to: 300_000),
                       LongTripBrief.Gap(from: 10_000, to: 300_000))
        XCTAssertNil(LongTripBrief.longestGap([5_000], from: 300_000, to: 300_000))
    }

    func testStationsBehindTheCarDoNotShortenTheGap() {
        let gap = LongTripBrief.longestGap([10_000, 100_000], from: 50_000, to: 120_000)
        XCTAssertEqual(gap, LongTripBrief.Gap(from: 50_000, to: 100_000))
    }

    // MARK: - Заправки по топливу машины

    func testFuelPerKindInTheCarsOrder() {
        let items = [item(.fuel, 10_000), item(.cng, 30_000), item(.hotel, 40_000), item(.cng, 120_000)]
        let fuel = LongTripBrief.fuel(items, kinds: VehicleEnergy.cng.stops, progress: 0,
                                      routeLength: 300_000, complete: true)
        XCTAssertEqual(fuel.map(\.kind), [.cng, .fuel], "машина на метане: сначала метан, бензин запасом")
        XCTAssertEqual(fuel[0].items.map(\.along), [30_000, 120_000], "гостиница — не заправка")
        XCTAssertEqual(fuel[0].gap, LongTripBrief.Gap(from: 120_000, to: 300_000))
    }

    func testIncompleteDataNeverPromisesAGap() {
        // Клетка без файла — не «заправок нет»: обещание «дальше 180 км
        // ничего» на ней было бы враньём.
        let fuel = LongTripBrief.fuel([item(.cng, 30_000)], kinds: [.cng], progress: 0,
                                      routeLength: 300_000, complete: false)
        XCTAssertEqual(fuel.first?.items.count, 1, "найденное всё равно показываем")
        XCTAssertNil(fuel.first?.gap)
    }

    func testCompleteDataWithoutStationsIsTheWholeRoute() {
        let fuel = LongTripBrief.fuel([item(.fuel, 30_000)], kinds: [.lpg], progress: 0,
                                      routeLength: 250_000, complete: true)
        XCTAssertTrue(fuel[0].items.isEmpty)
        XCTAssertEqual(fuel[0].gap, LongTripBrief.Gap(from: 0, to: 250_000))
    }

    func testFuelKindsAreNotRepeated() {
        let fuel = LongTripBrief.fuel([], kinds: [.fuel, .fuel], progress: 0, routeLength: 1, complete: true)
        XCTAssertEqual(fuel.map(\.kind), [.fuel])
    }

    // MARK: - Области

    private func region(_ id: String, bytes: Int64 = 10_000_000) -> RegionCatalog.Region {
        RegionCatalog.Region(id: id, name: ["ru": id], bbox: [], cells: 1, rows: [],
                             files: ["mvt": RegionCatalog.File(file: id, bytes: bytes, sha256: "")])
    }

    func testRegionsKeepTheCorridorOrderWithTheirStatus() {
        let corridor = [region("tashkent"), region("sirdaryo"), region("jizzax"), region("samarqand")]
        let states: [String: LongTripBrief.RegionStatus] = ["tashkent": .ready, "sirdaryo": .updateAvailable,
                                                            "jizzax": .downloading(0.4), "samarqand": .missing]
        let plan = LongTripBrief.regions(corridor) { states[$0.id] ?? .missing }
        XCTAssertEqual(plan.rows.map(\.id), ["tashkent", "sirdaryo", "jizzax", "samarqand"])
        XCTAssertEqual(plan.onPhone, 2, "старый выпуск области рисуется без связи так же")
        XCTAssertEqual(plan.missing, 1)
        XCTAssertTrue(plan.downloading)
        XCTAssertFalse(plan.allOnPhone)
    }

    func testAllOnPhoneNeedsRegions() {
        XCTAssertTrue(LongTripBrief.regions([region("a")]) { _ in .ready }.allOnPhone)
        XCTAssertFalse(LongTripBrief.regions([]) { _ in .ready }.allOnPhone, "нет коридора — не «всё на телефоне»")
    }

    // MARK: - Лист целиком

    func testMakeAssemblesEverything() async {
        let brief = await LongTripBrief.build(markers: [marker(1, 2_000), marker(2, 2_100, "Пост ДПС")],
                                              venues: [item(.fuel, 50_000)], kinds: [.fuel],
                                              progress: 0, routeLength: 120_000, venuesComplete: true, now: now)
        XCTAssertEqual(brief.checkpoints.count, 1)
        XCTAssertEqual(brief.tally, LongTripBrief.Tally(cameras: 1, posts: 1, crowd: 0))
        XCTAssertEqual(brief.fuel.first?.gap, LongTripBrief.Gap(from: 50_000, to: 120_000))
        XCTAssertTrue(brief.venuesComplete)
    }

    func testOnlyLongRoutesGetTheBrief() {
        XCTAssertFalse(RouteCorridor.isLong(40_000), "город из конца в конец")
        XCTAssertTrue(RouteCorridor.isLong(300_000), "Ташкент — Самарканд")
    }
}

/// Подписи листа: склонения и место отрезка словами.
@MainActor
final class LongTripTextTests: XCTestCase {

    private func camera(_ id: Int, _ type: String) -> Camera {
        Camera(id: id, region: "", city: "", location: "М39", lat: 40.5, lon: 68.7, type: type,
               violations: [], needsReview: nil)
    }

    func testTallyDeclinesEveryPart() {
        XCTAssertEqual(LongTripText.tally(LongTripBrief.Tally(cameras: 21, posts: 3, crowd: 5)),
                       "21\u{00A0}камера · 3\u{00A0}поста ДПС · 5\u{00A0}отметок водителей")
        XCTAssertEqual(LongTripText.tally(LongTripBrief.Tally(cameras: 0, posts: 1, crowd: 0)), "1\u{00A0}пост ДПС",
                       "пустые части молчат")
        XCTAssertEqual(LongTripText.crowdLabel(2), "отметки водителей")
        XCTAssertEqual(LongTripText.postsLabel(11), "постов ДПС")
    }

    func testPlaceTitleNamesTheOthers() {
        let place = LongTripBrief.Checkpoint(along: 47_000,
                                             cameras: [camera(1, "Стационар радар"), camera(2, "Пост ДПС"),
                                                       camera(3, "Стационар камера")],
                                             lead: camera(2, "Пост ДПС"))
        XCTAssertEqual(LongTripText.title(place), "Пост ДПС · ещё 2\u{00A0}камеры")
        let lone = LongTripBrief.Checkpoint(along: 1, cameras: [camera(1, "Стационар радар")],
                                            lead: camera(1, "Стационар радар"))
        XCTAssertEqual(LongTripText.title(lone), "Стационарный радар")
    }

    func testGapDetailSaysWhereTheStretchIs() {
        func d(_ meters: Double) -> String { LongTripText.km(meters) }
        XCTAssertEqual(LongTripText.gapDetail(LongTripBrief.Gap(from: 60_000, to: 200_000), progress: 0,
                                              routeLength: 300_000), "от \(d(60_000)) до \(d(200_000)) от старта")
        XCTAssertEqual(LongTripText.gapDetail(LongTripBrief.Gap(from: 0, to: 90_000), progress: 0,
                                              routeLength: 300_000), "от старта до \(d(90_000))")
        XCTAssertEqual(LongTripText.gapDetail(LongTripBrief.Gap(from: 120_000, to: 300_000), progress: 0,
                                              routeLength: 300_000), "от \(d(120_000)) до конца пути")
        XCTAssertEqual(LongTripText.gapDetail(LongTripBrief.Gap(from: 0, to: 300_000), progress: 0,
                                              routeLength: 300_000), "весь путь")
    }

    func testKilometreIsWholeOnTheHighway() {
        XCTAssertEqual(LongTripText.km(47_000), "47\u{00A0}км", "столб у дороги, а не «47,0 км»")
        XCTAssertEqual(LongTripText.km(117_400), "117\u{00A0}км")
        XCTAssertEqual(LongTripText.km(1_400), Formatting.distance(1_400), "в городе — с десятой, как везде")
        XCTAssertEqual(LongTripText.km(443), Formatting.distance(443))
    }

    func testGapTitleNamesTheFuel() {
        XCTAssertEqual(LongTripText.gapTitle(.cng, meters: 112_000),
                       "Дольше всего без метана — \(Formatting.distance(112_000))")
        XCTAssertEqual(LongTripText.gapTitle(.fuel, meters: 30_000),
                       "Дольше всего без заправки — \(Formatting.distance(30_000))")
    }

    func testVenueDetailRoadsideAndOffset() {
        let roadside = CorridorVenues.Item(venue: Venue(kind: .cng, name: "",
                                                        point: CLLocationCoordinate2D(latitude: 40, longitude: 68)),
                                           along: 10_000, offset: 40)
        XCTAssertEqual(LongTripText.venueDetail(roadside), "у дороги")
        let named = CorridorVenues.Item(venue: Venue(kind: .cng, name: "AGNKS Guliston",
                                                     point: CLLocationCoordinate2D(latitude: 40, longitude: 68)),
                                        along: 10_000, offset: 1_200)
        XCTAssertEqual(LongTripText.venueDetail(named), "Метан · \(Formatting.distance(1_200)) от дороги")
    }
}
