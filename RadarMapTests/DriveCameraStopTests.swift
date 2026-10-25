//
//  DriveCameraStopTests.swift
//  RadarMapTests
//
//  Кадр остановки (29.D): поворот в 200 м от светофора — в кадре на любом
//  экране; внутри обычного окна подъезда остановка кадр не меняет; без
//  развилки — перекрёсток впереди не мельче полос; пробка — до конца, но не
//  районом; камера в кадре старше всего; трогаемся — без разворота зума;
//  пробка «ползком» не качает кадр.
//

import XCTest
@testable import RadarMap

final class DriveCameraStopTests: XCTestCase {

    private typealias Cam = DriveCamera
    private let tashkent = 41.3
    private let stand = StopView.State(standing: true, maneuverWindow: AppConfig.stopViewManeuverMeters)

    /// Экраны: высота вида, место «я», верхняя панель.
    private struct Screen {
        let name: String
        let height: Double
        let carY: Double
        let top: Double
        let kind: Cam.Screen
    }

    private let screens = [
        Screen(name: "телефон", height: 852, carY: 0.72, top: 0.18, kind: .phone),
        Screen(name: "SE", height: 667, carY: 0.70, top: 0.22, kind: .phone),
        Screen(name: "машина", height: 382, carY: 0.62, top: 0.12, kind: .car),
    ]

    private func frame(_ s: Screen, kmh: Double = 0, turn: Double? = nil, stop: StopView.State = .moving,
                       jam: Double? = nil, keep: Cam.Keep? = nil) -> Cam.Frame {
        Cam.target(speedKmh: kmh, maneuverDistance: turn, pitchAllowed: true, screen: s.kind, keep: keep,
                   stop: stop, jamEnd: jam, viewHeight: s.height, latitude: tashkent,
                   clear: Cam.Clear(top: s.top), carY: { _ in s.carY })
    }

    private func ahead(_ f: Cam.Frame, _ s: Screen) -> Double {
        Cam.visibleAhead(zoom: f.zoom, pitchDegrees: f.pitchDegrees, viewHeight: s.height,
                         carY: s.carY, latitude: tashkent, clearTop: s.top)
    }

    func testTurnAtTheLightIsInFrame() {
        for s in screens {
            let before = frame(s, turn: 200)
            XCTAssertLessThan(ahead(before, s), 200, "\(s.name): до 29.D поворот был за краем")
            let after = frame(s, turn: 200, stop: stand)
            XCTAssertGreaterThanOrEqual(ahead(after, s), 200, "\(s.name): поворот в 200 м виден стоя")
        }
    }

    func testFarTurnNeverZoomsToADistrict() {
        for s in screens {
            let f = frame(s, turn: 249, stop: stand)
            XCTAssertGreaterThanOrEqual(f.zoom, Cam.stopMinZoom(s.kind) - 1e-9, s.name)
        }
    }

    func testInsideTheUsualWindowNothingChanges() {
        for s in screens {
            for d in [60.0, 100, 140] {
                XCTAssertEqual(frame(s, turn: d), frame(s, turn: d, stop: stand),
                               "\(s.name), развилка в \(d) м: обычный подъезд не трогаем")
            }
        }
    }

    func testStandingWithoutTurnShowsTheJunctionKeepingLanes() {
        for s in screens {
            let f = frame(s, stop: StopView.State(standing: true))
            XCTAssertGreaterThanOrEqual(f.zoom, Cam.laneZoom - 1e-9, "\(s.name): полосы видны")
            XCTAssertGreaterThanOrEqual(ahead(f, s), ahead(frame(s), s) - 1e-6,
                                        "\(s.name): стоя видно не меньше, чем раньше")
        }
        let phone = screens[0]
        XCTAssertGreaterThanOrEqual(ahead(frame(phone, stop: StopView.State(standing: true)), phone),
                                    AppConfig.stopViewLookaheadPhone - 1)
    }

    func testJamIsFramedToItsEndButNotADistrict() {
        for s in screens {
            let plain = frame(s, stop: StopView.State(standing: true))
            let jam = frame(s, stop: StopView.State(standing: true), jam: 300)
            XCTAssertGreaterThan(ahead(jam, s), ahead(plain, s), "\(s.name): пробка видна дальше")
            XCTAssertGreaterThanOrEqual(jam.zoom, Cam.stopMinZoom(s.kind) - 1e-9, s.name)
            let long = frame(s, stop: StopView.State(standing: true), jam: 5_000)
            XCTAssertGreaterThanOrEqual(long.zoom, Cam.stopMinZoom(s.kind) - 1e-9, "\(s.name): не район")
        }
    }

    func testJamIgnoredOnTheMoveAndWhenTurnIsFramed() {
        let s = screens[0]
        XCTAssertEqual(frame(s, kmh: 40, jam: 300), frame(s, kmh: 40), "на ходу кадр — по скорости")
        XCTAssertEqual(frame(s, turn: 200, stop: stand, jam: 400), frame(s, turn: 200, stop: stand),
                       "развилка старше пробки")
    }

    func testKeptCameraStaysInFrameWhileStanding() {
        // Камера в 330 м впереди, поворот в 200: обе в кадре — камера старше.
        for s in screens {
            let keep = Cam.Keep(forward: 330, right: 0)
            let f = frame(s, turn: 200, stop: stand, keep: keep)
            let floor = Cam.keepMinZoom(speedKmh: 0)
            if f.zoom > floor + 1e-9 {
                XCTAssertGreaterThanOrEqual(ahead(f, s), 330, "\(s.name): камера в кадре")
            }
            XCTAssertLessThanOrEqual(f.zoom, frame(s, turn: 200, stop: stand).zoom + 1e-9, s.name)
        }
    }

    // MARK: - Во времени

    /// Прогон через StopView.Tracker и Smoother: (секунда, скорость, до развилки).
    private func run(_ s: Screen, _ steps: [(Double, Double, Double?)]) -> [Cam.Frame] {
        var tracker = StopView.Tracker()
        var smoother = Cam.Smoother()
        let t0 = Date(timeIntervalSince1970: 0)
        return steps.map { second, kmh, turn in
            let now = t0 + second
            let stop = tracker.update(speedKmh: kmh, maneuverDistance: turn, active: true, at: now)
            return smoother.step(toward: frame(s, kmh: kmh, turn: turn, stop: stop), at: now)
        }
    }

    func testStartingTowardTheTurnNeverZoomsBackOut() {
        // Стоим 40 с в 210 м от поворота, потом разгон 1,5 м/с² до 40 км/ч к нему.
        for s in screens {
            var steps: [(Double, Double, Double?)] = []
            for t in 0..<40 { steps.append((Double(t), t < 3 ? 30 - 10 * Double(t) : 0, 210)) }
            var d = 210.0, v = 0.0
            var t = 40.0
            while d > 90 {
                v = min(40 / 3.6, v + 1.5)
                d -= v
                steps.append((t, v * 3.6, d))
                t += 1
            }
            let frames = run(s, steps)
            // С начала старта (после выдержки кадра стоя) масштаб только растёт:
            // подъезд продолжается, отъезда назад к «я» нет.
            let go = Array(frames[40...])
            for (a, b) in zip(go, go.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b.zoom, a.zoom - 0.011, "\(s.name): кадр не отъезжает на старте")
            }
        }
    }

    func testCrawlingJamDoesNotRockTheFrame() {
        // Пробка: 12 с стоим, 6 с ползём 3–9 км/ч — три минуты; без развилки.
        for s in screens {
            var steps: [(Double, Double, Double?)] = [(0, 40, nil), (1, 25, nil), (2, 10, nil)]
            var noise: UInt64 = 0x9E37_79B9_7F4A_7C15
            for t in 3..<180 {
                noise ^= noise << 13; noise ^= noise >> 7; noise ^= noise << 17
                let phase = t % 18
                steps.append((Double(t), phase < 12 ? 0 : 3 + Double(noise % 600) / 100, nil))
            }
            let zooms = run(s, steps).map(\.zoom)
            var reversals = 0, direction = 0
            for (a, b) in zip(zooms, zooms.dropFirst()) where abs(b - a) > 0.005 {
                let d = b > a ? 1 : -1
                if direction != 0, d != direction { reversals += 1 }
                direction = d
                XCTAssertLessThanOrEqual(abs(b - a), AppConfig.driveZoomInLevelsPerSecond + 0.011,
                                         "\(s.name): без скачков зума")
            }
            XCTAssertLessThanOrEqual(reversals, 1, "\(s.name): вид не качается в пробке")
        }
    }
}
