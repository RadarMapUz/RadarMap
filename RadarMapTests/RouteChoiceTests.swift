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

    /// 29.E: ничего личного не выбрано — вариант без пары разворотов и
    /// левых через встречку предлагается первым, если стоит не больше
    /// max(1 мин, 5 %); дороже — решает человек.
    func testSimplerIsRecommendedWhenItCostsAMinute() {
        var verdict = RouteChoice.decide([input(line(5000), minutes: 20, hard: 5),
                                          input(line(5000, north: 300), minutes: 21, hard: 2)],
                                         history: nil)
        XCTAssertTrue(verdict.assessments[1].labels.contains(.simpler))
        XCTAssertEqual(verdict.recommended, 1, "минута за три сложных манёвра — дёшево")

        verdict = RouteChoice.decide([input(line(5000), minutes: 20, hard: 5),
                                      input(line(5000, north: 300), minutes: 22, hard: 2)],
                                     history: nil)
        XCTAssertTrue(verdict.assessments[1].labels.contains(.simpler), "ярлык остаётся")
        XCTAssertEqual(verdict.recommended, 0, "две минуты на 20 — дороже 5 %: решает человек")

        // На длинном пути допуск — доля: 5 % от часа — три минуты.
        verdict = RouteChoice.decide([input(line(5000), minutes: 60, hard: 5),
                                      input(line(5000, north: 300), minutes: 62.5, hard: 2)],
                                     history: nil)
        XCTAssertEqual(verdict.recommended, 1)
    }

    func testSimplerDoesNotOverrideFamiliar() {
        let tracks = Array(repeating: track(5000), count: 4)
        let verdict = RouteChoice.decide([input(line(5000, north: 300), minutes: 20, hard: 5),
                                          input(line(5000), minutes: 21, hard: 5),
                                          input(line(5000, north: 600), minutes: 20.5, hard: 1)],
                                         history: RouteChoice.History(tracks: tracks, overspeedCameraIDs: []))
        XCTAssertTrue(verdict.assessments[1].labels.contains(.familiar))
        XCTAssertEqual(verdict.recommended, 1, "своя привычка — выше простоты")
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

    // MARK: - Моя дорога (24.4)

    private func personal(minutes: Double?, jam: Double = 0) -> RouteChoice.Personal {
        RouteChoice.Personal(direction: .toHome, trips: 12, seconds: minutes.map { $0 * 60 }, jamSeconds: jam)
    }

    func testMyRoadLeadsTheLabelsAndIsChosen() {
        var mine = input(line(5000, north: 300), minutes: 11)
        mine.personal = personal(minutes: 12)
        let verdict = RouteChoice.decide([input(line(5000), minutes: 10), mine], history: nil)
        XCTAssertEqual(verdict.assessments[1].labels.first, .myRoad)
        XCTAssertEqual(verdict.assessments[1].myRoad, personal(minutes: 12))
        XCTAssertEqual(verdict.recommended, 1, "+2 мин своей дорогой — выбираем её")
    }

    func testMyRoadOutranksFamiliarAndFastestInItsChip() {
        let history = RouteChoice.History(tracks: Array(repeating: track(5000, north: 300), count: 4),
                                          overspeedCameraIDs: [])
        var mine = input(line(5000, north: 300), minutes: 9)
        mine.personal = personal(minutes: 9)
        let verdict = RouteChoice.decide([input(line(5000), minutes: 10), mine], history: history)
        XCTAssertEqual(verdict.assessments[1].labels.prefix(2), [.myRoad, .familiar])
        XCTAssertTrue(verdict.assessments[1].labels.contains(.fastest))
    }

    func testMyRoadIsComparedWithTheFastestInTraffic() {
        // Быстрый по движку — 30 мин, сегодня с пробками 40; своя дорога по
        // своей истории — 42. Против голых 30 это +12 (не выбрали бы), против
        // 40 с пробками — +2, в пределах max(3 мин, 10 %).
        var mine = input(line(5000, north: 300), minutes: 45)
        mine.personal = personal(minutes: 42)
        let jammed = RouteChoice.decide([input(line(5000), minutes: 40), mine], history: nil)
        XCTAssertEqual(jammed.recommended, 1)
        let free = RouteChoice.decide([input(line(5000), minutes: 30), mine], history: nil)
        XCTAssertEqual(free.recommended, 0, "своя дорога на 12 мин дольше быстрого — решать человеку")
        XCTAssertTrue(free.assessments[1].labels.contains(.myRoad), "ярлык остаётся — выбор за водителем")
    }

    func testMyRoadWithoutOwnTimeUsesEngineTime() {
        var mine = input(line(5000, north: 300), minutes: 11)
        mine.personal = personal(minutes: nil)
        XCTAssertEqual(RouteChoice.decide([input(line(5000), minutes: 10), mine], history: nil).recommended, 1)
        mine = input(line(5000, north: 300), minutes: 20)
        mine.personal = personal(minutes: nil)
        XCTAssertEqual(RouteChoice.decide([input(line(5000), minutes: 10), mine], history: nil).recommended, 0)
    }

    func testClosureOnMyRoadStillDefersToACleanVariant() {
        var mine = input(line(5000, north: 300), minutes: 10)
        mine.personal = personal(minutes: 10)
        mine.closures = 1
        let verdict = RouteChoice.decide([input(line(5000), minutes: 11), mine], history: nil)
        XCTAssertEqual(verdict.assessments[1].labels.prefix(2), [.blocked, .myRoad])
        XCTAssertEqual(verdict.recommended, 0, "перекрытие важнее привычки")
    }

    func testSingleVariantOnMyRoadKeepsItsLabel() {
        var mine = input(line(5000), minutes: 10)
        mine.personal = personal(minutes: 11)
        let verdict = RouteChoice.decide([mine], history: nil)
        XCTAssertEqual(verdict.assessments[0].labels, [.myRoad])
        XCTAssertEqual(verdict.assessments[0].myRoad?.trips, 12)
    }

    // MARK: - «Знакомый» по профилю дороги (24.4)

    func testFamiliarCountsCommuteProfileLines() {
        // Треков за неделю нет вовсе — а своя линия за полтора месяца проезжена 6 раз.
        let profileLine = RouteChoice.WeightedLine(line: line(5000, north: 300), trips: 6)
        let history = RouteChoice.History(tracks: [], overspeedCameraIDs: [], commuteLines: [profileLine])
        let verdict = RouteChoice.decide([input(line(5000), minutes: 10),
                                          input(line(5000, north: 300), minutes: 11)], history: history)
        XCTAssertTrue(verdict.assessments[1].labels.contains(.familiar))
        XCTAssertEqual(verdict.assessments[1].familiarTrips, 6)
        XCTAssertEqual(verdict.recommended, 1)
    }

    func testHistoryCountsProfileTripsOnceAlongsideTracks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func row(_ id: Double, daysAgo: Double) -> CommuteProfile.Row {
            CommuteProfile.Row(tripID: id, departure: now.addingTimeInterval(-daysAgo * 86400),
                               weekend: false, arrivalMinute: 0, seconds: [20])
        }
        // Поездка 2 дня назад — и трек в истории, и строка профиля: считается раз.
        let recent = now.addingTimeInterval(-2 * 86400)
        var trip = TripRecord(id: recent.timeIntervalSince1970, startedAt: recent,
                              endedAt: recent.addingTimeInterval(1200), distanceMeters: 5000,
                              maxSpeedKmh: 60, passed: [])
        trip.track = track(5000, north: 300)
        var packed: [Int32] = []
        for c in line(5000, north: 300) {
            packed.append(Int32((c.latitude * 1e5).rounded()))
            packed.append(Int32((c.longitude * 1e5).rounded()))
        }
        var book = CommuteProfile.Book()
        book.toHome = [CommuteProfile.Variant(id: UUID(), line: packed, ends: [5000], limitKmh: [],
                                              rows: [row(recent.timeIntervalSince1970, daysAgo: 2),
                                                     row(1, daysAgo: 10), row(2, daysAgo: 20), row(3, daysAgo: 40)],
                                              lastUsed: now)]
        let history = RouteChoice.history(from: [trip], profile: book, now: now)
        XCTAssertEqual(history.tracks.count, 1)
        XCTAssertEqual(history.commuteLines.map(\.trips), [3], "строка поездки с треком не считается второй раз")
        let verdict = RouteChoice.decide([input(line(5000), minutes: 10),
                                          input(line(5000, north: 300), minutes: 11)], history: history)
        XCTAssertEqual(verdict.assessments[1].familiarTrips, 4)
        XCTAssertNil(RouteChoice.history(from: [trip], profile: nil, now: now).commuteLines.first)
    }
}
