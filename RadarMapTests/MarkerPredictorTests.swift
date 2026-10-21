//
//  MarkerPredictorTests.swift
//  RadarMapTests
//
//  Значок «я» между фиксами (25.B): прямая без лага, поворот без проскока,
//  остановка без уезда, разворот, пропуск фиксов, поправка без шага назад —
//  и граница применения: конвейер оповещений предсказание не читает.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class MarkerPredictorTests: XCTestCase {

    private let origin = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.25)

    /// Точка в метрах на восток/север от начала.
    private func at(_ east: Double, _ north: Double) -> CLLocationCoordinate2D {
        MarkerPredictor.moved(origin, east: east, north: north)
    }

    /// Метры на восток/север от начала.
    private func xy(_ c: CLLocationCoordinate2D) -> (east: Double, north: Double) {
        MarkerPredictor.offset(from: origin, to: c)
    }

    private func fix(_ east: Double, _ north: Double, course: Double, speed: Double, time: Double,
                     path: [CLLocationCoordinate2D] = []) -> MarkerPredictor.Fix {
        MarkerPredictor.Fix(coordinate: at(east, north), courseDegrees: course, speedMps: speed,
                            time: time, path: path)
    }

    // MARK: - Прямая

    func testStraightMovesWithCarAndStopsAtHorizon() throws {
        var p = MarkerPredictor()
        p.update(fix(0, 0, course: 0, speed: 14, time: 0), now: 0, immediate: true)
        XCTAssertEqual(xy(try XCTUnwrap(p.pose(at: 1)).coordinate).north, 14, accuracy: 0.1)
        XCTAssertEqual(xy(try XCTUnwrap(p.pose(at: 1.5)).coordinate).north, 21, accuracy: 0.1)
        // Фиксов нет — дальше 1,5 с вперёд не угадываем.
        XCTAssertEqual(xy(try XCTUnwrap(p.pose(at: 4)).coordinate).north, 21, accuracy: 0.1)
        XCTAssertFalse(p.isMoving(at: 4), "горизонт исчерпан — такт кадров не нужен")
    }

    /// Замер «до/после» на синтетической прямой: прежняя стрелка (ход к
    /// последнему фиксу за интервал) против предсказателя. Фикс раз в 1 с,
    /// задержка фикса 0 (симулятор) и 0,5 с (телефон).
    func testLagAgainstOldGlide() {
        var report: [String] = []
        for latency in [0.0, 0.5] {
            for kmh in [30.0, 50.0, 60.0, 90.0] {
                let v = kmh / 3.6
                let old = Self.simulateOldGlide(speed: v, latency: latency)
                let new = simulatePredictor(speed: v, latency: latency)
                report.append(String(format: "%.0f км/ч, задержка %.1f с: было %.1f м (макс %.1f), стало %.1f м (макс %.1f)",
                                     kmh, latency, old.mean, old.max, new.mean, new.max))
                XCTAssertGreaterThan(old.mean, v * 0.9, "прежняя стрелка — на фикс позади")
                XCTAssertLessThan(abs(new.mean), 0.5, "на прямой значок там, где машина")
                XCTAssertLessThan(new.max, 1.0)
            }
        }
        print("ЛАГ ЗНАЧКА\n" + report.joined(separator: "\n"))
    }

    /// Прежний EngineMapView: на фиксе стрелка плывёт от нарисованной точки к
    /// фиксу ровно за интервал с прошлого фикса.
    private static func simulateOldGlide(speed v: Double, latency: Double) -> (mean: Double, max: Double) {
        var from = 0.0, to = 0.0, start = 0.0
        var lags: [Double] = []
        let frame = 1.0 / 30
        var nextFix = 0.0
        var t = 0.0
        while t < 30 {
            if t >= nextFix + latency {
                let shown = start == 0 && to == 0 ? 0 : from + (to - from) * min(1, (t - start) / 1)
                from = shown
                to = v * nextFix
                start = t
                nextFix += 1
            }
            let shown = from + (to - from) * min(1, (t - start) / 1)
            if t > 5 { lags.append(v * t - shown) }
            t += frame
        }
        return (lags.reduce(0, +) / Double(lags.count), lags.max() ?? 0)
    }

    private func simulatePredictor(speed v: Double, latency: Double) -> (mean: Double, max: Double) {
        var p = MarkerPredictor()
        var lags: [Double] = []
        let frame = 1.0 / 30
        var nextFix = 0.0
        var t = 0.0
        var first = true
        while t < 30 {
            if t >= nextFix + latency {
                p.update(fix(0, v * nextFix, course: 0, speed: v, time: nextFix), now: t, immediate: first)
                first = false
                nextFix += 1
            }
            if t > 5, let pose = p.pose(at: t) { lags.append(v * t - xy(pose.coordinate).north) }
            t += frame
        }
        return (lags.reduce(0, +) / Double(lags.count), lags.map(abs).max() ?? 0)
    }

    // MARK: - Поворот

    func testRouteCornerIsNotOvershot() throws {
        var p = MarkerPredictor()
        // На север 10 м, дальше направо — поворот 90°.
        let path = [at(0, 0), at(0, 10), at(50, 10)]
        p.update(fix(0, 0, course: 0, speed: 14, time: 0, path: path), now: 0, immediate: true)
        let pose = try XCTUnwrap(p.pose(at: 1.5))
        XCTAssertEqual(xy(pose.coordinate).north, 10, accuracy: 0.1)
        XCTAssertEqual(xy(pose.coordinate).east, 0, accuracy: 0.1, "за угол — только с фиксом")
        XCTAssertEqual(pose.courseDegrees, 0, accuracy: 0.5)
    }

    func testGentleRouteBendIsFollowed() throws {
        var p = MarkerPredictor()
        // Дуга: каждые 10 м курс +10° — линия плавная, значок идёт по ней.
        var path = [origin]
        var bearing = 0.0
        for _ in 0..<6 {
            path.append(GeoMath.destination(from: path.last!, bearing: bearing, distanceMeters: 10))
            bearing += 10
        }
        p.update(MarkerPredictor.Fix(coordinate: origin, courseDegrees: 0, speedMps: 20, time: 0, path: path),
                 now: 0, immediate: true)
        let pose = try XCTUnwrap(p.pose(at: 1.5))   // 30 м по дуге
        XCTAssertEqual(MarkerPredictor.distance(pose.coordinate, path[3]), 0, accuracy: 0.5)
        XCTAssertEqual(pose.courseDegrees, 20, accuracy: 1, "курс значка — курс отрезка, по которому он едет")
    }

    func testTurnWithoutRouteKeepsShortHorizon() throws {
        var p = MarkerPredictor()
        p.update(fix(0, 0, course: 0, speed: 8, time: 0), now: 0, immediate: true)
        p.update(fix(0, 8, course: 40, speed: 8, time: 1), now: 1)
        XCTAssertTrue(p.turning)
        let target = try XCTUnwrap(p.target(at: 3))
        XCTAssertEqual(MarkerPredictor.distance(target.coordinate, at(0, 8)), 8 * 0.5, accuracy: 0.1,
                       "в повороте по прямой от курса — не дальше полсекунды")
    }

    // MARK: - Остановка

    func testStandingStillDoesNotDrift() throws {
        var p = MarkerPredictor()
        p.update(fix(0, 0, course: 0, speed: 0, time: 0), now: 0, immediate: true)
        XCTAssertEqual(xy(try XCTUnwrap(p.pose(at: 10)).coordinate).north, 0, accuracy: 0.01)
        XCTAssertFalse(p.isMoving(at: 0.1))
    }

    /// Тормозили — значок чуть уехал вперёд; встали — короткий доезд назад
    /// к точке остановки, и ни метра дальше неё.
    func testStopAfterOvershootSettlesBackToFix() throws {
        var p = MarkerPredictor()
        p.update(fix(0, 0, course: 0, speed: 6, time: 0), now: 0, immediate: true)
        let ahead = xy(try XCTUnwrap(p.pose(at: 1)).coordinate).north   // 6 м
        p.update(fix(0, 3, course: 0, speed: 0, time: 1), now: 1)
        XCTAssertEqual(p.settle, .glideBack)
        XCTAssertEqual(xy(try XCTUnwrap(p.pose(at: 1)).coordinate).north, ahead, accuracy: 0.01, "без скачка")
        var last = ahead
        for step in 1...30 {
            let north = xy(try XCTUnwrap(p.pose(at: 1 + Double(step) / 60)).coordinate).north
            XCTAssertLessThanOrEqual(north, last + 0.001)
            XCTAssertGreaterThanOrEqual(north, 3 - 0.001, "назад дальше точки остановки — нельзя")
            last = north
        }
        XCTAssertEqual(xy(try XCTUnwrap(p.pose(at: 1.6)).coordinate).north, 3, accuracy: 0.01)
        XCTAssertFalse(p.isMoving(at: 1.6))
    }

    // MARK: - Разворот

    func testUTurnFollowsNewCourseWithoutJumpingBack() throws {
        var p = MarkerPredictor()
        p.update(fix(0, 0, course: 0, speed: 4, time: 0), now: 0, immediate: true)
        // Разворот: машина в 2 м севернее, едет на юг. Линия маршрута ещё
        // смотрит на север (не пересчитана) — ей не верим.
        let stale = [at(0, 2), at(0, 60)]
        p.update(fix(0, 2, course: 180, speed: 4, time: 1, path: stale), now: 1)
        var lastSouth = -Double.infinity
        for step in 0...45 {
            let pose = try XCTUnwrap(p.pose(at: 1 + Double(step) / 30))
            let south = -xy(pose.coordinate).north
            XCTAssertGreaterThanOrEqual(south, lastSouth - 0.001, "по новому курсу — только вперёд")
            lastSouth = south
        }
        XCTAssertEqual(xy(try XCTUnwrap(p.pose(at: 2.5)).coordinate).north, 2 - 4 * 1.5, accuracy: 0.3,
                       "едем на юг, а не по старой линии на север")
    }

    // MARK: - Пропуск фиксов и поправка

    func testThreeSecondGapThenCatchUpForward() throws {
        var p = MarkerPredictor()
        let v = 14.0
        p.update(fix(0, 0, course: 0, speed: v, time: 0), now: 0, immediate: true)
        // Фиксов нет 3 с: значок встаёт на 1,5 с впереди и ждёт.
        XCTAssertEqual(xy(try XCTUnwrap(p.pose(at: 2.9)).coordinate).north, 21, accuracy: 0.1)
        p.update(fix(0, 3 * v, course: 0, speed: v, time: 3), now: 3)
        XCTAssertEqual(p.settle, .catchUp)
        var last = 21.0
        for step in 0...60 {
            let t = 3 + Double(step) / 30
            let north = xy(try XCTUnwrap(p.pose(at: t)).coordinate).north
            XCTAssertGreaterThanOrEqual(north, last - 0.001, "догон — только вперёд")
            last = north
        }
        XCTAssertEqual(xy(try XCTUnwrap(p.pose(at: 4.5)).coordinate).north, 4.5 * v, accuracy: 0.5,
                       "за полторы секунды догнал")
    }

    /// Шум фикса вдоль дороги ±2 м на 50 км/ч: значок не шагает назад ни на кадре.
    func testNoisyFixesNeverStepBackward() throws {
        var p = MarkerPredictor()
        let v = 50 / 3.6
        let noise = [1.8, -1.5, 0.4, 2.0, -2.0, 1.1, -0.7, 1.9, -1.9, 0.0, 1.5, -1.2]
        var last = -Double.infinity
        var t = 0.0
        for (k, n) in noise.enumerated() {
            let time = Double(k)
            p.update(fix(0, v * time + n, course: 0, speed: v, time: time), now: time, immediate: k == 0)
            while t < time + 1 {
                let north = xy(try XCTUnwrap(p.pose(at: t)).coordinate).north
                if t >= time { XCTAssertGreaterThanOrEqual(north, last - 0.001, "шаг назад на \(t) с") }
                last = north
                t += 1.0 / 30
            }
        }
    }

    /// Новый фикс сильно позади нарисованного (10 м): короткий доезд за
    /// полсекунды, без телепорта — ни один кадр не прыгает больше чем на
    /// пару метров.
    func testLargeBackwardCorrectionIsShortGlide() throws {
        var p = MarkerPredictor()
        let v = 14.0
        p.update(fix(0, 0, course: 0, speed: v, time: 0), now: 0, immediate: true)
        let shown = xy(try XCTUnwrap(p.pose(at: 1)).coordinate).north   // 14
        p.update(fix(0, 4, course: 0, speed: v, time: 1), now: 1)       // оценка 4 м — на 10 позади
        XCTAssertEqual(p.settle, .glideBack)
        var last = shown
        for step in 1...30 {
            let north = xy(try XCTUnwrap(p.pose(at: 1 + Double(step) / 60)).coordinate).north
            XCTAssertLessThan(abs(north - last), 2, "кадр без рывка")
            last = north
        }
        XCTAssertEqual(xy(try XCTUnwrap(p.pose(at: 1.5)).coordinate).north, 4 + v * 0.5, accuracy: 0.1)
    }

    func testFarJumpIsPlacedImmediately() throws {
        var p = MarkerPredictor()
        p.update(fix(0, 0, course: 0, speed: 0, time: 0), now: 0, immediate: true)
        p.update(fix(0, 500, course: 0, speed: 0, time: 1), now: 1)
        XCTAssertEqual(xy(try XCTUnwrap(p.pose(at: 1)).coordinate).north, 500, accuracy: 0.01)
    }

    func testLateralErrorFadesWithoutMovingAlong() throws {
        var p = MarkerPredictor()
        p.update(fix(3, 0, course: 0, speed: 0, time: 0), now: 0, immediate: true)
        p.update(fix(0, 0, course: 0, speed: 0, time: 1), now: 1)
        let mid = xy(try XCTUnwrap(p.pose(at: 1.2)).coordinate)
        XCTAssertGreaterThan(mid.east, 0.5)
        XCTAssertEqual(mid.north, 0, accuracy: 0.01)
        XCTAssertEqual(xy(try XCTUnwrap(p.pose(at: 4)).coordinate).east, 0, accuracy: 0.01)
    }

    // MARK: - Граница: только картинка

    /// Предсказание — только для EngineMapView. В сервисах (оповещения,
    /// гейты, проезды, трек, скорость) фикс для значка можно только
    /// ЗАПИСАТЬ; ни `pose`, ни сам предсказатель там не появляются.
    func testPipelineNeverReadsPrediction() throws {
        let services = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RadarMap/Services")
        let files = FileManager.default.enumerator(at: services, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: .newlines) {
                let code = line.components(separatedBy: "//")[0]
                XCTAssertFalse(code.contains("MarkerPredictor()") || code.contains(".pose(at")
                               || code.contains(".target(at"),
                               "\(file.lastPathComponent): предсказание в конвейере — \(line)")
                if code.contains("markerMotion") {
                    XCTAssertTrue(code.contains("markerMotion =") || code.contains("var markerMotion"),
                                  "\(file.lastPathComponent): markerMotion читают — \(line)")
                }
            }
        }
    }
}
