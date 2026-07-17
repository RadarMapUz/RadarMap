//
//  DrivingScoreTests.swift
//  RadarMapTests
//
//  Рейтинг вождения, штрафная арифметика ст. 128-3 КоАО и пожизненные счётчики.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class DrivingScoreTests: XCTestCase {

    // MARK: - Штрафные ступени

    func testFineTiers() {
        // В допуске — штрафа нет.
        XCTAssertEqual(FineSchedule.fine(overKmh: -10), 0)
        XCTAssertEqual(FineSchedule.fine(overKmh: 0), 0)
        XCTAssertEqual(FineSchedule.fine(overKmh: 5), 0)
        // до +20 → 1 БРВ
        XCTAssertEqual(FineSchedule.fine(overKmh: 6), FineSchedule.brv)
        XCTAssertEqual(FineSchedule.fine(overKmh: 20), FineSchedule.brv)
        // +20…40 → 5 БРВ
        XCTAssertEqual(FineSchedule.fine(overKmh: 21), 5 * FineSchedule.brv)
        XCTAssertEqual(FineSchedule.fine(overKmh: 40), 5 * FineSchedule.brv)
        // свыше 40 → 9 БРВ
        XCTAssertEqual(FineSchedule.fine(overKmh: 41), 9 * FineSchedule.brv)
    }

    // MARK: - Балл поездки

    private func smoothSpeeds(_ count: Int = 60) -> [Double] {
        (0..<count).map { 60 + Double($0 % 3) }   // перепады ~1 км/ч
    }

    func testPerfectTripScores100() {
        let passes = [DrivingScore.Pass(speedKmh: 58, limitKmh: 60),
                      DrivingScore.Pass(speedKmh: 61, limitKmh: 60)]
        let score = DrivingScore.tripScore(passes: passes, trackSpeeds: smoothSpeeds())
        XCTAssertEqual(score ?? 0, 100, accuracy: 0.5)
    }

    func testHeavyOverspeedTanksScore() {
        let passes = [DrivingScore.Pass(speedKmh: 115, limitKmh: 60),   // > +40: -40
                      DrivingScore.Pass(speedKmh: 90, limitKmh: 60)]    // +30: -25
        let score = DrivingScore.tripScore(passes: passes, trackSpeeds: smoothSpeeds())
        XCTAssertNotNil(score)
        XCTAssertLessThanOrEqual(score!, 40)
    }

    func testHarshDrivingPenalized() {
        // Рваный темп: перепады по 12 км/ч на каждом шаге.
        let jerky = (0..<60).map { $0 % 2 == 0 ? 48.0 : 60.0 }
        let smooth = DrivingScore.tripScore(passes: [], trackSpeeds: smoothSpeeds())!
        let harsh = DrivingScore.tripScore(passes: [], trackSpeeds: jerky)!
        XCTAssertGreaterThan(smooth, harsh)
        XCTAssertEqual(smooth, 100, accuracy: 0.5)
    }

    func testNoDataGivesNil() {
        XCTAssertNil(DrivingScore.tripScore(passes: [], trackSpeeds: []))
        // Проезды без лимитов и короткий трек — тоже нет вердикта.
        let passes = [DrivingScore.Pass(speedKmh: 90, limitKmh: nil)]
        XCTAssertNil(DrivingScore.tripScore(passes: passes, trackSpeeds: [50, 51]))
    }

    // MARK: - Пожизненные счётчики и серия

    func testLifetimeAccumulationAndSavings() {
        var stats = LifetimeStats()
        let passes = [DrivingScore.Pass(speedKmh: 58, limitKmh: 60),    // чисто → экономия
                      DrivingScore.Pass(speedKmh: 75, limitKmh: 60),    // +15 → 1 БРВ риска
                      DrivingScore.Pass(speedKmh: 80, limitKmh: nil)]   // без лимита — не считается
        stats = LifetimeStats.updated(stats, passes: passes, distanceMeters: 12_000)

        XCTAssertEqual(stats.trips, 1)
        XCTAssertEqual(stats.distanceMeters, 12_000)
        XCTAssertEqual(stats.camerasPassed, 3)
        XCTAssertEqual(stats.camerasInLimit, 1)
        XCTAssertEqual(stats.savedFinesSum, FineSchedule.minimumFine)
        XCTAssertEqual(stats.riskFinesSum, FineSchedule.brv)
        XCTAssertEqual(stats.cleanStreak, 0)   // был штрафной проезд — серия сброшена
    }

    func testCleanStreakGrowsAndResets() {
        var stats = LifetimeStats()
        let clean = [DrivingScore.Pass(speedKmh: 55, limitKmh: 60)]
        let dirty = [DrivingScore.Pass(speedKmh: 90, limitKmh: 60)]
        let noData: [DrivingScore.Pass] = []

        stats = LifetimeStats.updated(stats, passes: clean, distanceMeters: 1000)
        stats = LifetimeStats.updated(stats, passes: clean, distanceMeters: 1000)
        XCTAssertEqual(stats.cleanStreak, 2)

        // Поездка без лимитных камер серию не трогает.
        stats = LifetimeStats.updated(stats, passes: noData, distanceMeters: 1000)
        XCTAssertEqual(stats.cleanStreak, 2)

        stats = LifetimeStats.updated(stats, passes: dirty, distanceMeters: 1000)
        XCTAssertEqual(stats.cleanStreak, 0)
        XCTAssertEqual(stats.bestStreak, 2)
    }

    // MARK: - Достижения

    func testAchievementsProgress() {
        var stats = LifetimeStats()
        stats.distanceMeters = 150_000   // 150 км
        stats.camerasInLimit = 60
        stats.bestStreak = 3

        let badges = Achievements.all(for: stats)
        XCTAssertEqual(badges.count, 9)
        XCTAssertTrue(badges.first { $0.id == "km100" }!.earned)
        XCTAssertFalse(badges.first { $0.id == "km1000" }!.earned)
        XCTAssertTrue(badges.first { $0.id == "clean50" }!.earned)
        XCTAssertFalse(badges.first { $0.id == "streak5" }!.earned)
        XCTAssertEqual(badges.first { $0.id == "streak5" }!.fraction, 0.6, accuracy: 0.01)
    }
}

// MARK: - Чистка истории

final class HistoryPruneTests: XCTestCase {
    private func record(daysAgo: Double, withTrack: Bool = true) -> TripRecord {
        TripRecord(id: daysAgo, startedAt: Date().addingTimeInterval(-daysAgo * 86400),
                   endedAt: Date().addingTimeInterval(-daysAgo * 86400 + 600),
                   distanceMeters: 5000, maxSpeedKmh: 70, passed: [],
                   endLat: 41, endLon: 69,
                   track: withTrack ? [41, 69, 50, 41.01, 69.01, 55] : nil,
                   score: 90)
    }

    func testPruneKeepsSevenFullThenStripsTracksAndDropsOld() {
        // 12 поездок: 10 свежих + 2 старше месяца.
        var history = (0..<10).map { record(daysAgo: Double($0)) }
        history.append(record(daysAgo: 35))
        history.append(record(daysAgo: 40))

        let pruned = TripHistory.pruned(history)

        // Старше 30 дней — удалены (кроме случаев в первой семёрке).
        XCTAssertEqual(pruned.count, 10)
        // Первые 7 — с треками (для просмотра).
        for i in 0..<7 { XCTAssertNotNil(pruned[i].track, "поездка \(i) должна сохранить трек") }
        // Дальше — только цифры для статистики.
        for i in 7..<pruned.count { XCTAssertNil(pruned[i].track, "поездка \(i) должна потерять трек") }
        // Баллы и дистанции не тронуты.
        XCTAssertEqual(pruned[8].score, 90)
        XCTAssertEqual(pruned[8].distanceMeters, 5000)
    }

    func testPruneKeepsRecentSevenEvenIfOld() {
        // Все поездки древние — но первые 7 остаются целиком (список не пустеет).
        let history = (0..<9).map { record(daysAgo: Double(40 + $0)) }
        let pruned = TripHistory.pruned(history)
        XCTAssertEqual(pruned.count, 7)
        XCTAssertNotNil(pruned[0].track)
    }
}

// MARK: - Аналитика истории (данные экрана Итогов)

final class TripAnalyticsTests: XCTestCase {
    private func record(daysAgo: Double, km: Double, hour: Int = 12,
                        passes: [PassedCamera] = [], score: Double? = 90) -> TripRecord {
        let start = Calendar.current.date(byAdding: .day, value: -Int(daysAgo), to: Date())!
        let at = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: start)!
        return TripRecord(id: at.timeIntervalSince1970, startedAt: at,
                          endedAt: at.addingTimeInterval(1800),
                          distanceMeters: km * 1000, maxSpeedKmh: 70, passed: passes,
                          endLat: nil, endLon: nil, track: nil, score: score)
    }

    func testWeekDailyFillsSevenDaysWithZeros() {
        let history = [record(daysAgo: 0, km: 12), record(daysAgo: 0, km: 8),
                       record(daysAgo: 2, km: 30)]
        let daily = TripHistory.weekDaily(history)

        XCTAssertEqual(daily.count, 7)                    // нулевые дни не выпадают
        XCTAssertEqual(daily.last?.km ?? 0, 20, accuracy: 0.01)   // сегодня: 12+8
        XCTAssertEqual(daily[4].km, 30, accuracy: 0.01)   // позавчера
        XCTAssertEqual(daily[3].km, 0)                    // пустой день — ноль, не дырка
    }

    func testDayGroupsKeepOrderAndGroupByCalendarDay() {
        let history = [record(daysAgo: 0, km: 5, hour: 19), record(daysAgo: 0, km: 3, hour: 9),
                       record(daysAgo: 1, km: 7)]
        let groups = TripHistory.dayGroups(history)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].records.count, 2)        // обе сегодняшние вместе
        XCTAssertEqual(groups[1].records.count, 1)
        // Порядок внутри дня — как в истории (новые сверху).
        XCTAssertEqual(groups[0].records.map(\.id), history.prefix(2).map(\.id))
    }

    func testWeekSummaryCountsOnlyRecentTrips() {
        let history = [record(daysAgo: 1, km: 10), record(daysAgo: 20, km: 99)]
        let week = TripHistory.weekSummary(history)

        XCTAssertEqual(week?.trips, 1)
        XCTAssertEqual(week?.distance ?? 0, 10_000, accuracy: 0.01)
        XCTAssertNil(TripHistory.weekSummary([record(daysAgo: 20, km: 99)]))
    }

    func testFallbackRecordOnlyWhenSessionIsCold() {
        let last = record(daysAgo: 0, km: 5)
        // Поездка идёт — фолбэк не нужен, показываем живые метрики.
        XCTAssertNil(TripHistory.fallbackRecord(history: [last], isTripActive: true, liveDistance: 0))
        // Сессия уже что-то намерила — тоже живые.
        XCTAssertNil(TripHistory.fallbackRecord(history: [last], isTripActive: false, liveDistance: 800))
        // Холодный запуск — последняя запись истории вместо нулей.
        XCTAssertEqual(TripHistory.fallbackRecord(history: [last], isTripActive: false,
                                                  liveDistance: 0)?.id, last.id)
    }

    func testMonth30CountsCleanOverRiskAndTopLocation() {
        let clean = PassedCamera(id: UUID(), cameraID: 1, typeRaw: "Стационар радар", location: "",
                                 speedKmh: 55, date: Date(), lat: nil, lon: nil, limitKmh: 60)
        let fined = PassedCamera(id: UUID(), cameraID: 2, typeRaw: "Стационар радар",
                                 location: "Navoiy ko'chasi",
                                 speedKmh: 80, date: Date(), lat: nil, lon: nil, limitKmh: 60)
        let noLimit = PassedCamera(id: UUID(), cameraID: 3, typeRaw: "Стационар радар", location: "",
                                   speedKmh: 90, date: Date(), lat: nil, lon: nil, limitKmh: nil)
        let history = [record(daysAgo: 1, km: 10, passes: [clean, fined, noLimit])]

        let month = TripHistory.month30(history)
        XCTAssertEqual(month.clean, 1)                       // без лимита — не считается
        XCTAssertEqual(month.over, 1)
        // +20 км/ч — верхняя граница первой ступени: 1 БРВ.
        XCTAssertEqual(month.risk, FineSchedule.brv)
        XCTAssertEqual(month.topOverLocation, "Navoiy ko'chasi")
        XCTAssertEqual(TripHistory.fineRisk(of: [clean, fined, noLimit]), FineSchedule.brv)
    }

    func testMonth30IgnoresOldRecords() {
        let fined = PassedCamera(id: UUID(), cameraID: 2, typeRaw: "Стационар радар", location: "",
                                 speedKmh: 80, date: Date(), lat: nil, lon: nil, limitKmh: 60)
        let history = [record(daysAgo: 40, km: 10, passes: [fined])]
        let month = TripHistory.month30(history)
        XCTAssertEqual(month.over, 0)
        XCTAssertEqual(month.risk, 0)
    }
}

// MARK: - Скорость проезда: зона измерения

final class PassSpeedTests: XCTestCase {
    func testMeasuredSpeedIsMinimumOfApproachZone() {
        // Притормозил у камеры (57), газанул после — разгон не должен попасть в оценку.
        let zone: [(dist: Double, speed: Double)] = [(72, 64), (45, 57), (12, 61)]
        XCTAssertEqual(PassTracking.measuredSpeed(zone: zone, fallback: 70), 57)
    }

    func testMeasuredSpeedFallsBackWhenZoneEmpty() {
        // Редкие GPS-фиксы: ни одного сэмпла в зоне — берём скорость траверза.
        XCTAssertEqual(PassTracking.measuredSpeed(zone: [], fallback: 66), 66)
    }
}

// MARK: - Направление на камеру

final class CameraDirectionTests: XCTestCase {
    func testWideAheadDeadZoneSwallowsSmallOffset() {
        // ±40° от курса — «прямо»: смещённая вбок точка камеры не читается как «сбоку».
        XCTAssertEqual(CameraDirection.classify(relativeBearing: 0), .ahead)
        XCTAssertEqual(CameraDirection.classify(relativeBearing: 35), .ahead)
        XCTAssertEqual(CameraDirection.classify(relativeBearing: 325), .ahead)
        // За зоной — уже сторона.
        XCTAssertEqual(CameraDirection.classify(relativeBearing: 60), .right)
        XCTAssertEqual(CameraDirection.classify(relativeBearing: 300), .left)
    }

    func testBehindClassification() {
        XCTAssertEqual(CameraDirection.classify(relativeBearing: 160), .behindRight)
        XCTAssertEqual(CameraDirection.classify(relativeBearing: 200), .behindLeft)
    }

    func testArrowSnapsUpWhenAhead() {
        // «Прямо» — стрелка строго вверх (0), без дрожи от бокового смещения.
        XCTAssertEqual(CameraDirection.arrowAngle(relativeBearing: 30), 0)
        // «Сбоку» — реальный азимут.
        XCTAssertEqual(CameraDirection.arrowAngle(relativeBearing: 90), 90)
    }

    func testSmootherMovesGraduallyAndWrapsShortestArc() {
        var s = AngleSmoother(factor: 0.5)
        XCTAssertEqual(s.update(10), 10)            // первая проба — как есть
        XCTAssertEqual(s.update(30), 20, accuracy: 0.001)   // на полпути к 30
        // Кратчайшая дуга через 0: от 350 к 10 — это +20°, а не −340°.
        var w = AngleSmoother(factor: 0.5)
        _ = w.update(350)
        XCTAssertEqual(w.update(10), 0, accuracy: 0.001)    // середина дуги 350→10
    }
}

// MARK: - Движок порогов оповещения

final class AlertEngineTests: XCTestCase {
    func testEscalatesThroughThreeLevels() {
        var engine = AlertEngine()
        // Радиус 600 → пороги 600 / 360 / 180.
        XCTAssertNil(engine.evaluate(cameraID: 1, distance: 700, radius: 600))
        XCTAssertEqual(engine.evaluate(cameraID: 1, distance: 590, radius: 600)?.level, 1)
        XCTAssertNil(engine.evaluate(cameraID: 1, distance: 500, radius: 600))   // уровень не вырос
        XCTAssertEqual(engine.evaluate(cameraID: 1, distance: 350, radius: 600)?.level, 2)
        XCTAssertEqual(engine.evaluate(cameraID: 1, distance: 170, radius: 600)?.level, 3)
        XCTAssertNil(engine.evaluate(cameraID: 1, distance: 40, radius: 600))    // выше некуда
    }

    func testFastApproachSkipsToHigherLevel() {
        // Влетели сразу за второй порог — сигналим один раз, но уровнем 2.
        var engine = AlertEngine()
        XCTAssertEqual(engine.evaluate(cameraID: 1, distance: 300, radius: 600)?.level, 2)
    }

    func testExitWithHysteresisResetsSeries() {
        var engine = AlertEngine()
        XCTAssertEqual(engine.evaluate(cameraID: 1, distance: 200, radius: 600)?.level, 2)
        // Отошли чуть за радиус (внутри гистерезиса) — серия держится, дребезга нет.
        XCTAssertNil(engine.evaluate(cameraID: 1, distance: 650, radius: 600))
        XCTAssertNil(engine.evaluate(cameraID: 1, distance: 550, radius: 600))
        // Ушли за радиус+гистерезис — сброс; возврат в зону сигналит заново.
        XCTAssertNil(engine.evaluate(cameraID: 1, distance: 700, radius: 600))
        XCTAssertEqual(engine.evaluate(cameraID: 1, distance: 550, radius: 600)?.level, 1)
    }

    func testCamerasTrackedIndependently() {
        var engine = AlertEngine()
        XCTAssertEqual(engine.evaluate(cameraID: 1, distance: 550, radius: 600)?.level, 1)
        XCTAssertEqual(engine.evaluate(cameraID: 2, distance: 550, radius: 600)?.level, 1)
    }

    func testEffectiveRadiusGrowsWithSpeedAndClamps() {
        // Город: базовый радиус побеждает скоростной.
        XCTAssertEqual(AlertEngine.effectiveRadius(speedKmh: 40, baseRadius: 500), 500)
        // Трасса 110 км/ч: 30.6 м/с × 22 с ≈ 672 м.
        XCTAssertEqual(AlertEngine.effectiveRadius(speedKmh: 110, baseRadius: 500), 672, accuracy: 1)
        // Потолок динамического радиуса.
        XCTAssertEqual(AlertEngine.effectiveRadius(speedKmh: 250, baseRadius: 500), 1000)
    }
}

// MARK: - Учёт прохождения камер

final class PassTrackingTests: XCTestCase {
    private func camera(id: Int = 1, lat: Double, lon: Double) -> Camera {
        Camera(id: id, region: "", city: "", location: "тест", lat: lat, lon: lon,
               type: "Стационар радар", violations: [], needsReview: nil)
    }

    /// Едем на восток по 41.30°: торможение у камеры, разгон после проезда.
    func testCloseTraverseUsesMinimumZoneSpeed() {
        var tracking = PassTracking()
        let cam = camera(lat: 41.30, lon: 69.21)
        func tick(_ lon: Double, _ speed: Double) -> [PassTracking.Pass] {
            let d = GeoMath.fastDistance(41.30, lon, cam.lat, cam.lon)
            return tracking.update(nearest: cam, nearestDistance: d,
                                   coordinate: CLLocationCoordinate2D(latitude: 41.30, longitude: lon),
                                   speedKmh: speed, roadLimit: 60, radius: 500)
        }
        XCTAssertTrue(tick(69.205, 70).isEmpty)     // ~420 м — вошли в радиус
        XCTAssertTrue(tick(69.2095, 62).isEmpty)    // ~42 м — зона измерения
        XCTAssertTrue(tick(69.2100, 57).isEmpty)    // траверз
        XCTAssertTrue(tick(69.2105, 66).isEmpty)    // разгон после проезда
        let passes = tick(69.2180, 90)              // ушли за радиус + гистерезис
        XCTAssertEqual(passes.count, 1)
        XCTAssertEqual(passes[0].speedKmh, 57)      // минимум зоны, разгон не в счёт
        XCTAssertEqual(passes[0].limitKmh, 60)
        XCTAssertTrue(tracking.tracked.isEmpty)
    }

    func testParallelStreetPassIsDropped() {
        var tracking = PassTracking()
        let cam = camera(lat: 41.304, lon: 69.21)   // ~445 м севернее нашей дороги
        func tick(_ lon: Double, _ speed: Double) -> [PassTracking.Pass] {
            let d = GeoMath.fastDistance(41.30, lon, cam.lat, cam.lon)
            return tracking.update(nearest: cam, nearestDistance: d,
                                   coordinate: CLLocationCoordinate2D(latitude: 41.30, longitude: lon),
                                   speedKmh: speed, roadLimit: 60, radius: 500)
        }
        _ = tick(69.206, 70)
        _ = tick(69.210, 72)                        // максимальное сближение ~445 м
        let passes = tick(69.222, 74)
        XCTAssertTrue(passes.isEmpty, "камера с параллельной улицы не засчитывается")
        XCTAssertTrue(tracking.tracked.isEmpty)
    }

    func testFlushKeepsOnlyCloseTraverses() {
        var tracking = PassTracking()
        let close = camera(id: 1, lat: 41.30, lon: 69.2101)
        let coord = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.21)
        _ = tracking.update(nearest: close, nearestDistance: 9, coordinate: coord,
                            speedKmh: 55, roadLimit: 60, radius: 500)
        let far = camera(id: 2, lat: 41.302, lon: 69.21)   // ~220 м — в радиусе, но траверз далёкий
        _ = tracking.update(nearest: far, nearestDistance: 220, coordinate: coord,
                            speedKmh: 55, roadLimit: 60, radius: 500)
        let passes = tracking.flush()
        XCTAssertEqual(passes.map(\.camera.id), [1])
        XCTAssertTrue(tracking.tracked.isEmpty)
    }
}

// MARK: - Гео-чистка проездов

final class PassCleanupTests: XCTestCase {
    /// Прямая ~2 км на восток: после Дугласа-Пекера от неё остаются только концы,
    /// поэтому расстояние обязано считаться до отрезка, а не до вершин.
    private let track = [TrackPoint(lat: 41.30, lon: 69.20, speedKmh: 60),
                         TrackPoint(lat: 41.30, lon: 69.224, speedKmh: 62)]

    private func pass(_ speed: Double, limit: Int?, lat: Double, lon: Double) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: Int(lat * 1e4 + lon), typeRaw: "Стационар радар",
                     location: "", speedKmh: speed, date: Date(),
                     lat: lat, lon: lon, limitKmh: limit)
    }

    func testDistanceMeasuredToSegmentNotVertices() {
        // Точка над серединой отрезка, смещение к северу 0.0005° ≈ 56 м.
        let d = TripHistory.distanceToTrack(lat: 41.3005, lon: 69.212, track: track)
        XCTAssertEqual(d, 55.7, accuracy: 3)
        // До ближайшей ВЕРШИНЫ при этом ~1 км — сегментная математика обязательна.
    }

    func testSanitizedDropsParallelStreetPassAndRescores() {
        let near = pass(58, limit: 60, lat: 41.3003, lon: 69.21)   // ~33 м от трека
        let far = pass(73, limit: 60, lat: 41.3040, lon: 69.21)    // ~445 м — чужая улица
        let record = TripRecord(id: 1, startedAt: Date(),
                                endedAt: Date().addingTimeInterval(600),
                                distanceMeters: 2000, maxSpeedKmh: 70,
                                passed: [near, far], endLat: nil, endLon: nil,
                                track: [41.30, 69.20, 60, 41.30, 69.224, 62], score: 60)

        let (cleaned, changed) = TripHistory.sanitized([record])

        XCTAssertTrue(changed)
        XCTAssertEqual(cleaned[0].passed.map(\.cameraID), [near.cameraID])
        // Штрафной вклад ложного проезда ушёл — балл пересчитан вверх.
        XCTAssertNotNil(cleaned[0].score)
        XCTAssertGreaterThan(cleaned[0].score!, 60)
    }

    func testSanitizedLeavesHonestHistoryUntouched() {
        let record = TripRecord(id: 2, startedAt: Date(),
                                endedAt: Date().addingTimeInterval(600),
                                distanceMeters: 2000, maxSpeedKmh: 70,
                                passed: [pass(61, limit: 60, lat: 41.3001, lon: 69.205)],
                                endLat: nil, endLon: nil,
                                track: [41.30, 69.20, 60, 41.30, 69.224, 62], score: 97)

        let (cleaned, changed) = TripHistory.sanitized([record])

        XCTAssertFalse(changed)
        XCTAssertEqual(cleaned[0].passed.count, 1)
        XCTAssertEqual(cleaned[0].score, 97)   // нетронутые записи не пересчитываются
    }
}

// MARK: - Восстановление счётчиков из истории

final class LifetimeRebuildTests: XCTestCase {
    private func pass(_ speed: Double, limit: Int?) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: 1, typeRaw: "Стационар радар", location: "",
                     speedKmh: speed, date: Date(), lat: 41, lon: 69, limitKmh: limit)
    }
    private func record(daysAgo: Double, passes: [PassedCamera]) -> TripRecord {
        TripRecord(id: daysAgo, startedAt: Date().addingTimeInterval(-daysAgo * 86400),
                   endedAt: Date().addingTimeInterval(-daysAgo * 86400 + 600),
                   distanceMeters: 10_000, maxSpeedKmh: 80, passed: passes,
                   endLat: nil, endLon: nil, track: nil, score: nil)
    }

    func testRebuildGoesOldestToNewest() {
        // Новейшая — чистая, старейшая — со штрафом: серия должна закончиться на 1.
        let history = [record(daysAgo: 1, passes: [pass(55, limit: 60)]),
                       record(daysAgo: 5, passes: [pass(90, limit: 60)])]
        let stats = LifetimeStats.rebuilt(from: history)

        XCTAssertEqual(stats.trips, 2)
        XCTAssertEqual(stats.distanceMeters, 20_000)
        XCTAssertEqual(stats.camerasInLimit, 1)
        XCTAssertEqual(stats.savedFinesSum, FineSchedule.minimumFine)
        XCTAssertEqual(stats.riskFinesSum, 5 * FineSchedule.brv)   // +30 км/ч
        XCTAssertEqual(stats.cleanStreak, 1)   // последняя по времени — чистая
        XCTAssertEqual(stats.bestStreak, 1)
    }
}
