//
//  TripCheckpointTests.swift
//  RadarMapTests
//
//  Чекпоинт живой поездки: слепок с диска превращается в запись истории так,
//  как finish() превратил бы её сам — накат не теряется при смерти процесса.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class TripCheckpointTests: XCTestCase {

    private let started = Date(timeIntervalSince1970: 1_800_000_000)

    /// Сырой трек прямой улицы: точка каждые ~100 м, скорость постоянная.
    private func flatTrack(points: Int, speed: Double = 55) -> [Double] {
        (0..<points).flatMap { [41.30, 69.20 + Double($0) * 0.001, speed] }
    }

    private func pass(_ speed: Double, limit: Int?) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: 7, typeRaw: "Стационар радар",
                     location: "Юнусабад", speedKmh: speed, date: started,
                     lat: 41.30, lon: 69.21, limitKmh: limit)
    }

    private func snapshot(distance: Double, track: [Double],
                          passed: [PassedCamera] = [],
                          stops: [TripStop] = []) -> TripStats.InflightTrip {
        TripStats.InflightTrip(
            startedAt: started, lastPointAt: started.addingTimeInterval(600),
            distanceMeters: distance, maxSpeedKmh: 72,
            passed: passed, stops: stops, track: track,
            endLat: 41.30, endLon: 69.25)
    }

    func testRecordKeepsDistancePassesAndAllowsMerge() {
        let record = TripStats.record(from: snapshot(
            distance: 5_200, track: flatTrack(points: 52),
            passed: [pass(58, limit: 60)]))

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.distanceMeters ?? 0, 5_200, accuracy: 0.1)
        XCTAssertEqual(record?.passed.count, 1)
        XCTAssertEqual(record?.maxSpeedKmh ?? 0, 72, accuracy: 0.1)
        XCTAssertEqual(record?.id ?? 0, started.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(record?.endedAt, started.addingTimeInterval(600))
        // «Завершить» никто не нажимал: следующий автозапуск имеет право
        // склеиться с этой записью через TripMerge.
        XCTAssertEqual(record?.endedManually, false)
        // Точка финиша — чтобы склейка и «повторить маршрут» работали.
        XCTAssertEqual(record?.endLat ?? 0, 41.30, accuracy: 0.001)
    }

    func testRecordComputesScoreLikeFinish() {
        let passedList = [pass(88, limit: 60)]   // +28 → −25 по ступеням
        let record = TripStats.record(from: snapshot(
            distance: 5_200, track: flatTrack(points: 52), passed: passedList))
        let expected = DrivingScore.tripScore(
            passes: passedList.map { DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh) },
            trackSpeeds: (0..<52).map { _ in 55 })
        XCTAssertEqual(record?.score, expected)
    }

    func testRecordSimplifiesTrackButKeepsEnds() {
        let record = TripStats.record(from: snapshot(distance: 9_900,
                                                     track: flatTrack(points: 100)))
        let points = record?.trackPoints ?? []
        // Прямая из 100 точек сжимается Дугласом-Пекером до концов.
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.first?.lon ?? 0, 69.20, accuracy: 0.0001)
        XCTAssertEqual(points.last?.lon ?? 0, 69.299, accuracy: 0.0001)
    }

    func testShortTripIsDiscarded() {
        // Порог тот же, что в finish(): меньше 100 м — не поездка.
        XCTAssertNil(TripStats.record(from: snapshot(distance: 60,
                                                     track: flatTrack(points: 2))))
    }

    func testStopsSurviveRestore() {
        let stop = TripStop(id: UUID(), lat: 41.30, lon: 69.22,
                            from: started.addingTimeInterval(100),
                            to: started.addingTimeInterval(400))
        let record = TripStats.record(from: snapshot(
            distance: 3_000, track: flatTrack(points: 30), stops: [stop]))
        XCTAssertEqual(record?.stops?.count, 1)
        // Стоянка исключается из «в движении» — средняя скорость честная.
        XCTAssertEqual(record?.movingDuration ?? 0, 300, accuracy: 0.5)
    }

    func testSnapshotRoundTripsThroughJSON() throws {
        let original = snapshot(distance: 5_200, track: flatTrack(points: 52),
                                passed: [pass(58, limit: 60)])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TripStats.InflightTrip.self, from: data)
        XCTAssertEqual(decoded.distanceMeters, original.distanceMeters)
        XCTAssertEqual(decoded.track, original.track)
        XCTAssertEqual(decoded.passed.count, 1)
    }
}
