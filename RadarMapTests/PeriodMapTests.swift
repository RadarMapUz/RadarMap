//
//  PeriodMapTests.swift
//  RadarMapTests
//
//  Карта проездов: слой частоты («тепло») и данные одной выбранной поездки.
//  Слой частоты — то, что убирает паутину из наложенных треков, поэтому его
//  математика (сетка, подсчёт РАЗНЫХ поездок, нарезка на куски одного градуса)
//  проверяется здесь, а не глазами на симуляторе.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class PeriodMapTests: XCTestCase {

    private let base = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)

    /// Прямой трек на восток: `points` точек с шагом `stepMeters`.
    private func track(points: Int, stepMeters: Double = 100,
                       bearing: Double = 90) -> [TrackPoint] {
        (0..<points).map { step in
            let p = GeoMath.destination(from: base, bearing: bearing,
                                        distanceMeters: Double(step) * stepMeters)
            return TrackPoint(lat: p.latitude, lon: p.longitude, speedKmh: 60)
        }
    }

    // MARK: - Градусы частоты

    func testSingleTrackIsRareTier() async {
        let lines = await TripHistory.heatLines([track(points: 10)])
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.allSatisfy { $0.tier == 0 },
                      "одна поездка — фоновая линия, а не постоянный коридор")
        XCTAssertTrue(lines.allSatisfy { $0.times == 1 })
    }

    func testRepeatedCorridorIsMiddleTier() async {
        let commute = track(points: 10)
        let lines = await TripHistory.heatLines([commute, commute])
        XCTAssertTrue(lines.allSatisfy { $0.times == 2 })
        XCTAssertTrue(lines.allSatisfy { $0.tier == 1 })
    }

    func testFrequentCorridorReachesTopTier() async {
        let commute = track(points: 10)
        let lines = await TripHistory.heatLines(Array(repeating: commute,
                                                count: AppConfig.heatFrequentTimes))
        XCTAssertTrue(lines.allSatisfy { $0.tier == 2 },
                      "\(AppConfig.heatFrequentTimes) проездов — яркий коридор")
    }

    /// Съездил и вернулся по той же улице в ОДНОЙ поездке — это всё ещё один
    /// проезд коридора, иначе любая поездка «туда и обратно» врала бы про частоту.
    func testReturnTripInsideOneRecordCountsOnce() async {
        let there = track(points: 8)
        let backAndForth = there + there.reversed()
        let lines = await TripHistory.heatLines([backAndForth])
        XCTAssertTrue(lines.allSatisfy { $0.times == 1 })
    }

    /// Частичное наложение: общая половина становится ярче, продолжение остаётся
    /// фоновым — и трек режется на куски, а не красится целиком по максимуму.
    func testPartialOverlapSplitsTrackIntoTiers() async {
        let long = track(points: 20)
        let short = Array(long.prefix(10))
        let lines = await TripHistory.heatLines([long, short])

        XCTAssertTrue(lines.contains { $0.tier == 1 }, "общий участок — повторяющийся")
        XCTAssertTrue(lines.contains { $0.tier == 0 }, "продолжение — фоновое")
        XCTAssertGreaterThanOrEqual(lines.filter { $0.points.count >= 2 }.count, 2)
        // Куски рисуются от редких к частым: яркая линия ложится поверх фоновой.
        XCTAssertEqual(lines.map(\.tier), lines.map(\.tier).sorted())
    }

    func testAdjacentStreetsDoNotShareCells() async {
        // Параллельная улица в 120 м: в сетку 20 м она не попадает.
        let lines = await TripHistory.heatLines([track(points: 10),
                                           track(points: 10).map {
                                               let p = GeoMath.destination(
                                                   from: CLLocationCoordinate2D(latitude: $0.lat,
                                                                                longitude: $0.lon),
                                                   bearing: 0, distanceMeters: 120)
                                               return TrackPoint(lat: p.latitude, lon: p.longitude,
                                                                 speedKmh: 60)
                                           }])
        XCTAssertTrue(lines.allSatisfy { $0.times == 1 },
                      "соседняя улица не должна делать коридор частым")
    }

    func testHeatLinesIgnoreDegenerateTracks() async {
        let empty = await TripHistory.heatLines([])
        let emptyTrack = await TripHistory.heatLines([[]])
        let onePoint = await TripHistory.heatLines([track(points: 1)])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(emptyTrack.isEmpty)
        XCTAssertTrue(onePoint.isEmpty, "из одной точки линию не построить")
    }

    /// Куски идут без разрывов: конец одного равен началу следующего.
    func testRunsShareBoundaryPoints() async {
        let long = track(points: 12)
        let lines = await TripHistory.heatLines([long, Array(long.prefix(6))])
            .sorted { $0.id < $1.id }
        let ofLongTrack = lines.filter { $0.points.count >= 2 }
        guard ofLongTrack.count >= 2 else { return XCTFail("трек должен разрезаться") }
        let first = ofLongTrack[0], second = ofLongTrack[1]
        XCTAssertEqual(first.points.last?.lat ?? 0, second.points.first?.lat ?? 1,
                       accuracy: 1e-9, "граничная точка входит в оба куска")
    }

    // MARK: - Устойчивость к шуму

    /// Два прохода по одной улице с дрожанием GPS ±25 м: частота участков
    /// «прыгает», но сглаживание не даёт развалить трек на десятки кусков.
    func testNoisyRepeatIsNotShreddedIntoManyLines() async {
        let clean = track(points: 60, stepMeters: 40)
        let noisy = clean.enumerated().map { index, point -> TrackPoint in
            let shifted = GeoMath.destination(
                from: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon),
                bearing: index % 2 == 0 ? 0 : 180, distanceMeters: 25)
            return TrackPoint(lat: shifted.latitude, lon: shifted.longitude, speedKmh: 60)
        }
        let lines = await TripHistory.heatLines([clean, noisy])
        XCTAssertLessThanOrEqual(lines.count, 12,
                                 "шум не должен резать трек на куски: \(lines.count)")
        XCTAssertLessThanOrEqual(lines.count, AppConfig.heatMaxLines)
    }

    func testMedianSmoothingRemovesSingleDips() {
        let smoothed = TripHistory.medianSmoothed([3, 3, 1, 3, 3, 3])
        XCTAssertEqual(smoothed, [3, 3, 3, 3, 3, 3], "одиночный провал затирается")
    }

    func testMedianSmoothingKeepsRealTransition() {
        let smoothed = TripHistory.medianSmoothed([5, 5, 5, 5, 1, 1, 1, 1])
        XCTAssertEqual(smoothed.first, 5)
        XCTAssertEqual(smoothed.last, 1, "настоящий переход частоты сохраняется")
    }

    // MARK: - Данные выбранной поездки

    private func record(cameraIDs: [Int], withTrack: Bool = true) -> TripRecord {
        let points = track(points: 10)
        let passes = cameraIDs.enumerated().map { index, id in
            PassedCamera(id: UUID(), cameraID: id, typeRaw: "Стационар радар",
                         location: "Камера \(id)", speedKmh: index == 0 ? 95 : 55,
                         date: Date(timeIntervalSince1970: 1e9 + Double(index)),
                         lat: points[index + 1].lat, lon: points[index + 1].lon,
                         limitKmh: 60)
        }
        return TripRecord(id: 1, startedAt: Date(timeIntervalSince1970: 1e9),
                          endedAt: Date(timeIntervalSince1970: 1e9 + 600),
                          distanceMeters: 900, maxSpeedKmh: 95, passed: passes,
                          track: withTrack ? points.flatMap { [$0.lat, $0.lon, $0.speedKmh] }
                                           : nil)
    }

    func testMapDataOfRecordHasOwnTrackAndMarkersWithoutHeat() {
        let data = TripHistory.mapData(of: record(cameraIDs: [10, 11]))
        XCTAssertEqual(data.tracks.count, 1)
        XCTAssertEqual(data.markers.count, 2, "маркеры — только камеры этой поездки")
        XCTAssertTrue(data.heat.isEmpty, "для одной поездки частота не считается")
        XCTAssertFalse(data.isEmpty)
    }

    func testMapDataOfRecordWithoutTrackKeepsMarkers() {
        let data = TripHistory.mapData(of: record(cameraIDs: [10], withTrack: false))
        XCTAssertTrue(data.tracks.isEmpty)
        XCTAssertEqual(data.markers.count, 1)
    }

    func testPassMarkersOfRecordFlagViolation() {
        let markers = TripHistory.passMarkers(of: record(cameraIDs: [10, 11]))
        XCTAssertEqual(markers.filter(\.hasViolation).count, 1, "95 при лимите 60 — превышение")
        XCTAssertEqual(markers.filter { !$0.hasViolation }.count, 1)
    }

    /// Строка списка спрашивает это на каждый пересчёт — проверка должна быть
    /// по плоскому массиву, без разбора трека в структуры.
    func testHasTrackMatchesDrawableTrack() {
        XCTAssertTrue(record(cameraIDs: [10]).hasTrack)
        XCTAssertFalse(record(cameraIDs: [10], withTrack: false).hasTrack)
        let onePoint = TripRecord(id: 2, startedAt: Date(), endedAt: Date(),
                                  distanceMeters: 0, maxSpeedKmh: 0, passed: [],
                                  track: [41.3, 69.2, 10])
        XCTAssertFalse(onePoint.hasTrack, "одна точка — рисовать нечего")
    }
}
