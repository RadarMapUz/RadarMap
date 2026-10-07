//
//  RouteChoiceTests.swift
//  RadarMapTests
//
//  Ярлыки вариантов маршрута и выбор первого. Тесты держат то, что делает
//  ярлык честным: «Знакомый» — только при заметном перевесе и после
//  нескольких поездок; параллельная улица знакомой не становится; ничья
//  ярлыка не даёт; привычка не выбирается, если стоит много времени.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class RouteChoiceTests: XCTestCase {

    private let lat0 = 41.30
    private let lon0 = 69.20
    /// Метров в градусе долготы на широте теста.
    private var lonMeters: Double { 111_320 * cos(lat0 * .pi / 180) }

    /// Прямая на восток длиной `meters`, смещённая к северу на `north` м.
    private func line(_ meters: Double, north: Double = 0) -> [CLLocationCoordinate2D] {
        let lat = lat0 + north / 111_320
        return stride(from: 0.0, through: meters, by: 100).map {
            CLLocationCoordinate2D(latitude: lat, longitude: lon0 + $0 / lonMeters)
        }
    }

    /// Упрощённый трек как в TripRecord: две точки по краям прямой.
    private func track(_ meters: Double, north: Double = 0) -> [Double] {
        let lat = lat0 + north / 111_320
        return [lat, lon0, 40, lat, lon0 + meters / lonMeters, 40]
    }

    private func input(_ path: [CLLocationCoordinate2D], minutes: Double, km: Double? = nil,
                       cameras: [Int] = [], hard: Int? = 0) -> RouteChoice.Input {
        RouteChoice.Input(path: path, distance: (km ?? 5) * 1000, travelTime: minutes * 60,
                          cameraIDs: cameras, hardManeuvers: hard)
    }

    // MARK: - Знакомость

    func testTrackOnSameRoadCoversItAndParallelStreetDoesNot() {
        let tracks = Array(repeating: track(5000), count: 3)
        let result = RouteChoice.familiarity(of: [line(5000), line(5000, north: 150)], tracks: tracks)
        XCTAssertGreaterThan(result[0].share, 0.95, "упрощённый трек заполняется между точками")
        XCTAssertEqual(result[0].trips, 3)
        XCTAssertEqual(result[1].share, 0, "улица в 150 м — не та же дорога")
        XCTAssertEqual(result[1].trips, 0)
    }

    func testGpsNoiseWithinLaneStillCounts() {
        let result = RouteChoice.familiarity(of: [line(5000)], tracks: [track(5000, north: 20)])
        XCTAssertGreaterThan(result[0].share, 0.95)
    }

    func testPartialOverlapIsNotATrip() {
        // Трек прошёл треть пути: доля есть, поездкой «этим путём» не считается.
        let result = RouteChoice.familiarity(of: [line(6000)], tracks: [track(2000)])
        XCTAssertGreaterThan(result[0].share, 0.2)
        XCTAssertLessThan(result[0].share, 0.5)
        XCTAssertEqual(result[0].trips, 0)
    }

    // MARK: - Ярлыки

    func testSingleVariantGetsNoLabels() {
        let verdict = RouteChoice.decide([input(line(5000), minutes: 10)], history: nil)
        XCTAssertEqual(verdict.assessments, [.none])
        XCTAssertEqual(verdict.recommended, 0)
    }

    func testFamiliarIsRecommendedWhenCheap() {
        let history = RouteChoice.History(tracks: Array(repeating: track(5000, north: 300), count: 4),
                                          overspeedCameraIDs: [])
        let verdict = RouteChoice.decide([input(line(5000), minutes: 10),
                                          input(line(5000, north: 300), minutes: 12)],
                                         history: history)
        XCTAssertEqual(verdict.assessments[0].labels, [.fastest])
        XCTAssertEqual(verdict.assessments[1].labels, [.familiar])
        XCTAssertEqual(verdict.assessments[1].familiarTrips, 4)
        XCTAssertEqual(verdict.recommended, 1, "+2 минуты за привычный путь — выбираем его")
    }

    func testFamiliarCostingTooMuchIsOfferedNotChosen() {
        let history = RouteChoice.History(tracks: Array(repeating: track(5000, north: 300), count: 4),
                                          overspeedCameraIDs: [])
        let verdict = RouteChoice.decide([input(line(5000), minutes: 10),
                                          input(line(5000, north: 300), minutes: 20)],
                                         history: history)
        XCTAssertTrue(verdict.assessments[1].labels.contains(.familiar))
        XCTAssertEqual(verdict.recommended, 0, "привычка ценой 10 минут — решать человеку")
    }

    func testFamiliarNeedsSeveralTripsAndAMargin() {
        let once = RouteChoice.History(tracks: [track(5000, north: 300)], overspeedCameraIDs: [])
        var verdict = RouteChoice.decide([input(line(5000), minutes: 10),
                                          input(line(5000, north: 300), minutes: 11)], history: once)
        XCTAssertFalse(verdict.assessments[1].labels.contains(.familiar), "одна поездка — ещё не привычка")

        // Оба пути знакомы одинаково — ярлык ничего не различает.
        let both = RouteChoice.History(
            tracks: Array(repeating: track(5000), count: 3) + Array(repeating: track(5000, north: 300), count: 3),
            overspeedCameraIDs: [])
        verdict = RouteChoice.decide([input(line(5000), minutes: 10),
                                      input(line(5000, north: 300), minutes: 11)], history: both)
        XCTAssertFalse(verdict.assessments.contains { $0.labels.contains(.familiar) })
        XCTAssertEqual(verdict.recommended, 0)
    }

    func testFewerCamerasAndTieGivesNothing() {
        var verdict = RouteChoice.decide([input(line(5000), minutes: 10, cameras: [1, 2, 3]),
                                          input(line(5000, north: 300), minutes: 12, cameras: [4])],
                                         history: nil)
        XCTAssertTrue(verdict.assessments[1].labels.contains(.fewerCameras))

        verdict = RouteChoice.decide([input(line(5000), minutes: 10, cameras: [1, 2, 3]),
                                      input(line(5000, north: 300), minutes: 12, cameras: [4]),
                                      input(line(5000, north: 600), minutes: 13, cameras: [5])],
                                     history: nil)
        XCTAssertFalse(verdict.assessments.contains { $0.labels.contains(.fewerCameras) },
                       "два варианта с одной камерой — «меньше» у обоих, значит ни у кого")
    }

    func testAvoidsYourOverspeedCameras() {
        let history = RouteChoice.History(tracks: [], overspeedCameraIDs: [2])
        let verdict = RouteChoice.decide([input(line(5000), minutes: 10, cameras: [1, 2]),
                                          input(line(5000, north: 300), minutes: 12, cameras: [3, 4])],
                                         history: history)
        XCTAssertEqual(verdict.assessments[0].overspeedCameras, 1)
        XCTAssertTrue(verdict.assessments[1].labels.contains(.avoidsOverspeed))
        XCTAssertFalse(verdict.assessments[1].labels.contains(.fewerCameras), "камер столько же")
        XCTAssertEqual(verdict.recommended, 0, "сам по себе этот ярлык быстрый вариант не отменяет")
    }

    func testSimplerOnlyWhenEveryEngineKnowsManeuvers() {
        var verdict = RouteChoice.decide([input(line(5000), minutes: 10, hard: 6),
                                          input(line(5000, north: 300), minutes: 11, hard: 2)],
                                         history: nil)
        XCTAssertTrue(verdict.assessments[1].labels.contains(.simpler))

        verdict = RouteChoice.decide([input(line(5000), minutes: 10, hard: 6),
                                      input(line(5000, north: 300), minutes: 11, hard: nil)],
                                     history: nil)
        XCTAssertFalse(verdict.assessments.contains { $0.labels.contains(.simpler) })
    }

    func testShortestNeedsANoticeableGain() {
        var verdict = RouteChoice.decide([input(line(5000), minutes: 10, km: 10),
                                          input(line(5000, north: 300), minutes: 12, km: 8)],
                                         history: nil)
        XCTAssertTrue(verdict.assessments[1].labels.contains(.shortest))

        verdict = RouteChoice.decide([input(line(5000), minutes: 10, km: 10),
                                      input(line(5000, north: 300), minutes: 12, km: 9.9)],
                                     history: nil)
        XCTAssertFalse(verdict.assessments[1].labels.contains(.shortest), "100 м — не «короткий»")
    }

    func testHardManeuversCount() {
        func step(_ kind: ManeuverKind?) -> RouteStep {
            RouteStep(distanceAlong: 0, text: "", icon: "", kind: kind)
        }
        XCTAssertEqual(RouteChoice.hardManeuvers([step(.left), step(.right), step(.uturn),
                                                  step(.roundabout), step(.arrive)]), 3)
        XCTAssertNil(RouteChoice.hardManeuvers([step(.left), step(nil)]))
    }

    /// Бюджет: полгода поездок против трёх вариантов по 30 км. На маке в
    /// отладочной сборке — ~17 мс; порог с запасом ловит порядок, а не шум.
    func testFamiliarityBudget() {
        let tracks = (0..<200).map { track(30_000, north: Double($0 % 7) * 10) }
        let paths = [line(30_000), line(30_000, north: 300), line(30_000, north: 600)]
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = RouteChoice.familiarity(of: paths, tracks: tracks) }
        XCTAssertLessThan(elapsed, .milliseconds(300))
    }

    // MARK: - История

    func testHistoryTakesWindowAndRealOverspeedOnly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func record(daysAgo: Double, speed: Double, camera: Int) -> TripRecord {
            let start = now.addingTimeInterval(-daysAgo * 86400)
            let pass = PassedCamera(id: UUID(), cameraID: camera, typeRaw: "Стационар радар",
                                    location: "", speedKmh: speed, date: start,
                                    lat: lat0, lon: lon0, limitKmh: 60)
            var trip = TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                                  endedAt: start.addingTimeInterval(1200), distanceMeters: 5000,
                                  maxSpeedKmh: 80, passed: [pass])
            trip.track = track(5000)
            return trip
        }
        let history = RouteChoice.history(from: [record(daysAgo: 1, speed: 85, camera: 1),
                                                 record(daysAgo: 2, speed: 61, camera: 2),
                                                 record(daysAgo: 400, speed: 90, camera: 3)],
                                          now: now)
        XCTAssertEqual(history.overspeedCameraIDs, [1], "61 при лимите 60 — в допуске; старое — вне окна")
        XCTAssertEqual(history.tracks.count, 2)
    }
}
