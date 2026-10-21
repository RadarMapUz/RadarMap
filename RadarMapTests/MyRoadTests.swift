//
//  MyRoadTests.swift
//  RadarMapTests
//
//  «Моя дорога» (24.4): опорные точки ложатся после поворотов и на длинных
//  прямых, не на коротких хвостах, не у дома и работы и не у краёв линии;
//  петля через опорную точку и параллельная улица — не своя дорога; вариант
//  движка по своей дороге помечается вместо второго такого же; время — по
//  своим поездкам этого часа, пробки — только сверх обычного.
//

import CoreLocation
import simd
import XCTest
@testable import RadarMap

final class MyRoadTests: XCTestCase {
    private let lat = 41.30, lon0 = 69.20
    private var k: Double { 111_320 * cos(lat * .pi / 180) }
    private var frame: CommuteProfile.Frame { CommuteProfile.Frame(latitude: lat) }
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    /// Понедельник, 11 января 2027.
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 11) -> Date {
        utc.date(from: DateComponents(year: 2027, month: 1, day: day, hour: hour, minute: minute))!
    }

    /// Точка в метрах от (lat, lon0): x — восток, y — север.
    private func point(_ x: Double, _ y: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat + y / 111_320, longitude: lon0 + x / k)
    }

    /// Ломаная по вершинам (м), с точками через 50 м — как линия профиля.
    private func path(_ corners: [(Double, Double)], step: Double = 50) -> [CLLocationCoordinate2D] {
        var out = [point(corners[0].0, corners[0].1)]
        for (a, b) in zip(corners, corners.dropFirst()) {
            let length = hypot(b.0 - a.0, b.1 - a.1)
            let n = max(1, Int((length / step).rounded(.up)))
            for i in 1...n {
                let t = Double(i) / Double(n)
                out.append(point(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t))
            }
        }
        return out
    }

    private func xy(_ c: CLLocationCoordinate2D) -> SIMD2<Double> { frame.xy(c.latitude, c.longitude) }

    private func length(_ line: [CLLocationCoordinate2D]) -> Double {
        CommuteProfile.Geometry.length(line.map(xy))
    }

    /// Вариант профиля по линии: участки по 200 м, `rows` утренних поездок
    /// по `seconds` на участок.
    private func variant(_ line: [CLLocationCoordinate2D], rows: Int = 5, seconds: Int = 20,
                         hour: Int = 8) -> CommuteProfile.Variant {
        let ends = CommuteProfile.boundaries(length: length(line))
        var packed: [Int32] = []
        for c in line {
            packed.append(Int32((c.latitude * 1e5).rounded()))
            packed.append(Int32((c.longitude * 1e5).rounded()))
        }
        let made = (0..<rows).map { i in
            CommuteProfile.Row(tripID: Double(1000 + i), departure: at(hour, 10, day: 4 + i % 5),
                               weekend: false, arrivalMinute: 0,
                               seconds: [UInt16](repeating: UInt16(seconds), count: ends.count))
        }
        return CommuteProfile.Variant(id: UUID(), line: packed, ends: ends.map(Float.init),
                                      limitKmh: [], rows: made, lastUsed: at(8))
    }

    // MARK: - Цель

    func testDestinationIsHomeOrWorkOnlyNearThem() {
        let home = point(0), work = point(8000)
        XCTAssertEqual(MyRoad.direction(destination: point(150), home: home, work: work), .toHome)
        XCTAssertEqual(MyRoad.direction(destination: point(7800), home: home, work: work), .toWork)
        XCTAssertNil(MyRoad.direction(destination: point(4000), home: home, work: work), "магазин посередине")
        XCTAssertNil(MyRoad.direction(destination: point(500), home: home, work: work), "за 500 м — уже не дом")
    }

    // MARK: - Опорные точки

    func testViaPointsFollowTurnsAndLongStraights() {
        // На восток 3 км, затем на север 3 км.
        let line = path([(0, 0), (3000, 0), (3000, 3000)]).map(xy)
        let via = MyRoad.viaPoints(line, avoid: [])
        XCTAssertGreaterThanOrEqual(via.count, 3)
        XCTAssertLessThanOrEqual(via.count, AppConfig.myRoadViaMax)
        // Точка после поворота — на отрезке на север, с курсом на север, не на перекрёстке.
        let afterTurn = via.first { abs($0.along - 3000 - AppConfig.myRoadViaAfterTurnMeters) < 5 }
        XCTAssertNotNil(afterTurn, "\(via.map(\.along))")
        if let afterTurn {
            XCTAssertEqual(afterTurn.bearing, 0)
            XCTAssertGreaterThan(simd_distance(afterTurn.point, SIMD2(3000, 0) + line[0]), 50)
        }
        // По ходу движения, с интервалом и не у краёв.
        XCTAssertEqual(via.map(\.along), via.map(\.along).sorted())
        for (a, b) in zip(via, via.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.along - a.along, AppConfig.myRoadViaSpacingMeters - 1)
        }
        XCTAssertTrue(via.allSatisfy { $0.along >= AppConfig.myRoadViaEdgeMeters && $0.along <= 6000 - AppConfig.myRoadViaEdgeMeters })
        // Прямая на восток — курс 90.
        XCTAssertTrue(via.filter { $0.along < 3000 }.allSatisfy { $0.bearing == 90 })
    }

    func testNoViaOnAShortTail() {
        // Уступ: 2 км на восток, 80 м на север, снова 2 км на восток. На
        // 80-метровом хвосте точки нет — она легла бы на перекрёсток.
        let line = path([(0, 0), (2000, 0), (2000, 80), (4000, 80)]).map(xy)
        let via = MyRoad.viaPoints(line, avoid: [])
        XCTAssertFalse(via.contains { $0.along > 2000 && $0.along < 2080 }, "\(via.map(\.along))")
        XCTAssertTrue(via.contains { abs($0.along - 2080 - AppConfig.myRoadViaAfterTurnMeters) < 5 },
                      "после второго поворота длинный отрезок — точка есть")
    }

    func testGpsZigzagIsNotATurn() {
        // Прямая 3 км с шумом ±8 м: поворотов нет, точки только на прямой.
        var corners: [(Double, Double)] = []
        for i in 0...60 { corners.append((Double(i) * 50, i % 2 == 0 ? 8 : -8)) }
        let via = MyRoad.viaPoints(path(corners, step: 25).map(xy), avoid: [])
        XCTAssertFalse(via.isEmpty)
        XCTAssertTrue(via.allSatisfy { $0.bearing >= 80 && $0.bearing <= 100 }, "\(via.map(\.bearing))")
    }

    func testNoViaNearHomeOrWork() {
        // Работа посреди пути (заезд мимо офиса) — и рядом с ней ни одной точки.
        let line = path([(0, 0), (3000, 0), (3000, 3000), (6000, 3000)]).map(xy)
        let office = xy(point(3000, 0))
        let via = MyRoad.viaPoints(line, avoid: [office])
        XCTAssertFalse(via.isEmpty)
        for v in via {
            XCTAssertGreaterThanOrEqual(simd_distance(v.point, office), AppConfig.myRoadPrivacyMeters)
        }
    }

    func testAtMostEightPoints() {
        // Зубчатая линия с поворотом каждые 400 м — точек всё равно не больше восьми.
        var corners: [(Double, Double)] = [(0, 0)]
        for i in 1...30 { corners.append((Double(i) * 400, i % 2 == 0 ? 0 : 300)) }
        let via = MyRoad.viaPoints(path(corners).map(xy), avoid: [])
        XCTAssertEqual(via.count, AppConfig.myRoadViaMax)
    }

    // MARK: - План

    func testPlanNeedsThreeTripsAndAStartNearTheLine() {
        let line = path([(0, 0), (4000, 0), (4000, 4000)])
        let home = line.last!, work = line.first!
        XCTAssertNil(MyRoad.plan(variants: [variant(line, rows: 2)], direction: .toHome,
                                 source: work, destination: home, home: home, work: work),
                     "две поездки — ещё не «моя дорога»")
        let plan = MyRoad.plan(variants: [variant(line, rows: 3)], direction: .toHome,
                               source: work, destination: home, home: home, work: work)
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.trips, 3)
        XCTAssertEqual(plan?.lineLength ?? 0, 8000, accuracy: 20)
        XCTAssertNil(MyRoad.plan(variants: [variant(line)], direction: .toHome,
                                 source: point(-1500, -800), destination: home, home: home, work: work),
                     "старт далеко от своей линии")
        XCTAssertNil(MyRoad.plan(variants: [variant(line)], direction: .toHome,
                                 source: work, destination: point(4000, 2500), home: home, work: work),
                     "линия кончается не у цели")
    }

    func testPlanStartsWhereTheCarIs() {
        // Машина уже на своей дороге, на третьем километре: остаток — от неё.
        let line = path([(0, 0), (4000, 0), (4000, 4000)])
        let home = line.last!, work = line.first!
        let plan = MyRoad.plan(variants: [variant(line)], direction: .toHome,
                               source: point(3000, 20), destination: home, home: home, work: work)
        XCTAssertEqual(plan?.fromAlong ?? 0, 3000, accuracy: 5)
        XCTAssertEqual(plan?.startOffset ?? 0, 20, accuracy: 2)
        XCTAssertEqual(plan?.lineLength ?? 0, 5000, accuracy: 20)
        XCTAssertTrue(plan?.via.allSatisfy { $0.along >= AppConfig.myRoadViaEdgeMeters } ?? false)
    }

    func testPlanPicksTheMostDrivenVariant() {
        let viaCentre = path([(0, 0), (4000, 0), (4000, 4000)])
        let viaRing = path([(0, 0), (0, 4000), (4000, 4000)])
        let home = viaCentre.last!, work = viaCentre.first!
        let plan = MyRoad.plan(variants: [variant(viaCentre, rows: 3), variant(viaRing, rows: 9)],
                               direction: .toHome, source: work, destination: home, home: home, work: work)
        XCTAssertEqual(plan?.trips, 9)
    }

    func testViaPointsKeepClearOfHomeAndWorkInPlan() {
        let line = path([(0, 0), (500, 0), (500, 3000), (4000, 3000), (4000, 3400)])
        let home = line.last!, work = line.first!
        let plan = MyRoad.plan(variants: [variant(line)], direction: .toHome,
                               source: work, destination: home, home: home, work: work)
        XCTAssertFalse(plan?.via.isEmpty ?? true)
        for v in plan?.via ?? [] {
            for place in [home, work] {
                XCTAssertGreaterThanOrEqual(GeoMath.fastDistance(v.latitude, v.longitude,
                                                                 place.latitude, place.longitude),
                                            AppConfig.myRoadPrivacyMeters - 1)
            }
        }
    }

    // MARK: - Тот же путь

    private func plan(_ line: [CLLocationCoordinate2D]) -> MyRoad.Plan {
        MyRoad.plan(variants: [variant(line)], direction: .toHome, source: line.first!,
                    destination: line.last!, home: line.last!, work: line.first!)!
    }

    func testRouteAlongTheLineIsAccepted() {
        let line = path([(0, 0), (4000, 0), (4000, 4000)])
        let p = plan(line)
        XCTAssertTrue(MyRoad.accepts(distance: length(line) * 1.05, path: line, plan: p))
    }

    func testLoopAtAViaPointIsRejected() {
        // Опорная точка легла на встречную проезжую часть: маршрут проехал
        // мимо, развернулся через 700 м и вернулся — путь тот же, длиннее на 1,4 км.
        let line = path([(0, 0), (4000, 0), (4000, 4000)])
        let looped = path([(0, 0), (4000, 0), (4000, 700), (4015, 700), (4015, 0), (4000, 0), (4000, 4000)])
        XCTAssertGreaterThan(length(looped), length(line) * 1.15)
        XCTAssertFalse(MyRoad.accepts(distance: length(looped), path: looped, plan: plan(line)))
    }

    func testParallelStreetIsNotMyRoad() {
        let line = path([(0, 0), (4000, 0), (4000, 4000)])
        let parallel = path([(0, 0), (0, 150), (3850, 150), (3850, 4000), (4000, 4000)])
        XCTAssertFalse(MyRoad.accepts(distance: length(parallel), path: parallel, plan: plan(line)))
    }

    func testEngineVariantOnMyRoadIsMarkedNotDuplicated() {
        let line = path([(0, 0), (4000, 0), (4000, 4000)])
        let other = path([(0, 0), (0, 4000), (4000, 4000)])
        let same = path([(0, 0), (4000, 8), (4000, 4000)])
        XCTAssertEqual(MyRoad.matching([other, same], plan: plan(line)), 1)
        XCTAssertNil(MyRoad.matching([other], plan: plan(line)))
        // Совпадает наполовину (общий первый отрезок) — не своя дорога.
        let half = path([(0, 0), (4000, 0), (8000, 0)])
        XCTAssertNil(MyRoad.matching([half], plan: plan(line)))
    }

    func testMyRoadTakesTheSlowestSlot() {
        XCTAssertEqual(MyRoad.slotToFree(times: [1500, 1700, 1600]), 1)
        XCTAssertNil(MyRoad.slotToFree(times: [1500, 1700]), "место есть — никого не вытесняем")
    }

    // MARK: - Перестроение (ревью 24.4)

    /// Своя дорога: 4 км на восток, 4 км на север. Опорные точки — на 2000
    /// (середина первой прямой), 4060 (после поворота) и 6000 м.
    private func commutePlan() -> MyRoad.Plan {
        plan(path([(0, 0), (4000, 0), (4000, 4000)]))
    }

    func testCommutePlanViaLayout() {
        XCTAssertEqual(commutePlan().via.map { Int($0.along.rounded()) }, [2000, 4060, 6000])
    }

    func testRerouteDropsViaPointsBehind() throws {
        let rest = try XCTUnwrap(MyRoad.remaining(commutePlan(), from: point(3000), course: 90))
        XCTAssertEqual(rest.via.count, 2, "точка на 2000 м пройдена")
        XCTAssertEqual(rest.via.map { Int($0.along.rounded()) }, [1060, 3000], "отсчёт — от машины")
        XCTAssertEqual(rest.fromAlong, 3000, accuracy: 5)
        XCTAssertEqual(rest.lineLength, 5000, accuracy: 20)
    }

    func testNearestViaTooCloseIsSkipped() throws {
        // До точки после поворота ~120 м — на неё без петли не вырулить.
        let rest = try XCTUnwrap(MyRoad.remaining(commutePlan(), from: point(3900), course: 90))
        XCTAssertEqual(rest.via.map { Int($0.along.rounded()) }, [2100])
    }

    func testNearestViaBehindByCourseIsSkipped() throws {
        // Ушли на квартал к северу и едем на запад: ближайшая точка впереди по
        // линии — у нас за спиной.
        let rest = try XCTUnwrap(MyRoad.remaining(commutePlan(), from: point(3500, 300), course: 270))
        XCTAssertEqual(rest.via.count, 1)
        XCTAssertEqual(rest.startOffset, 300, accuracy: 2)
        // Без курса (стоим) — точку не выбрасываем.
        XCTAssertEqual(MyRoad.remaining(commutePlan(), from: point(3500, 300))?.via.count, 2)
    }

    func testWentSidewaysAndBackFollowsOwnLineAgain() throws {
        // Объехали квартал: машина в 400 м к северу от своей линии.
        let rest = try XCTUnwrap(MyRoad.remaining(commutePlan(), from: point(2500, 400), course: 90))
        XCTAssertEqual(rest.via.count, 2)
        // Маршрут через оставшиеся точки возвращается на свою линию — принят.
        let back = path([(2500, 400), (2800, 400), (2800, 0), (4000, 0), (4000, 4000)])
        XCTAssertTrue(MyRoad.accepts(distance: length(back), path: back, plan: rest))
        // Маршрут движка той дорогой, на которую жаловались, — не своя дорога.
        let engine = path([(2500, 400), (2500, 4000), (4000, 4000)])
        XCTAssertFalse(MyRoad.accepts(distance: length(engine), path: engine, plan: rest))
        // Петля у опорной точки и при перестроении отбраковывается.
        let looped = path([(2500, 400), (2800, 400), (2800, 0), (4000, 0), (4000, 900), (4015, 900),
                           (4015, 0), (4000, 0), (4000, 4000)])
        XCTAssertFalse(MyRoad.accepts(distance: length(looped), path: looped, plan: rest))
    }

    func testNoViaLeftMeansEngine() {
        XCTAssertNil(MyRoad.remaining(commutePlan(), from: point(4000, 3000), course: 0),
                     "последняя точка пройдена — ведёт движок")
    }

    func testFarFromOwnLineMeansEngine() {
        XCTAssertNil(MyRoad.remaining(commutePlan(), from: point(2000, 1500), course: 90))
    }

    // MARK: - Запрос

    func testRequestKeepsViaPointsPassThroughAndDirected() {
        let via = [MyRoad.Via(latitude: 41.31, longitude: 69.25, bearing: 90, along: 500),
                   MyRoad.Via(latitude: 41.32, longitude: 69.26, bearing: 0, along: 1500)]
        let items = Dictionary(uniqueKeysWithValues: RouteService.osrmQueryItems(heading: nil, via: via)
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["waypoints"], "0;3", "одно плечо: без «прибытия» у каждой точки")
        XCTAssertEqual(items["continue_straight"], "true", "без разворота у опорной точки")
        XCTAssertEqual(items["alternatives"], "false")
        XCTAssertEqual(items["bearings"], ";90,\(AppConfig.myRoadViaBearingRange);0,\(AppConfig.myRoadViaBearingRange);")
        XCTAssertEqual(items["radiuses"]?.split(separator: ";", omittingEmptySubsequences: false).count, 4)
        let moving = Dictionary(uniqueKeysWithValues: RouteService.osrmQueryItems(heading: 270, via: via)
            .map { ($0.name, $0.value ?? "") })
        XCTAssertTrue(moving["bearings"]?.hasPrefix("270,") ?? false)
    }

    // MARK: - Время

    func testEstimateIsOwnMedianFromTheStart() throws {
        // 4 км = 20 участков по 20 с: обычно 400 с; с середины — 200.
        let line = path([(0, 0), (4000, 0)])
        let full = try XCTUnwrap(MyRoad.plan(variants: [variant(line)], direction: .toHome, source: line.first!,
                                             destination: line.last!, home: line.last!, work: point(-5000)))
        let estimate = try XCTUnwrap(MyRoad.estimate(full, now: at(8, 30), snapshot: nil, calendar: utc))
        XCTAssertEqual(estimate.seconds, 400, accuracy: 2)
        XCTAssertEqual(estimate.jamSeconds, 0)
        let half = try XCTUnwrap(MyRoad.plan(variants: [variant(line)], direction: .toHome, source: point(2000),
                                             destination: line.last!, home: line.last!, work: point(-5000)))
        XCTAssertEqual(try XCTUnwrap(MyRoad.estimate(half, now: at(8, 30), snapshot: nil, calendar: utc)).seconds,
                       200, accuracy: 2)
    }

    func testNoEstimateForAnHourWithoutTrips() throws {
        // Поездки утром, строим в 14:00 — медиана всего дня не «сейчас».
        let line = path([(0, 0), (4000, 0)])
        let p = try XCTUnwrap(MyRoad.plan(variants: [variant(line)], direction: .toHome, source: line.first!,
                                          destination: line.last!, home: line.last!, work: point(-5000)))
        XCTAssertNil(MyRoad.estimate(p, now: at(14), snapshot: nil, calendar: utc))
    }
}
