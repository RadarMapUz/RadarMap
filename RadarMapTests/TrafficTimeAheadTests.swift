//
//  TrafficTimeAheadTests.swift
//  RadarMapTests
//
//  Время прибытия во времени (33C, docs/spec_traffic_33.md): скорость участка
//  — на момент, когда до него доедешь. Живое — только на ближние 15 минут
//  пути, дальше типичная слота часа недели прибытия (profile.json, смесь
//  слотов по минуте), иначе граф; старый или чужой файл — нет данных.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class TrafficTimeAheadTests: XCTestCase {

    private let base = CLLocationCoordinate2D(latitude: 41.2000, longitude: 69.2800)
    private let tashkent = TypicalTraffic.tashkent

    private func north(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: base.latitude + meters / 111_320, longitude: base.longitude)
    }

    /// Маршрут на север длиной `km`, точка каждые 100 м; граф — 60 км/ч.
    private func route(km: Double) -> [CLLocationCoordinate2D] {
        stride(from: 0.0, through: km * 1000, by: 100).map { north($0) }
    }

    private func baseTime(km: Double) -> TimeInterval { km * 60 }       // 60 км/ч

    /// Понедельник 26.10.2026 по Ташкенту (25-е — воскресенье).
    private func at(hour: Int, minute: Int = 0, day: Int = 26) -> Date {
        tashkent.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// profile.json: рёбра по 100 м на [from, to) с этими слотами.
    private func profile(slots: [Int: Int], from: Double = 0, to: Double = 60_000, generated: Date? = nil,
                         version: Int = 1, model: Int = 60) -> TrafficProfile? {
        let edges: [[Any]] = stride(from: from, to: to, by: 100).map { y in
            let a = north(y), b = north(y + 100)
            return [a.latitude, a.longitude, b.latitude, b.longitude, model,
                    slots.sorted { $0.key < $1.key }.map { [$0.key, $0.value] }]
        }
        // Сборка в воскресенье 22:00 — свежая для всех моментов тестов (≤ 36 ч).
        let object: [String: Any] = ["v": version, "generated": (generated ?? at(hour: 22, day: 25)).timeIntervalSince1970,
                                     "edges": edges]
        return TrafficProfile.decode(try! JSONSerialization.data(withJSONObject: object))
    }

    private func live(level: Int, kmh: Double, from: Double = 0, to: Double = 60_000,
                      generated: Date) -> TrafficSnapshot {
        TrafficSnapshot(generated: generated, edges: stride(from: from, to: to, by: 100).map {
            TrafficEdge(a: north($0), b: north($0 + 100), level: level, kmh: kmh, modelKmh: 60)
        })
    }

    private func delay(km: Double, departure: Date, now: Date? = nil, live: TrafficSnapshot? = nil,
                       profile: TrafficProfile?) -> TrafficForecast.Delay? {
        TrafficTimeAhead.delay(along: route(km: km), baseTime: baseTime(km: km), departure: departure,
                               now: now ?? departure, live: live, profile: profile)
    }

    // MARK: - Слоты

    func testWeekSlotsAreTashkentMondayBased() {
        XCTAssertEqual(TrafficProfile.weekSlot(at(hour: 0)), 0, "понедельник 00:00")
        XCTAssertEqual(TrafficProfile.weekSlot(at(hour: 18)), 18)
        XCTAssertEqual(TrafficProfile.weekSlot(at(hour: 23, day: 25)), 167, "воскресенье 23:00")
        // 1 сентября 2026 — вторник и праздник: слот воскресенья того же часа.
        let independence = tashkent.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 9))!
        XCTAssertEqual(TrafficProfile.weekSlot(independence), 6 * 24 + 9)
    }

    func testMinuteMixesTheNextSlot() {
        XCTAssertEqual(TrafficProfile.mix(at: at(hour: 17, minute: 30)),
                       TrafficProfile.Mix(current: 17, next: 18, alpha: 0.5))
        XCTAssertEqual(TrafficProfile.mix(at: at(hour: 23, minute: 30, day: 25)),
                       TrafficProfile.Mix(current: 167, next: 0, alpha: 0.5), "воскресенье → понедельник")
    }

    // MARK: - Время прибытия

    func testEveningJamReachesOnlyTheFarPart() throws {
        // Выезд 17:40, 30 км (30 мин по графу), в слоте 18 обычно 20 км/ч.
        let jam = try XCTUnwrap(profile(slots: [18: 20]))
        let departure = at(hour: 17, minute: 40)
        // Ближние 15 минут — свежие живые «свободно»: ближние участки без задержки.
        let free = live(level: 1, kmh: 60, generated: departure)
        let near = try XCTUnwrap(delay(km: 10, departure: departure, live: free, profile: jam))
        XCTAssertEqual(near.seconds, 0, accuracy: 0.001, "ближние 10 км — по живым, задержки нет")
        XCTAssertEqual(near.source, .live)
        let whole = try XCTUnwrap(delay(km: 30, departure: departure, live: free, profile: jam))
        XCTAssertGreaterThan(whole.seconds, 60, "дальние участки — после 17:55, в смеси со слотом 18")
        XCTAssertEqual(whole.source, .mixed)
        // Тот же путь в 3 ночи — пусто.
        XCTAssertEqual(try XCTUnwrap(delay(km: 30, departure: at(hour: 3), live: nil, profile: jam)).seconds, 0,
                       accuracy: 0.001)
    }

    /// Решение 28.10: смешанная задержка делится на живую часть и «обычно»;
    /// свежий, но пустой на нашем пути now.json не делает задержку профиля
    /// «пробками» (симуляция 27.10: «+10 мин из-за пробок» из профиля).
    func testLivePartIsSplitFromUsualForTheCaption() throws {
        let jam = try XCTUnwrap(profile(slots: [18: 20]))
        let departure = at(hour: 17, minute: 40)
        let free = live(level: 1, kmh: 60, generated: departure)
        let usual = try XCTUnwrap(delay(km: 30, departure: departure, live: free, profile: jam))
        XCTAssertEqual(usual.source, .mixed)
        XCTAssertEqual(usual.liveSeconds, 0, accuracy: 0.001, "живые есть, но свободны — живой задержки нет")
        XCTAssertEqual(TrafficForecast.cause(total: usual.seconds, live: usual.liveSeconds), .usual)
        // Живая пробка на ближних 5 км (10 км/ч; в 15-минутный горизонт
        // попадает ~2,5 км, ~750 с) и вечер чуть медленнее графа дальше
        // (50 км/ч, ~300 с): живое — больше половины, это пробки сейчас.
        let nearJam = live(level: 3, kmh: 10, to: 5_000, generated: departure)
        let mild = try XCTUnwrap(profile(slots: [18: 50]))
        let mixed = try XCTUnwrap(delay(km: 30, departure: departure, live: nearJam, profile: mild))
        XCTAssertEqual(mixed.source, .mixed)
        XCTAssertGreaterThan(mixed.liveSeconds, 0)
        XCTAssertLessThanOrEqual(mixed.liveSeconds, mixed.seconds)
        XCTAssertEqual(TrafficForecast.cause(total: mixed.seconds, live: mixed.liveSeconds), .jams)
        // Только живые — вся задержка живая.
        let onlyLive = try XCTUnwrap(delay(km: 2, departure: at(hour: 12), live: live(level: 3, kmh: 10,
                                                                                     generated: at(hour: 12)),
                                           profile: nil))
        XCTAssertEqual(onlyLive.liveSeconds, onlyLive.seconds)
    }

    func testCaptionCauseIsHalfTheDelay() {
        XCTAssertEqual(TrafficForecast.cause(total: 600, live: 300), .jams, "ровно половина — пробки")
        XCTAssertEqual(TrafficForecast.cause(total: 600, live: 299), .usual)
        XCTAssertEqual(TrafficForecast.cause(total: 600, live: 0), .usual)
        XCTAssertEqual(TrafficForecast.cause(total: 600, live: 600), .jams)
        XCTAssertEqual(TrafficForecast.Delay(seconds: 120, source: .live).liveSeconds, 120)
        XCTAssertEqual(TrafficForecast.Delay(seconds: 120, source: .typical).liveSeconds, 0)
    }

    func testDelayGrowsTowardTheJamHour() throws {
        // Пробка весь вечер (слоты 18 и 19): к 18:00 задержка растёт до полной.
        let jam = try XCTUnwrap(profile(slots: [18: 20, 19: 20]))
        let early = try XCTUnwrap(delay(km: 5, departure: at(hour: 17, minute: 0), profile: jam)).seconds
        let later = try XCTUnwrap(delay(km: 5, departure: at(hour: 17, minute: 50), profile: jam)).seconds
        let inside = try XCTUnwrap(delay(km: 5, departure: at(hour: 18, minute: 0), profile: jam)).seconds
        XCTAssertLessThan(early, later)
        XCTAssertLessThan(later, inside)
        // В 18:00 весь участок — 20 км/ч против 60: 5 км по 3 мин/км против 1.
        XCTAssertEqual(inside, 5000 / (20 / 3.6) - 5000 / (60 / 3.6), accuracy: 30)
    }

    func testMidnightWrapsSundayToMonday() throws {
        let monday = try XCTUnwrap(profile(slots: [0: 20]))
        let sunday = at(hour: 23, minute: 50, day: 25)
        XCTAssertGreaterThan(try XCTUnwrap(delay(km: 10, departure: sunday, profile: monday)).seconds, 0,
                             "воскресенье 23:50 → пробка понедельника 0:00")
        let lateSunday = try XCTUnwrap(profile(slots: [167: 20]))
        XCTAssertGreaterThan(try XCTUnwrap(delay(km: 5, departure: at(hour: 23, minute: 0, day: 25),
                                                 profile: lateSunday)).seconds, 0)
        XCTAssertEqual(try XCTUnwrap(delay(km: 5, departure: at(hour: 0, minute: 0), profile: lateSunday)).seconds, 0,
                       "понедельник 0:00 — уже слот 0, пробка воскресенья кончилась")
    }

    func testProfileWithoutOurEdgeAddsNothing() throws {
        let elsewhere = try XCTUnwrap(profile(slots: [18: 20], from: 100_000, to: 101_000))
        let got = try XCTUnwrap(delay(km: 10, departure: at(hour: 18), profile: elsewhere))
        XCTAssertEqual(got.seconds, 0)
        XCTAssertEqual(got.source, .typical)
    }

    func testLiveShareCountsOnlyMeasuredRoadInTheHorizon() throws {
        // 10 км, свежие живые свободны на первых 2 км: измерено 2 из 10 км горизонта.
        let partial = try XCTUnwrap(delay(km: 10, departure: at(hour: 3),
                                          live: live(level: 1, kmh: 60, to: 2_000, generated: at(hour: 3)),
                                          profile: profile(slots: [:])))
        XCTAssertEqual(partial.liveMeasuredShare, 0.2, accuracy: 0.02)
        XCTAssertNil(TrafficForecast.claimable(partial), "о 8 км ничего не известно — не «без пробок»")
        let full = try XCTUnwrap(delay(km: 10, departure: at(hour: 3),
                                       live: live(level: 1, kmh: 60, generated: at(hour: 3)), profile: nil))
        XCTAssertEqual(full.liveMeasuredShare, 1, accuracy: 0.01)
        XCTAssertNotNil(TrafficForecast.claimable(full))
    }

    func testOldOrForeignFileIsNoData() {
        let departure = at(hour: 18)
        XCTAssertNil(delay(km: 10, departure: departure,
                           profile: profile(slots: [18: 20], generated: departure.addingTimeInterval(-37 * 3600))),
                     "старше 36 ч — нет данных")
        XCTAssertNotNil(delay(km: 10, departure: departure,
                              profile: profile(slots: [18: 20], generated: departure.addingTimeInterval(-35 * 3600))))
        XCTAssertNil(profile(slots: [18: 20], version: 2), "чужая версия не разбирается")
        XCTAssertNil(TrafficProfile.decode(Data("не json".utf8)))
        XCTAssertNil(delay(km: 10, departure: departure, profile: nil), "ничего нет — nil, не «пробок нет»")
    }

    func testLiveIsTrustedOnlyFifteenMinutesAhead() throws {
        let departure = at(hour: 12)
        let jam = live(level: 3, kmh: 10, generated: departure)
        let got = try XCTUnwrap(delay(km: 30, departure: departure, live: jam, profile: nil))
        // Живая пробка 10 км/ч: до 15-й минуты пути — она, дальше профиля нет — граф.
        let near = try XCTUnwrap(delay(km: 2, departure: departure, live: jam, profile: nil)).seconds
        XCTAssertEqual(near, 2000 / (10 / 3.6) - 2000 / (60 / 3.6), accuracy: 10)
        XCTAssertLessThan(got.seconds, 30_000 / (10 / 3.6) - 30_000 / (60 / 3.6), "дальше 15 мин живое не участвует")
        XCTAssertGreaterThan(got.seconds, near)
        // Старый now.json — не живое.
        XCTAssertNil(delay(km: 2, departure: departure, live: live(level: 3, kmh: 10,
                                                                   generated: departure.addingTimeInterval(-11 * 60)),
                           profile: nil))
    }

    func testDecodeKeepsOnlySaneSlots() throws {
        let object: [String: Any] = ["v": 1, "generated": 1_790_000_000, "edges": [
            [41.2, 69.28, 41.201, 69.28, 60, [[18, 20], [200, 10], [19, 90]]],
            [41.3, 69.28, 41.301, 69.28, 60, [[400, 10]]],
            [41.3, 69.28, 41.301, 69.28, 0, [[18, 10]]],
        ]]
        let decoded = try XCTUnwrap(TrafficProfile.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(decoded.slots.count, 1, "без годных слотов и без графа — мимо")
        XCTAssertEqual(decoded.slots[0], [18: 20], "слот вне недели и быстрее графа отброшены")
    }
}
