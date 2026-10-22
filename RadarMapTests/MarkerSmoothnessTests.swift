//
//  MarkerSmoothnessTests.swift
//  RadarMapTests
//
//  «Не должен дёргаться, туда-сюда» (владелец, 22.10, план 27.A): значок «я»
//  и граница пройденной линии на шумных фиксах (±3–5 м вдоль дороги) с
//  неровным интервалом (0,8–1,5 с) едут плавно — ни кадра назад в движении,
//  без скачков между кадрами и без рывков скорости. Граница линии — под той
//  же сглаженной точкой, что значок (RouteCut.Tracker по MarkerPredictor), и
//  монотонна вперёд.
//
//  Метрики печатаются строкой «ПЛАВНОСТЬ …» — так снимались «до/после».
//

import CoreLocation
import XCTest
@testable import RadarMap

final class MarkerSmoothnessTests: XCTestCase {

    private let origin = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.25)

    private func at(_ north: Double) -> CLLocationCoordinate2D {
        MarkerPredictor.moved(origin, east: 0, north: north)
    }

    /// Детерминированный шум: xorshift, равномерно в [-1, 1].
    private struct Noise {
        var state: UInt64
        mutating func next() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 20_001) / 10_000 - 1
        }
    }

    struct Metrics {
        /// Кадров, где точка сдвинулась назад больше чем на сантиметр.
        var backward = 0
        /// Наибольший сдвиг за кадр, м.
        var maxStep = 0.0
        /// Наибольшее ускорение по скорости на окнах 0,1 с, м/с².
        var maxAccel = 0.0
        /// Отставание от истинной точки: среднее и худшее по модулю, м.
        var meanLag = 0.0
        var maxLag = 0.0
    }

    /// Поездка по прямой на север: фиксы с шумом вдоль дороги ±`noise` м
    /// (не меньше 3 м по модулю у половины), интервал 0,8–1,5 с, кадры 60/с.
    /// Значок и граница линии (RouteCut) считаются как в EngineMapView.
    private func drive(speed v: Double, noise amplitude: Double, seed: UInt64 = 0x9E37_79B9_7F4A_7C15,
                       seconds: Double = 60) -> (marker: Metrics, cut: Metrics) {
        var noise = Noise(state: seed)
        var predictor = MarkerPredictor()
        var tracker = RouteCut.Tracker()
        let line = RouteCut.Line([at(-100), at(v * seconds + 500)])
        let frame = 1.0 / 60
        var nextFix = 0.0
        var first = true
        var fixAlong = 0.0
        var marker: [(t: Double, s: Double)] = []
        var cut: [(t: Double, s: Double)] = []
        var t = 0.0
        while t < seconds {
            if t >= nextFix {
                let n = noise.next() * amplitude
                let s = v * nextFix + n
                let speed = v + noise.next() * 0.5
                fixAlong = s + 100
                predictor.update(MarkerPredictor.Fix(coordinate: at(s), courseDegrees: 0, speedMps: speed,
                                                     time: nextFix, path: [at(s), at(s + 80)]),
                                 now: t, immediate: first)
                first = false
                nextFix += 0.8 + (noise.next() + 1) / 2 * 0.7
            }
            if let pose = predictor.pose(at: t) {
                let north = MarkerPredictor.offset(from: origin, to: pose.coordinate).north
                marker.append((t, north))
                let along = tracker.advance(pose: pose.coordinate, course: 0, fixAlong: fixAlong,
                                            speedMps: v, line: line)
                cut.append((t, along - 100))
            }
            t += frame
        }
        return (metrics(marker, speed: v), metrics(cut, speed: v))
    }

    private func metrics(_ series: [(t: Double, s: Double)], speed v: Double) -> Metrics {
        var m = Metrics()
        let settled = series.filter { $0.t > 3 }
        for (a, b) in zip(settled, settled.dropFirst()) {
            let step = b.s - a.s
            if step < -0.01 { m.backward += 1 }
            m.maxStep = max(m.maxStep, abs(step))
        }
        // Скорость на окнах по 6 кадров (0,1 с), ускорение — между соседними окнами.
        let window = 6
        var speeds: [Double] = []
        var i = 0
        while i + window < settled.count {
            speeds.append((settled[i + window].s - settled[i].s) / (settled[i + window].t - settled[i].t))
            i += window
        }
        for (a, b) in zip(speeds, speeds.dropFirst()) {
            m.maxAccel = max(m.maxAccel, abs(b - a) / (Double(window) / 60))
        }
        let lags = settled.map { v * $0.t - $0.s }
        m.meanLag = lags.reduce(0, +) / Double(max(1, lags.count))
        m.maxLag = lags.map(abs).max() ?? 0
        return m
    }

    private func line(_ name: String, _ m: Metrics) -> String {
        String(format: "%@: назад %d кадров, скачок ≤ %.2f м/кадр, рывок ≤ %.1f м/с², отставание %.1f м (худшее %.1f)",
               name, m.backward, m.maxStep, m.maxAccel, m.meanLag, m.maxLag)
    }

    func testNoisyIrregularFixesNeverStepBackward() {
        var report: [String] = []
        for (kmh, amplitude) in [(50.0, 3.0), (50.0, 5.0), (30.0, 4.0), (90.0, 5.0)] {
            let v = kmh / 3.6
            let (marker, cut) = drive(speed: v, noise: amplitude)
            report.append(String(format: "%.0f км/ч, шум ±%.0f м — ", kmh, amplitude)
                          + line("значок", marker) + "; " + line("граница", cut))
            XCTAssertEqual(marker.backward, 0, "значок шагает назад на \(kmh) км/ч, шум \(amplitude) м")
            XCTAssertEqual(cut.backward, 0, "граница линии шагает назад")
            // Кадр 1/60 с: скачок не больше полутора скоростей кадра.
            XCTAssertLessThan(marker.maxStep, v * 1.6 / 60 + 0.05, "скачок значка между кадрами")
            XCTAssertLessThan(cut.maxStep, v * 1.6 / 60 + 0.05, "скачок границы между кадрами")
            XCTAssertLessThan(marker.maxAccel, AppConfig.markerMaxAccel * 2.5, "рывок скорости значка")
            XCTAssertLessThan(abs(marker.meanLag), 1.0, "значок в среднем там, где машина")
        }
        print("ПЛАВНОСТЬ\n" + report.joined(separator: "\n"))
    }

    /// Поправка назад (новый фикс сильно позади нарисованного) гасится
    /// скоростью: значок замедляется, но не едет назад и не прыгает.
    func testBackwardCorrectionIsAbsorbedBySpeed() throws {
        var p = MarkerPredictor()
        let v = 14.0
        p.update(MarkerPredictor.Fix(coordinate: at(0), courseDegrees: 0, speedMps: v, time: 0),
                 now: 0, immediate: true)
        var last = 0.0
        var lastT = 0.0
        var slowest = Double.infinity
        for k in 1...300 {
            let t = Double(k) / 60
            // С 1-й секунды фиксы на 10 м позади нарисованного: машина на
            // самом деле там, значку надо отдать 10 м.
            if k % 60 == 0 {
                let second = Double(k / 60)
                let truth = v * second - 10
                p.update(MarkerPredictor.Fix(coordinate: at(truth), courseDegrees: 0, speedMps: v,
                                             time: second), now: t)
            }
            let north = MarkerPredictor.offset(from: origin, to: try XCTUnwrap(p.pose(at: t)).coordinate).north
            XCTAssertGreaterThanOrEqual(north, last - 0.001, "шаг назад на \(t) с")
            XCTAssertLessThan(north - last, v * 1.7 / 60, "рывок вперёд на \(t) с")
            if t > 1 { slowest = min(slowest, (north - last) / (t - lastT)) }
            last = north
            lastT = t
        }
        XCTAssertGreaterThanOrEqual(slowest, v * AppConfig.markerMinSpeedShare * 0.9,
                                    "значок замедлился, а не встал и не поехал назад")
    }

    /// Неровный интервал без шума: значок на месте машины, поправок почти нет.
    func testIrregularIntervalWithoutNoiseStaysOnTheCar() {
        let (marker, _) = drive(speed: 50 / 3.6, noise: 0)
        XCTAssertEqual(marker.backward, 0)
        XCTAssertLessThan(marker.maxLag, 1.0)
    }
}
