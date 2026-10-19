//
//  ReportPlacementTests.swift
//  RadarMapTests
//
//  Место отметки и судьба очереди без сети. Оба движка чистые, поэтому
//  проверяются целиком — а проверять есть что: снап на встречное полотно и
//  доставка получасовой отметки одинаково плохи, только по-разному.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class ReportPlacementTests: XCTestCase {

    // MARK: - Снап на ось

    /// Прямая дорога с юга на север через заданную долготу.
    private func northSouthRoad(lon: Double, kind: RoadClass = .primary) -> RoadLine {
        RoadLine(points: [CLLocationCoordinate2D(latitude: 41.30, longitude: lon),
                          CLLocationCoordinate2D(latitude: 41.32, longitude: lon)],
                 kind: kind)
    }

    func testPointOffTheAxisSnapsOntoIt() {
        // Телефон отдаёт координату с погрешностью и с задержкой реакции —
        // отметка обязана сесть на полотно, а не рядом с ним.
        let road = northSouthRoad(lon: 69.250)
        let raw = CLLocationCoordinate2D(latitude: 41.310, longitude: 69.2504)
        let placed = ReportPlacement.snapped(raw, course: 0, roads: [road], maxMeters: 60)
        XCTAssertNotNil(placed)
        XCTAssertEqual(placed!.coordinate.longitude, 69.250, accuracy: 1e-6)
        XCTAssertEqual(placed!.coordinate.latitude, 41.310, accuracy: 1e-6)
        XCTAssertEqual(placed!.roadClass, .primary)
    }

    /// Пока тайлов улиц нет, сеть — индекс лимитов: класса он не знает, но
    /// отметка обязана сесть и на его ось (vehicleNetwork, аудит 19.10).
    func testFallbackNetworkWithoutClassStillPlacesTheReport() {
        let limitLine = RoadLine(points: [CLLocationCoordinate2D(latitude: 41.30, longitude: 69.25),
                                          CLLocationCoordinate2D(latitude: 41.32, longitude: 69.25)])
        struct Lines: RoadNetworkSource {
            let lines: [RoadLine]
            func roads(near coordinate: CLLocationCoordinate2D, radius: CLLocationDistance) -> [RoadLine] { lines }
        }
        let network = FallbackRoadNetwork(primary: EmptyRoadNetwork(), fallback: Lines(lines: [limitLine]))
        let raw = CLLocationCoordinate2D(latitude: 41.310, longitude: 69.2504)
        let placed = ReportPlacement.snapped(raw, course: 0,
                                             roads: network.roads(near: raw, radius: 60), maxMeters: 60)
        XCTAssertEqual(placed?.coordinate.longitude ?? 0, 69.250, accuracy: 1e-6)

        // Тайлы есть, но двора водителя в них нет (дворы не качаем): объединение
        // с индексом лимитов сажает на свою улицу, а не на соседний проспект.
        let avenue = RoadLine(points: [CLLocationCoordinate2D(latitude: 41.30, longitude: 69.2509),
                                       CLLocationCoordinate2D(latitude: 41.32, longitude: 69.2509)],
                              kind: .primary)
        // «Первичный, иначе запасной» видел бы только проспект и сажал туда.
        let primaryOnly = FallbackRoadNetwork(primary: Lines(lines: [avenue]), fallback: Lines(lines: [limitLine]))
        let wrong = ReportPlacement.snapped(raw, course: 0,
                                            roads: primaryOnly.roads(near: raw, radius: 60), maxMeters: 60)
        XCTAssertEqual(wrong?.coordinate.longitude ?? 0, 69.2509, accuracy: 1e-6)
        let union = UnionRoadNetwork(sources: [Lines(lines: [avenue]), Lines(lines: [limitLine])])
        let own = ReportPlacement.snapped(raw, course: 0,
                                          roads: union.roads(near: raw, radius: 60), maxMeters: 60)
        XCTAssertEqual(own?.coordinate.longitude ?? 0, 69.250, accuracy: 1e-6)
    }

    func testRoadAlongCourseBeatsACloserCrossStreet() {
        // Развязка: поперечная улица ближе, но мы едем не по ней. Снап на неё
        // увёл бы отметку на дорогу, по которой никто из предупреждаемых не
        // поедет.
        let mine = northSouthRoad(lon: 69.2510)                     // по курсу, дальше
        let cross = RoadLine(points: [CLLocationCoordinate2D(latitude: 41.3101, longitude: 69.249),
                                      CLLocationCoordinate2D(latitude: 41.3101, longitude: 69.253)],
                             kind: .residential)                    // поперёк, ближе
        let raw = CLLocationCoordinate2D(latitude: 41.31005, longitude: 69.2505)
        let placed = ReportPlacement.snapped(raw, course: 0, roads: [mine, cross], maxMeters: 120)
        XCTAssertEqual(placed?.roadClass, .primary,
                       "снап ушёл на поперечную улицу, хотя едем не по ней")
    }

    func testUntrustedCourseFallsBackToTheNearestRoad() {
        // Курсу верить нельзя (стоим, спутники плывут) — выбор по направлению
        // выключается целиком, а не подставляет ноль градусов.
        let mine = northSouthRoad(lon: 69.2510)
        let cross = RoadLine(points: [CLLocationCoordinate2D(latitude: 41.3101, longitude: 69.249),
                                      CLLocationCoordinate2D(latitude: 41.3101, longitude: 69.253)],
                             kind: .residential)
        let raw = CLLocationCoordinate2D(latitude: 41.31005, longitude: 69.2505)
        let placed = ReportPlacement.snapped(raw, course: -1, roads: [mine, cross], maxMeters: 120)
        XCTAssertEqual(placed?.roadClass, .residential, "без курса берётся ближайшая")
    }

    func testFootwayIsNeverChosen() {
        // Радар стоит над проезжей частью. Тротуар рядом — не повод сажать
        // отметку на него: класс уедет в сервер и испортит радиус слияния.
        let footway = RoadLine(points: [CLLocationCoordinate2D(latitude: 41.3100, longitude: 69.2500),
                                        CLLocationCoordinate2D(latitude: 41.3120, longitude: 69.2500)],
                               kind: .pedestrian)
        let raw = CLLocationCoordinate2D(latitude: 41.310, longitude: 69.25005)
        XCTAssertNil(ReportPlacement.snapped(raw, course: 0, roads: [footway], maxMeters: 60))
    }

    func testNoRoadNearbyMeansNoSnapNotNoReport() {
        // Отметка обязана уйти с сырой координатой: промолчать о радаре хуже,
        // чем поставить его на десять метров мимо.
        let far = northSouthRoad(lon: 69.30)
        let raw = CLLocationCoordinate2D(latitude: 41.310, longitude: 69.250)
        XCTAssertNil(ReportPlacement.snapped(raw, course: 0, roads: [far], maxMeters: 40))
    }

    func testSnapNeverMovesFartherThanTheLimit() {
        let road = northSouthRoad(lon: 69.250)
        let raw = CLLocationCoordinate2D(latitude: 41.310, longitude: 69.2503)
        guard let placed = ReportPlacement.snapped(raw, course: 0, roads: [road],
                                                   maxMeters: 40) else {
            return XCTFail("дорога в пределах порога — снап обязан состояться")
        }
        let moved = GeoMath.fastDistance(raw.latitude, raw.longitude,
                                         placed.coordinate.latitude, placed.coordinate.longitude)
        XCTAssertLessThanOrEqual(moved, 40)
    }

    func testSinglePointRoadIsIgnored() {
        // Обрубок в один узел оси не задаёт — снап по нему был бы выдумкой.
        let stub = RoadLine(points: [CLLocationCoordinate2D(latitude: 41.310, longitude: 69.250)],
                            kind: .primary)
        let raw = CLLocationCoordinate2D(latitude: 41.310, longitude: 69.2501)
        XCTAssertNil(ReportPlacement.snapped(raw, course: 0, roads: [stub], maxMeters: 60))
    }

    // MARK: - Очередь без сети

    private func pending(_ minutesAgo: Double, kind: String = "radar",
                         lat: Double = 41.31, lon: Double = 69.25) -> PendingReport {
        PendingReport(kind: kind, lat: lat, lon: lon, cls: "primary",
                      at: Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60))
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testStaleReportIsDroppedRatherThanDelivered() {
        // Через час радар уехал, а мы бы предупредили: доставка здесь хуже
        // молчания. Тренога 20 минут назад — ещё стоит (S25: 15 минут
        // выбрасывали отметку с трассы без покрытия); ДТП — уже нет.
        let (send, expired) = ReportQueue.split([pending(50), pending(20), pending(25, kind: "accident"),
                                                 pending(2)], now: now)
        XCTAssertEqual(send.map(\.at), [pending(20).at, pending(2).at])
        XCTAssertEqual(expired.count, 2)
    }

    func testFreshQueueGoesOutWhole() {
        let (send, expired) = ReportQueue.split([pending(1), pending(3, kind: "tripod")], now: now)
        XCTAssertEqual(send.count, 2)
        XCTAssertTrue(expired.isEmpty)
    }

    func testRepeatedTapAtTheSameSpotDoesNotPileUp() {
        // Без сети человек жмёт ещё раз именно потому, что не понял, ушло ли.
        // Три копии одной засады на сервере — три точки на карте.
        var queue = ReportQueue.enqueued(pending(0), into: [])
        queue = ReportQueue.enqueued(pending(0), into: queue)
        XCTAssertEqual(queue.count, 1)
    }

    func testDifferentTypeAtTheSameSpotIsKept() {
        var queue = ReportQueue.enqueued(pending(0), into: [])
        queue = ReportQueue.enqueued(pending(0, kind: "accident"), into: queue)
        XCTAssertEqual(queue.count, 2, "ДТП рядом с радаром — разные события")
    }

    func testQueueKeepsTheFreshestWhenOverflowing() {
        var queue: [PendingReport] = []
        for index in 0..<6 {
            // Разные места, чтобы сработал не дубль-гейт, а именно потолок.
            queue = ReportQueue.enqueued(pending(0, lat: 41.31 + Double(index) * 0.05),
                                         into: queue)
        }
        XCTAssertEqual(queue.count, ReportQueue.limit)
        XCTAssertEqual(queue.last?.lat ?? 0, 41.31 + 5 * 0.05, accuracy: 1e-9,
                       "потолок обязан выбрасывать старые, а не новые")
    }

    func testEmptyQueueIsHandled() {
        let (send, expired) = ReportQueue.split([], now: now)
        XCTAssertTrue(send.isEmpty)
        XCTAssertTrue(expired.isEmpty)
    }
    // MARK: - Отступ назад на время реакции

    private var here: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 41.31, longitude: 69.25)
    }

    private func metres(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    func testMarkLandsWhereTheDriverWasTwoSecondsAgo() {
        // Отметку ставят, ПРОЕХАВ объект: пока палец идёт к экрану, машина
        // уезжает. На 110 км/ч две секунды — это 61 метр.
        let back = ReportPlacement.backdated(here, course: 0, speedKmh: 110)
        XCTAssertEqual(metres(here, back), 61, accuracy: 3)
        XCTAssertLessThan(back.latitude, here.latitude,
                          "курс на север — отметка обязана лечь южнее, то есть позади")
    }

    func testNoCourseNoShift() {
        // Недостоверный курс — двигать не по чему, и выдумывать направление
        // хуже, чем оставить точку на месте.
        XCTAssertEqual(metres(here, ReportPlacement.backdated(here, course: -1, speedKmh: 110)), 0,
                       accuracy: 0.01)
    }

    func testStandingStillIsNotShifted() {
        XCTAssertEqual(metres(here, ReportPlacement.backdated(here, course: 0, speedKmh: 5)), 0,
                       accuracy: 0.01)
    }

    func testShiftHasACeiling() {
        let wild = ReportPlacement.backdated(here, course: 90, speedKmh: 400)
        XCTAssertLessThanOrEqual(metres(here, wild), ReportPlacement.maxBackdateMeters + 1,
                                 "выброс скорости не должен унести отметку за перекрёсток")
    }

}
