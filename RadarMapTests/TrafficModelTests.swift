//
//  TrafficModelTests.swift
//  RadarMapTests
//
//  Модель обычных пробок на телефоне (33G, server/traffic_model.py):
//  profile.json со строками модели и таблицей кривых. Слой «обычно в это
//  время» и его подпись по источнику, ETA через 33C (TrafficTimeAhead), и
//  главное — догадка не звучит: JamAhead и объезд по модели не срабатывают.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class TrafficModelTests: XCTestCase {

    private let base = CLLocationCoordinate2D(latitude: 41.3000, longitude: 69.2800)
    private let tashkent = TypicalTraffic.tashkent

    private func north(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: base.latitude + meters / 111_320, longitude: base.longitude)
    }

    /// Понедельник 26.10.2026 по Ташкенту; `day` 1 = 25-е, воскресенье.
    private func at(hour: Int, minute: Int = 0, day: Int = 26) -> Date {
        tashkent.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// Кривая модели: 50 % графа в будние 8:00–9:59 и 17:00–19:59, иначе 100 %.
    private var peakCurve: [Int] {
        (0..<168).map { slot in
            let (day, hour) = (slot / 24, slot % 24)
            return day < 5 && ([8, 9, 17, 18, 19].contains(hour)) ? 50 : 100
        }
    }

    /// profile.json: проспект на север 0…2 км — строки модели по 200 м; по
    /// желанию — строка водителей на 2…2,2 км со слотом 18 и кривой модели.
    private func profileData(drivers: [[Int]]? = nil, curves: [[Int]]? = nil,
                             generated: Date? = nil) -> Data {
        var edges: [[Any]] = stride(from: 0.0, to: 2000, by: 200).map { y in
            let a = north(y), b = north(y + 200)
            return [a.latitude, a.longitude, b.latitude, b.longitude, 60, 0]
        }
        if let drivers {
            let a = north(2000), b = north(2200)
            edges.append([a.latitude, a.longitude, b.latitude, b.longitude, 60, drivers, 0])
        }
        let object: [String: Any] = ["v": 1, "generated": (generated ?? at(hour: 2)).timeIntervalSince1970,
                                     "curves": curves ?? [peakCurve], "edges": edges,
                                     "sources": ["drivers": drivers == nil ? 0 : 1, "model": 10]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func profile(drivers: [[Int]]? = nil) throws -> TrafficProfile {
        try XCTUnwrap(TrafficProfile.decode(profileData(drivers: drivers)))
    }

    // MARK: - Формат

    func testDecodesModelRowsAndCurves() throws {
        let p = try profile(drivers: [[18, 54]])
        XCTAssertEqual(p.snapshot.edges.count, 11)
        XCTAssertEqual(p.curves.count, 1)
        XCTAssertEqual(p.curves[0][18], 0.5)
        XCTAssertEqual(p.curveIndex.filter { $0 == 0 }.count, 11, "у водительского ребра — та же кривая седьмым")
        let mix = TrafficProfile.mix(at: at(hour: 18))
        XCTAssertEqual(p.source(edge: 0, mix: mix), .model)
        XCTAssertEqual(p.source(edge: 10, mix: mix), .drivers)
        XCTAssertEqual(p.source(edge: 10, mix: TrafficProfile.mix(at: at(hour: 8))), .model,
                       "в слоте без наблюдений водителей — модель")
    }

    func testBrokenCurveDropsOnlyModelRows() throws {
        let data = profileData(drivers: [[18, 30]], curves: [[10, 20]])
        let p = try XCTUnwrap(TrafficProfile.decode(data))
        XCTAssertEqual(p.snapshot.edges.count, 1, "строки модели с битой кривой — мимо; водители остаются")
        XCTAssertEqual(p.curveIndex, [-1])
    }

    func testOldFormatWithoutCurvesStillWorks() throws {
        let a = north(0), b = north(100)
        let object: [String: Any] = ["v": 1, "generated": at(hour: 2).timeIntervalSince1970,
                                     "edges": [[a.latitude, a.longitude, b.latitude, b.longitude, 60, [[18, 30]]]]]
        let p = try XCTUnwrap(TrafficProfile.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(p.curveIndex, [-1])
        XCTAssertEqual(p.speed(edge: 0, mix: TrafficProfile.mix(at: at(hour: 3))), 60, "без модели — граф")
    }

    // MARK: - Скорость: водители поверх модели

    func testDriversSlotBeatsModelAndModelBeatsGraph() throws {
        let p = try profile(drivers: [[18, 54]])
        let evening = TrafficProfile.mix(at: at(hour: 18))
        XCTAssertEqual(p.speed(edge: 0, mix: evening), 30, accuracy: 0.01, "модель: 0,5 графа")
        XCTAssertEqual(p.speed(edge: 10, mix: evening), 54, accuracy: 0.01, "водители вытеснили модель")
        XCTAssertEqual(p.speed(edge: 0, mix: TrafficProfile.mix(at: at(hour: 3))), 60, accuracy: 0.01, "ночью — граф")
        // 16:30 — смесь 16-го (граф) и 17-го (модель) слотов пополам.
        XCTAssertEqual(p.speed(edge: 0, mix: TrafficProfile.mix(at: at(hour: 16, minute: 30))), 45, accuracy: 0.01)
    }

    // MARK: - Слой «обычно в это время»

    func testUsualLayerIsThereInPeaksAndNotAtNight() throws {
        let p = try profile(drivers: [[18, 54]])
        // 18:10: водители 54 км/ч в слоте 18, модель 30 в слоте 19 → 50 из 60.
        let evening = p.usual(at: at(hour: 18, minute: 10))
        XCTAssertEqual(evening.count, 10, "проспект модели виден, водительское ребро — нет")
        XCTAssertTrue(evening.allSatisfy { $0.source == .model && $0.isHeavy })
        XCTAssertEqual(p.usual(at: at(hour: 8, minute: 30)).count, 11)
        XCTAssertTrue(p.usual(at: at(hour: 3)).isEmpty, "ночью пусто")
        XCTAssertTrue(p.usual(at: at(hour: 12, day: 25)).isEmpty, "воскресенье днём пусто")
    }

    func testUsualLayerLabelsDrivers() throws {
        let p = try profile(drivers: [[18, 20]])
        let edge = try XCTUnwrap(p.usual(at: at(hour: 18)).last)
        XCTAssertEqual(edge.source, .drivers)
        XCTAssertEqual(edge.ratio, 20.0 / 60.0, accuracy: 0.001)
    }

    func testUsualLayerThreshold() throws {
        // 75 % графа — не «медленно» для слоя; 69 % — да.
        let mild = (0..<168).map { _ in 75 }, slow = (0..<168).map { _ in 69 }
        for (curve, expected) in [(mild, 0), (slow, 10)] {
            let p = try XCTUnwrap(TrafficProfile.decode(profileData(curves: [curve])))
            XCTAssertEqual(p.usual(at: at(hour: 12)).count, expected)
        }
        XCTAssertEqual(AppConfig.usualTrafficShowRatio, 0.7)
    }

    // MARK: - ETA через 33C

    func testEtaIncludesModelInPeakOnly() throws {
        let p = try profile()
        let route = stride(from: 0.0, through: 2000, by: 100).map { north($0) }
        let baseTime = 2.0 * 60   // 2 км по 60 км/ч
        let evening = try XCTUnwrap(TrafficTimeAhead.delay(along: route, baseTime: baseTime, departure: at(hour: 18),
                                                           now: at(hour: 18), live: nil, profile: p))
        XCTAssertEqual(evening.source, .typical)
        XCTAssertEqual(evening.seconds, 120, accuracy: 3, "0,5 графа — время вдвое")
        let night = try XCTUnwrap(TrafficTimeAhead.delay(along: route, baseTime: baseTime, departure: at(hour: 3),
                                                         now: at(hour: 3), live: nil, profile: p))
        XCTAssertEqual(night.seconds, 0, accuracy: 0.5)
        // Встречное направление — модели нет (ребро только на север).
        let back = Array(route.reversed())
        let opposite = try XCTUnwrap(TrafficTimeAhead.delay(along: back, baseTime: baseTime, departure: at(hour: 18),
                                                            now: at(hour: 18), live: nil, profile: p))
        XCTAssertEqual(opposite.seconds, 0, accuracy: 0.5)
    }

    // MARK: - Голос — только по живым

    func testModelNeverSpeaks() throws {
        let p = try profile()
        let route = stride(from: 0.0, through: 2000, by: 100).map { north($0) }
        // Даже если рёбра профиля попадут туда, где ждут живые, они уровня 1 —
        // ни «Впереди пробка», ни задержки для объезда.
        XCTAssertTrue(p.snapshot.edges.allSatisfy { $0.level == 1 })
        XCTAssertNil(JamAhead.detect(edges: p.snapshot.edges, position: north(-300), course: 0))
        XCTAssertEqual(p.snapshot.delay(along: route), 0, "живая мерка объезда по профилю — ноль")
        XCTAssertFalse(DetourAdvisor.shouldSearch(remainingDistance: 10_000, delayAhead: p.snapshot.delay(along: route),
                                                  crawl: 0, sinceLastSearch: nil, sinceDecline: nil, offersOnRoute: 0),
                       "объезд ищется только по живой задержке")
        // А ETA модель получает (тот же профиль, 18:00) — догадка в цифре, не в голосе.
        let eta = TrafficTimeAhead.delay(along: route, baseTime: 120, departure: at(hour: 18), now: at(hour: 18),
                                         live: nil, profile: p)
        XCTAssertGreaterThan(eta?.seconds ?? 0, 60)
    }

    func testStaleProfileGivesNoLayerData() throws {
        let p = try XCTUnwrap(TrafficProfile.decode(profileData(generated: at(hour: 2, day: 20))))
        XCTAssertFalse(p.isFresh(now: at(hour: 18)), "старше 36 ч — нет данных (слой берёт только свежий)")
    }
}
