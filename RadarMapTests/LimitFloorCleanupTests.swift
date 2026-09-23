//
//  LimitFloorCleanupTests.swift
//  RadarMapTests
//
//  Одноразовый подъём лимитов в уже записанной истории.
//
//  Ретро-правки истории в этом проекте опасны одинаково: пересобрать агрегаты
//  «из истории» — значит стереть месяцы, чьи поездки уже вычищены. Здесь
//  сторожится ровно это, плюс само правило: проезды не удаляются, лимит только
//  поднимается, знак остаётся назван.
//

import XCTest
@testable import RadarMap

final class LimitFloorCleanupTests: XCTestCase {

    private func pass(_ speed: Double, limit: Int?, id: Int = 1) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: id, typeRaw: "Стационар радар",
                     location: "", speedKmh: speed, date: Date(),
                     lat: 41.30, lon: 69.21, limitKmh: limit)
    }

    private func record(_ passes: [PassedCamera], score: Double? = 80) -> TripRecord {
        let start = Date().addingTimeInterval(-3600)
        return TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                          endedAt: start.addingTimeInterval(1800),
                          distanceMeters: 12_000, maxSpeedKmh: 95,
                          passed: passes, score: score)
    }

    /// Тот самый проезд со скриншота: 66 км/ч по улице с тегом 50.
    func testTheFiftyTagPassLosesItsFine() {
        let (cleaned, changed) = TripHistory.limitFloored([record([pass(66, limit: 50)])])
        XCTAssertTrue(changed)
        let updated = cleaned[0].passed[0]
        XCTAssertEqual(updated.limitKmh, 60)
        XCTAssertEqual(updated.roadLimitKmh, 50)
        XCTAssertTrue(updated.limitWasFloored)
        // Был 1 БРВ по тегу 50 — стал 1 БРВ по полу 60: превышение осталось
        // настоящим (66 при 60 камера фиксирует), но теперь оно честное.
        XCTAssertEqual(updated.overLimitKmh, 6)
    }

    /// А вот этот проезд обвинение теряет целиком.
    func testACalmPassStopsBeingAViolation() {
        let (cleaned, _) = TripHistory.limitFloored([record([pass(58, limit: 50)])])
        let updated = cleaned[0].passed[0]
        XCTAssertEqual(FineSchedule.fine(overKmh: updated.overLimitKmh ?? 0), 0)
        XCTAssertEqual(TripHistory.fineRisk(of: cleaned[0].passed), 0)
    }

    /// Проезды НЕ удаляются: это правка лимита, а не чистка ложных записей.
    /// Спутать одно с другим значит потерять историю человека.
    func testPassesAreNeverRemoved() {
        let passes = [pass(66, limit: 50, id: 1), pass(80, limit: 70, id: 2),
                      pass(40, limit: nil, id: 3)]
        let (cleaned, changed) = TripHistory.limitFloored([record(passes)])
        XCTAssertTrue(changed)
        XCTAssertEqual(cleaned[0].passed.count, 3)
        XCTAssertEqual(cleaned[0].passed.map(\.cameraID), [1, 2, 3])
        // Лимит выше пола не тронут, отсутствующий не выдуман.
        XCTAssertEqual(cleaned[0].passed[1].limitKmh, 70)
        XCTAssertNil(cleaned[0].passed[1].roadLimitKmh)
        XCTAssertNil(cleaned[0].passed[2].limitKmh)
    }

    /// Нечего поднимать — запись не трогается вовсе, и флаг «менялось» не
    /// поднимается: иначе миграция перезаписала бы всю историю впустую.
    func testNothingToRaiseMeansNoChange() {
        let (cleaned, changed) = TripHistory.limitFloored([record([pass(66, limit: 60)])])
        XCTAssertFalse(changed)
        XCTAssertEqual(cleaned[0].passed[0].limitKmh, 60)
        XCTAssertNil(cleaned[0].passed[0].roadLimitKmh)
    }

    /// Балл поездки пересчитывается по новым лимитам — иначе разбор рейтинга
    /// разошёлся бы с самим рейтингом.
    func testScoreIsRecomputed() {
        let before = record([pass(66, limit: 50)], score: 10)
        let (cleaned, _) = TripHistory.limitFloored([before])
        XCTAssertNotNil(cleaned[0].score)
        XCTAssertGreaterThan(cleaned[0].score ?? 0, before.score ?? 0)
    }

    /// Балла не было — он и не появляется. Выдумать рейтинг там, где его не
    /// считали (старая запись без трека), нельзя.
    func testMissingScoreIsNotInvented() {
        let (cleaned, _) = TripHistory.limitFloored([record([pass(66, limit: 50)], score: nil)])
        XCTAssertNil(cleaned[0].score)
    }

    /// Дневная свёртка правится ХИРУРГИЧЕСКИ: снять старую запись, положить
    /// новую. Пересборка `rebuilt(from:)` по обрезанной истории обнулила бы
    /// месяцы, поездок за которые уже нет.
    func testDailyRollupIsRepairedSurgically() {
        let before = record([pass(66, limit: 50)])
        let (cleaned, _) = TripHistory.limitFloored([before])
        let after = cleaned[0]

        // День с этой поездкой плюс старый день, которого в истории уже нет.
        let ancient = TripDay(day: Calendar.current.startOfDay(
            for: Date().addingTimeInterval(-400 * 86400)),
            trips: 9, distanceMeters: 900_000,
            overPasses: 3, fineRisk: 3 * FineSchedule.brv)
        var days = [ancient]
        days = TripDayBook.folded(before, into: days)

        days = TripDayBook.unfolded(before, from: days)
        days = TripDayBook.folded(after, into: days)

        // Старый месяц на месте — ради этого вся хирургия и затевалась.
        XCTAssertEqual(days.first { $0.day == ancient.day }?.trips, 9)
        XCTAssertEqual(days.first { $0.day == ancient.day }?.fineRisk, 3 * FineSchedule.brv)
        // А день поездки пересчитан по новому лимиту.
        let key = Calendar.current.startOfDay(for: before.startedAt)
        XCTAssertEqual(days.first { $0.day == key }?.trips, 1)
    }

    /// Пожизненные счётчики правятся заменой проезда, а не пересборкой:
    /// поездки и километры остаются на месте, меняются только деньги и вердикт.
    func testLifetimeIsRepairedByReplacingThePass() {
        var lifetime = LifetimeStats()
        lifetime = LifetimeStats.updated(
            lifetime, passes: [DrivingScore.Pass(speedKmh: 58, limitKmh: 50)],
            distanceMeters: 12_000)
        XCTAssertEqual(lifetime.trips, 1)
        XCTAssertGreaterThan(lifetime.riskFinesSum, 0)
        XCTAssertEqual(lifetime.camerasInLimit, 0)

        lifetime = LifetimeStats.replacingPass(
            DrivingScore.Pass(speedKmh: 58, limitKmh: 50),
            with: DrivingScore.Pass(speedKmh: 58, limitKmh: 60), in: lifetime)

        // Обвинение снято…
        XCTAssertEqual(lifetime.riskFinesSum, 0)
        XCTAssertEqual(lifetime.camerasInLimit, 1)
        XCTAssertEqual(lifetime.savedFinesSum, FineSchedule.minimumFine)
        // …а поездка, километры и сам факт проезда — нет.
        XCTAssertEqual(lifetime.trips, 1)
        XCTAssertEqual(lifetime.distanceMeters, 12_000)
        XCTAssertEqual(lifetime.camerasPassed, 1)
    }

    /// «Свои» камеры: проезды, переставшие быть нарушением, наконец покупают
    /// тишину. Это прямой ответ на «я там много раз проезжаю, а он говорит».
    func testFlooredPassesFinallyMakeACameraFamiliar() {
        let now = Date()
        let history = (0..<CameraFamiliarity.minPasses).map { index -> TripRecord in
            let start = now.addingTimeInterval(-Double(index + 1) * 86400)
            // 57 км/ч по улице с тегом 50: превышение на 7 — по тегу это
            // «нарушение» каждый день, по настоящему лимиту 60 — спокойная езда.
            let pass = PassedCamera(id: UUID(), cameraID: 42, typeRaw: "Стационар радар",
                                    location: "", speedKmh: 57,
                                    date: start.addingTimeInterval(600),
                                    lat: 41.30, lon: 69.21, limitKmh: 50)
            return TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                              endedAt: start.addingTimeInterval(1200),
                              distanceMeters: 9000, maxSpeedKmh: 60, passed: [pass])
        }
        XCTAssertFalse(CameraFamiliarity.familiarIDs(history: history, now: now).contains(42),
                       "по тегу 50 камера остаётся вечно говорящей")

        let (raised, _) = TripHistory.limitFloored(history)
        XCTAssertTrue(CameraFamiliarity.familiarIDs(history: raised, now: now).contains(42))
    }
}
