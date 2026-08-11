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
        // Через полчаса радар уехал, а мы бы предупредили: доставка здесь
        // хуже молчания.
        let (send, expired) = ReportQueue.split([pending(20), pending(2)], now: now)
        XCTAssertEqual(send.count, 1)
        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(send.first?.at, pending(2).at)
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
}
