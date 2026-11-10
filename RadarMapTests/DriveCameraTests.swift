//
//  DriveCameraTests.swift
//  RadarMapTests
//
//  Камера поездки: полосы видны там, где они решают, на любом экране;
//  впереди видно нужные секунды пути; развилка не уходит из кадра; плавно.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class DriveCameraTests: XCTestCase {

    private typealias Cam = DriveCamera
    private let tashkent = 41.31
    /// Высоты вида: CarPlay 1920×720 (382 pt), CarPlay 800×480, телефон.
    private let heights: [Double] = [382, 480, 760, 900]
    private let maxPitch = 45.0

    private func frame(_ kmh: Double, turn: Double? = nil, height: Double,
                       carY: Double = 0.7, pitch: Bool = true) -> Cam.Frame {
        Cam.target(speedKmh: kmh, maneuverDistance: turn, pitchAllowed: pitch, maxPitch: maxPitch,
                   viewHeight: height, latitude: tashkent, carY: { _ in carY })
    }

    private func ahead(_ f: Cam.Frame, height: Double, carY: Double = 0.7) -> Double {
        Cam.visibleAhead(zoom: f.zoom, pitchDegrees: f.pitchDegrees, viewHeight: height,
                         carY: carY, latitude: tashkent)
    }

    // MARK: - Полосы

    func testLanesAreVisibleStandingAndInTownOnEveryScreen() {
        // Владелец, 12.10: «полосы делали — не видны». Разметка в стиле — с 17.
        for height in heights {
            for kmh in stride(from: 0.0, through: 70, by: 5) {
                XCTAssertGreaterThanOrEqual(frame(kmh, height: height).zoom, Cam.laneZoom,
                                            "\(kmh) км/ч, экран \(height) pt")
            }
        }
    }

    func testBiggerScreenShowsMoreNotBigger() {
        // Масштаб не падает с ростом экрана: полоса не мельчает, а дороги больше.
        for kmh in stride(from: 0.0, through: 130, by: 10) {
            let small = frame(kmh, height: 382), big = frame(kmh, height: 900)
            XCTAssertGreaterThanOrEqual(big.zoom, small.zoom - 1e-9, "\(kmh) км/ч")
            XCTAssertGreaterThan(ahead(big, height: 900), ahead(small, height: 382) - 1e-6, "\(kmh) км/ч")
        }
    }

    // MARK: - Обзор и наклон

    func testStandingIsSlightlyPitched() {
        // До 22.10 стоя и ползком (≤ 5 км/ч) было строго сверху — владелец
        // видел плоский телефон рядом с наклонной машиной. С 27.L стоя —
        // лёгкий наклон, сверху — только у манёвра (DrivePitchTests).
        for kmh in [0.0, 3, 5, 10] {
            XCTAssertEqual(frame(kmh, height: 382).pitchDegrees, Cam.standingPitch, "\(kmh) км/ч")
        }
    }

    func testPitchGrowsWithSpeedAndNeverPassesTheEngineLimit() {
        var previous = -1.0
        for kmh in stride(from: 0.0, through: 200, by: 5) {
            let pitch = frame(kmh, height: 760).pitchDegrees
            XCTAssertGreaterThanOrEqual(pitch, previous, "\(kmh) км/ч")
            XCTAssertLessThanOrEqual(pitch, maxPitch, "предел перегрева движка")
            previous = pitch
        }
        XCTAssertGreaterThan(frame(100, height: 760).pitchDegrees, 30)
    }

    func testLookaheadSecondsAreVisibleUnlessTheFloorHolds() {
        for height in heights {
            for kmh in stride(from: 20.0, through: 130, by: 10) {
                let f = frame(kmh, height: height)
                let profile = Cam.profile(speedKmh: kmh, pitchAllowed: true, maxPitch: maxPitch)
                let needed = max(Cam.minLookaheadMeters, kmh / 3.6 * profile.lookaheadSeconds)
                let atFloor = abs(f.zoom - profile.minZoom) < 1e-9
                XCTAssertTrue(ahead(f, height: height) >= needed * 0.99 || atFloor,
                              "\(kmh) км/ч, экран \(height): видно \(Int(ahead(f, height: height))) из \(Int(needed)) м")
            }
        }
    }

    func testFlatModeHasNoPitchAndStillSeesAhead() {
        for kmh in stride(from: 0.0, through: 130, by: 10) {
            let f = frame(kmh, height: 760, pitch: false)
            XCTAssertEqual(f.pitchDegrees, 0)
            if kmh >= 40 {
                XCTAssertGreaterThan(ahead(f, height: 760), kmh / 3.6 * 8, "\(kmh) км/ч плоско")
            }
        }
    }

    // MARK: - Развилка

    func testTurnStaysInFrameAllTheWayIn() {
        // Прежняя камера стягивала охват, пока развилка была ЗА краем экрана.
        for height in heights {
            for kmh in stride(from: 30.0, through: 130, by: 10) {
                let window = min(Cam.maneuverWindowMax, max(Cam.maneuverWindowMin, kmh / 3.6 * Cam.maneuverLeadSeconds))
                for d in stride(from: 0.0, to: window, by: 10) {
                    let f = frame(kmh, turn: d, height: height)
                    XCTAssertGreaterThanOrEqual(ahead(f, height: height), d,
                                                "\(kmh) км/ч, развилка в \(d) м, экран \(height)")
                }
            }
        }
    }

    func testAtTheTurnLaneArrowsAreVisible() {
        for height in heights {
            for kmh in stride(from: 20.0, through: 130, by: 10) {
                for d in [0.0, 40, 80] {
                    let f = frame(kmh, turn: d, height: height)
                    XCTAssertGreaterThanOrEqual(f.zoom, Cam.laneZoom, "\(kmh) км/ч, \(d) м, экран \(height)")
                    XCTAssertLessThanOrEqual(f.pitchDegrees, Cam.maneuverPitch + 1e-9)
                }
            }
        }
    }

    func testFarTurnDoesNotTouchTheView() {
        XCTAssertEqual(frame(90, turn: 2_000, height: 760), frame(90, height: 760))
        XCTAssertEqual(frame(50, turn: 600, height: 382), frame(50, height: 382))
    }

    private func ahead(_ d: Double) -> Cam.Keep { Cam.Keep(forward: d, right: 0) }

    func testKeptObjectStaysInFrameOnTheSmallTile() {
        // Плитка главного экрана машины (374 pt): камера в 130–250 м впереди
        // обязана быть видна, даже стоя (carplay12: «радары не показывает»).
        for d in [130.0, 250] {
            let f = Cam.target(speedKmh: 0, maneuverDistance: nil, pitchAllowed: true, maxPitch: maxPitch,
                               keep: ahead(d), viewHeight: 374, latitude: tashkent, carY: { _ in 0.62 })
            XCTAssertGreaterThanOrEqual(ahead(f, height: 374, carY: 0.62), d, "камера в \(d) м")
        }
        // Камера в 480 м стоя — уже нет (25.A, 21.10): ради неё кадр уходил в
        // район (z14,7 на плитке), а в городе кадр не мельче z15,5 — камеру
        // видно, когда до неё ~290 м. Предел, а не прежний отъезд.
        let far480 = Cam.target(speedKmh: 0, maneuverDistance: nil, pitchAllowed: true, maxPitch: maxPitch,
                                keep: ahead(480), viewHeight: 374, latitude: tashkent, carY: { _ in 0.62 })
        XCTAssertEqual(far480.zoom, AppConfig.driveKeepMinZoomTown, accuracy: 1e-9)
        // Дальняя камера вид не трогает.
        let far = Cam.target(speedKmh: 0, maneuverDistance: nil, pitchAllowed: true, maxPitch: maxPitch,
                             keep: ahead(2_000), viewHeight: 374, latitude: tashkent, carY: { _ in 0.62 })
        XCTAssertEqual(far, Cam.target(speedKmh: 0, maneuverDistance: nil, pitchAllowed: true, maxPitch: maxPitch,
                                       viewHeight: 374, latitude: tashkent, carY: { _ in 0.62 }))
    }

    func testKeptObjectIsNotHiddenUnderTheTopPanel() {
        // Телефон, 12.10: «377 м до радара», а радар — под плашкой HUD у
        // верхней кромки. Обзор считается до нижнего края панели.
        let clear = Cam.Clear(top: 0.17), carY = 0.72
        for kmh in [0.0, 40, 70] {
            for d in [150.0, 377, 480] {
                let f = Cam.target(speedKmh: kmh, maneuverDistance: nil, pitchAllowed: true, maxPitch: maxPitch,
                                   keep: ahead(d), viewHeight: 760, latitude: tashkent, clear: clear,
                                   carY: { _ in carY })
                XCTAssertGreaterThanOrEqual(
                    Cam.visibleAhead(zoom: f.zoom, pitchDegrees: f.pitchDegrees, viewHeight: 760,
                                     carY: carY, latitude: tashkent, clearTop: clear.top), d,
                    "\(kmh) км/ч, камера в \(d) м")
            }
        }
        // Под панелью видно меньше, чем до края экрана, — и никогда не ноль.
        let plain = Cam.visibleAhead(zoom: 17, pitchDegrees: 30, viewHeight: 760, carY: carY, latitude: tashkent)
        let covered = Cam.visibleAhead(zoom: 17, pitchDegrees: 30, viewHeight: 760, carY: carY, latitude: tashkent,
                                       clearTop: clear.top)
        XCTAssertLessThan(covered, plain)
        XCTAssertGreaterThan(Cam.visibleAhead(zoom: 17, pitchDegrees: 0, viewHeight: 760, carY: carY,
                                              latitude: tashkent, clearTop: 0.95), 0, "панель ниже «я» — бред, не ноль")
    }

    /// Телефон 402×760, HUD сверху, панель поездки снизу, кнопки справа.
    private let phone = Cam.Clear(top: 0.17, bottom: 0.12, width: 402, side: 60)

    /// Точка (вперёд, вправо) в незакрытой части экрана при этом кадре — с
    /// перспективой: стоя с 27.L наклон 35°, и строка точки и её мерка
    /// поперёк — свои (`rowShare`, `lateralScale`); на наклоне 0 — прежний
    /// вид сверху.
    private func isVisible(_ keep: Cam.Keep, in f: Cam.Frame, carY: Double = 0.72) -> Bool {
        let row = Cam.rowShare(forward: keep.forward, zoom: f.zoom, pitchDegrees: f.pitchDegrees,
                               viewHeight: 760, carY: carY, latitude: tashkent)
        let perPoint = Cam.metersPerPoint(zoom: f.zoom, latitude: tashkent)
            * Cam.lateralScale(share: row, pitchDegrees: f.pitchDegrees)
        let y = 0.5 + row
        let side = 402 / 2 - phone.side
        return abs(keep.right / perPoint) <= side && y >= phone.top && y <= 1 - phone.bottom
    }

    func testKeptCameraBesideOrBehindIsInFrameToo() {
        // 12.10, Чиланзар: «136 м до камеры», стоя, а камера справа за краем
        // экрана — «вперёд» её не ловило.
        for keep in [Cam.Keep(forward: 20, right: 130), Cam.Keep(forward: 0, right: -136),
                     Cam.Keep(forward: -110, right: 30), Cam.Keep(forward: 90, right: 90)] {
            let f = Cam.target(speedKmh: 0, maneuverDistance: nil, pitchAllowed: true, maxPitch: maxPitch,
                               keep: keep, viewHeight: 760, latitude: tashkent, clear: phone,
                               carY: { _ in 0.72 })
            XCTAssertEqual(f.pitchDegrees, Cam.standingPitch, "стоя — лёгкий наклон (27.L)")
            XCTAssertTrue(isVisible(keep, in: f), "камера \(keep)")
        }
    }

    func testKeptCameraBesideKeepsItsMarginUnderStandingPitch() {
        // 27.L: стоя наклон 35°, а строка машины мельче центра на ~10 % —
        // мерка центра ставила камеру сбоку «136 м» под кнопки, съедая запас
        // значка. Точка обязана стоять с запасом `keepMarginPoints`. Дальше
        // ~120 м сбоку кадр упирается в городской предел z15,5 (25.A: предел
        // старше удержания) — там точка в кадре, но запас меньше; здесь —
        // случаи до предела.
        let carY = 0.72
        for keep in [Cam.Keep(forward: 0, right: -110), Cam.Keep(forward: 20, right: 105),
                     Cam.Keep(forward: 60, right: 95)] {
            let f = Cam.target(speedKmh: 0, maneuverDistance: nil, pitchAllowed: true, maxPitch: maxPitch,
                               keep: keep, viewHeight: 760, latitude: tashkent, clear: phone,
                               carY: { _ in carY })
            let row = Cam.rowShare(forward: keep.forward, zoom: f.zoom, pitchDegrees: f.pitchDegrees,
                                   viewHeight: 760, carY: carY, latitude: tashkent)
            let perPoint = Cam.metersPerPoint(zoom: f.zoom, latitude: tashkent)
                * Cam.lateralScale(share: row, pitchDegrees: f.pitchDegrees)
            XCTAssertGreaterThan(f.zoom, AppConfig.driveKeepMinZoomTown + 0.05, "не предел: \(keep)")
            XCTAssertLessThanOrEqual(abs(keep.right) / perPoint, 402 / 2 - phone.side - Cam.keepMarginPoints + 1,
                                     "камера \(keep)")
        }
    }

    func testRowShareIsTheInverseOfTheGroundOffset() {
        for pitch in [0.0, 35, 58] {
            let span = Cam.span(zoom: 17.5, viewHeight: 760, latitude: tashkent)
            for share in [-0.4, -0.1, 0, 0.2, 0.45] {
                let toward = Cam.groundOffset(spanMeters: span, share: share, pitchDegrees: pitch)
                let forward = Cam.centreAhead(spanMeters: span, anchorY: 0.72, pitchDegrees: pitch) - toward
                XCTAssertEqual(Cam.rowShare(forward: forward, zoom: 17.5, pitchDegrees: pitch, viewHeight: 760,
                                            carY: 0.72, latitude: tashkent), share, accuracy: 1e-9,
                               "\(pitch)°, строка \(share)")
            }
        }
    }

    func testUnknownDirectionFitsAnySide() {
        // Курса нет, поворот карты неизвестен — точка влезает в любую сторону.
        let d = 136.0
        let f = Cam.target(speedKmh: 0, maneuverDistance: nil, pitchAllowed: true, maxPitch: maxPitch,
                           keep: Cam.Keep(forward: d, right: 0, anyDirection: true),
                           viewHeight: 760, latitude: tashkent, clear: phone, carY: { _ in 0.72 })
        for keep in [Cam.Keep(forward: d, right: 0), Cam.Keep(forward: -d, right: 0),
                     Cam.Keep(forward: 0, right: d), Cam.Keep(forward: 0, right: -d)] {
            XCTAssertTrue(isVisible(keep, in: f), "в сторону \(keep)")
        }
    }

    func testKeptCameraDoesNotZoomOutMoreThanNeeded() {
        // Камера прямо впереди в 60 м — полосы остаются (порог z17 не трогается).
        let f = Cam.target(speedKmh: 0, maneuverDistance: nil, pitchAllowed: true, maxPitch: maxPitch,
                           keep: ahead(60), viewHeight: 760, latitude: tashkent, clear: phone, carY: { _ in 0.72 })
        XCTAssertGreaterThanOrEqual(f.zoom, Cam.laneZoom)
    }

    func testKeepOffsetFollowsTheMapRotation() {
        let car = CLLocationCoordinate2D(latitude: tashkent, longitude: 69.24)
        let east = CLLocationCoordinate2D(latitude: tashkent, longitude: 69.24 + 100 / (cos(tashkent * .pi / 180) * 111_320))
        let north = Cam.Keep.offset(from: car, to: east, bearing: 0)
        XCTAssertEqual(north.forward, 0, accuracy: 0.5)
        XCTAssertEqual(north.right, 100, accuracy: 0.5, "север вверху — восток справа")
        let facingEast = Cam.Keep.offset(from: car, to: east, bearing: 90)
        XCTAssertEqual(facingEast.forward, 100, accuracy: 0.5, "едем на восток — точка впереди")
        XCTAssertEqual(facingEast.right, 0, accuracy: 0.5)
        let unknown = Cam.Keep.offset(from: car, to: east, bearing: nil)
        XCTAssertTrue(unknown.anyDirection)
        XCTAssertEqual(unknown.distance, 100, accuracy: 0.5)
    }

    // MARK: - Экран машины

    /// CarPlay 1920×720 (382 pt) и 800×480.
    private let carHeights: [Double] = [382, 480]

    private func carFrame(_ kmh: Double, turn: Double? = nil, height: Double,
                          carY: Double = 0.7, pitch: Bool = true) -> Cam.Frame {
        Cam.target(speedKmh: kmh, maneuverDistance: turn, pitchAllowed: pitch, maxPitch: maxPitch,
                   screen: .car, viewHeight: height, latitude: tashkent, carY: { _ in carY })
    }

    func testCarSeesTheRoadAheadInTown() {
        // 18.10, «при езде нормального вида нет»: на экране машины впереди
        // было 106 м на 40 км/ч и 175 м на 60 — перекрёсток за краем.
        for height in carHeights {
            XCTAssertGreaterThanOrEqual(ahead(carFrame(40, height: height), height: height), 250, "40 км/ч, \(height) pt")
            XCTAssertGreaterThanOrEqual(ahead(carFrame(60, height: height), height: height), 380, "60 км/ч, \(height) pt")
            XCTAssertGreaterThan(ahead(carFrame(60, height: height), height: height),
                                 ahead(frame(60, height: height), height: height) * 2, "вдвое дальше прежнего")
        }
    }

    func testCarStandingIsOnTheLanes() {
        for height in carHeights {
            for kmh in [0.0, 5, 10, 15] {
                let f = carFrame(kmh, height: height)
                // Стоя и ползком — лёгкий наклон, как на телефоне (27.L; до
                // 22.10 здесь было «сверху ≤ 5 км/ч»), полосы и перекрёсток — те же.
                if kmh <= 10 { XCTAssertEqual(f.pitchDegrees, Cam.standingPitch, "\(kmh) км/ч") }
                XCTAssertGreaterThanOrEqual(f.zoom, Cam.laneZoom, "\(kmh) км/ч, \(height) pt — полосы")
                XCTAssertGreaterThanOrEqual(ahead(f, height: height), Cam.carMinLookaheadMeters * 0.99,
                                            "перекрёсток впереди целиком")
            }
        }
    }

    func testCarTurnBringsTheLanesBack() {
        // На ходу в городе разметки нет — у манёвра она обязана вернуться.
        for height in carHeights {
            for kmh in stride(from: 20.0, through: 130, by: 10) {
                for d in [0.0, 40, 80] {
                    let f = carFrame(kmh, turn: d, height: height)
                    XCTAssertGreaterThanOrEqual(f.zoom, Cam.laneZoom, "\(kmh) км/ч, \(d) м, \(height) pt")
                    XCTAssertLessThanOrEqual(f.pitchDegrees, Cam.maneuverPitch + 1e-9)
                }
            }
        }
    }

    func testCarTurnStaysInFrameAllTheWayIn() {
        for height in carHeights {
            for kmh in stride(from: 30.0, through: 130, by: 10) {
                let window = min(Cam.maneuverWindowMax, max(Cam.maneuverWindowMin, kmh / 3.6 * Cam.maneuverLeadSeconds))
                for d in stride(from: 0.0, to: window, by: 10) {
                    XCTAssertGreaterThanOrEqual(ahead(carFrame(kmh, turn: d, height: height), height: height), d,
                                                "\(kmh) км/ч, развилка в \(d) м, \(height) pt")
                }
            }
        }
    }

    func testCarPitchNeverPassesTheEngineLimitAndFlatHasNone() {
        for kmh in stride(from: 0.0, through: 200, by: 5) {
            XCTAssertLessThanOrEqual(carFrame(kmh, height: 382).pitchDegrees, maxPitch, "\(kmh) км/ч")
            XCTAssertEqual(carFrame(kmh, height: 382, pitch: false).pitchDegrees, 0, "\(kmh) км/ч плоско")
        }
        // Плоско (горячий телефон) обзор добирает отдалением.
        XCTAssertGreaterThanOrEqual(ahead(carFrame(60, height: 382, pitch: false), height: 382), 280)
    }

    func testCarBiggerScreenShowsMoreNotBigger() {
        for kmh in stride(from: 0.0, through: 130, by: 10) {
            let small = carFrame(kmh, height: 382), big = carFrame(kmh, height: 480)
            XCTAssertGreaterThanOrEqual(big.zoom, small.zoom - 1e-9, "\(kmh) км/ч")
            XCTAssertGreaterThan(ahead(big, height: 480), ahead(small, height: 382) - 1e-6, "\(kmh) км/ч")
        }
    }

    // MARK: - Геометрия

    func testTopDownGeometryIsThePlainFormula() {
        let span = 300.0
        XCTAssertEqual(Cam.centreAhead(spanMeters: span, anchorY: 0.7, pitchDegrees: 0), span * 0.2, accuracy: 1e-6)
        let zoom = 17.0
        let full = Cam.span(zoom: zoom, viewHeight: 382, latitude: tashkent)
        XCTAssertEqual(Cam.visibleAhead(zoom: zoom, pitchDegrees: 0, viewHeight: 382, carY: 0.7, latitude: tashkent),
                       full * 0.7, accuracy: 1e-6)
        // z17 на 382 pt в Ташкенте — около 171 м по высоте.
        XCTAssertEqual(full, 171, accuracy: 2)
    }

    func testPitchedCarNeedsMoreGroundToSitWhereIntended() {
        // Формула вида сверху на наклоне ставила машину выше задуманного:
        // чтобы она стояла на anchorY, центр уходит дальше вперёд.
        let flat = Cam.centreAhead(spanMeters: 300, anchorY: 0.72, pitchDegrees: 0)
        let pitched = Cam.centreAhead(spanMeters: 300, anchorY: 0.72, pitchDegrees: 45)
        XCTAssertGreaterThan(pitched, flat * 1.15)
        XCTAssertEqual(Cam.centreAhead(spanMeters: 300, anchorY: 0.5, pitchDegrees: 45), 0, accuracy: 1e-6)
    }

    func testZoomShowingInvertsVisibleAhead() {
        for pitch in [0.0, 30, 45] {
            let z = Cam.zoomShowing(250, pitchDegrees: pitch, viewHeight: 480, carY: 0.7, latitude: tashkent)
            XCTAssertEqual(Cam.visibleAhead(zoom: z, pitchDegrees: pitch, viewHeight: 480, carY: 0.7,
                                            latitude: tashkent), 250, accuracy: 0.5)
        }
    }

    // MARK: - Место машины на экране машины (85)

    /// Окна CarPlay: бар 50 сверху, плашка улицы снизу, кнопки справа.
    private let carWindows: [(width: Double, height: Double)] = [(800, 480), (940, 471), (1015, 382)]
    private let carSpeeds: [Double] = [0, 5, 15, 30, 50, 70, 90, 130]

    /// До 85: доля по скорости (0,62 стоя … 0,75) и док снизу на всю ширину.
    private func oldCarShare(_ kmh: Double) -> Double {
        let knots: [(Double, Double)] = [(0, 0.62), (15, 0.62), (30, 0.66), (50, 0.70), (70, 0.72), (90, 0.74),
                                         (110, 0.75)]
        guard kmh > 0 else { return 0.62 }
        for (a, b) in zip(knots, knots.dropFirst()) where kmh <= b.0 {
            return a.1 + (b.1 - a.1) * (kmh - a.0) / (b.0 - a.0)
        }
        return 0.75
    }

    func testCarSitsLowWithAQuarterOfTheFieldBehind() {
        for w in carWindows {
            for kmh in carSpeeds {
                let share = Cam.profile(speedKmh: kmh, pitchAllowed: true, screen: .car).carShare
                let y = CarPlaySurface.carMeY(height: w.height, safeTop: 50, safeBottom: 0, share: share) * w.height
                let behind = (w.height - y) / (w.height - 50)
                let wanted: ClosedRange<Double> = w.height >= 470 ? 0.20...0.25 : 0.20...0.30
                XCTAssertTrue(wanted.contains(behind), "\(w), \(kmh) км/ч: позади \(Int(behind * 100)) % поля")
                let before = (w.height - (62 + (w.height - 74) * oldCarShare(kmh))) / (w.height - 50)
                if kmh < 90 { XCTAssertLessThan(behind, before, "\(w), \(kmh) км/ч: машина ниже прежнего") }
            }
        }
    }

    func testCarStaysAboveTheBottomRowWithClearance() {
        for w in carWindows {
            let clear = CarPlaySurface.carClear(width: w.width, height: w.height, safeTop: 50, safeBottom: 0, side: 60)
            for kmh in carSpeeds {
                let share = Cam.profile(speedKmh: kmh, pitchAllowed: true, screen: .car).carShare
                let y = CarPlaySurface.carMeY(height: w.height, safeTop: 50, safeBottom: 0, share: share)
                XCTAssertGreaterThanOrEqual((1 - clear.bottom - y) * w.height,
                                            AppConfig.carPlayMeClearancePoints - 1e-6, "\(w), \(kmh) км/ч")
                let f = Cam.target(speedKmh: kmh, maneuverDistance: nil, pitchAllowed: true, screen: .car,
                                   viewHeight: w.height, latitude: tashkent, clear: clear,
                                   carY: { CarPlaySurface.carMeY(height: w.height, safeTop: 50, safeBottom: 0,
                                                                 share: $0) })
                XCTAssertGreaterThan(Cam.visibleBehind(zoom: f.zoom, pitchDegrees: f.pitchDegrees, viewHeight: w.height,
                                                       carY: y, latitude: tashkent, clearBottom: clear.bottom), 0,
                                     "\(w), \(kmh) км/ч: позади машины есть открытая дорога")
            }
        }
    }

    func testLoweredCarSeesNoLessRoadAhead() {
        for w in carWindows {
            let clear = CarPlaySurface.carClear(width: w.width, height: w.height, safeTop: 50, safeBottom: 0, side: 60)
            let oldClear = Cam.Clear(top: 50 / w.height, bottom: 112 / w.height, width: w.width, side: 120,
                                     topKeepPoints: Cam.keepMarginPoints)
            for kmh in carSpeeds {
                let newY: (Double) -> Double = { CarPlaySurface.carMeY(height: w.height, safeTop: 50, safeBottom: 0,
                                                                       share: $0) }
                let oldY: (Double) -> Double = { _ in (62 + (w.height - 74) * self.oldCarShare(kmh)) / w.height }
                func seen(_ carY: @escaping (Double) -> Double, _ clear: Cam.Clear) -> Double {
                    let f = Cam.target(speedKmh: kmh, maneuverDistance: nil, pitchAllowed: true, screen: .car,
                                       viewHeight: w.height, latitude: tashkent, clear: clear, carY: carY)
                    return Cam.visibleAhead(zoom: f.zoom, pitchDegrees: f.pitchDegrees, viewHeight: w.height,
                                            carY: carY(f.carShare), latitude: tashkent, clearTop: clear.top)
                }
                XCTAssertGreaterThanOrEqual(seen(newY, clear), seen(oldY, oldClear) - 0.5, "\(w), \(kmh) км/ч")
            }
        }
    }

    func testCarRowDoesNotRideWithSpeed() {
        let shares = carSpeeds.map { Cam.profile(speedKmh: $0, pitchAllowed: true, screen: .car).carShare }
        XCTAssertEqual(Set(shares), [AppConfig.carPlayMeShare], "машина не ездит по экрану со скоростью")
        XCTAssertEqual(Cam.profile(speedKmh: 40, pitchAllowed: false, screen: .car).carShare, AppConfig.carPlayMeShare)
    }

    func testPhoneAlreadyKeepsAQuarterBehind() {
        // Телефон: «я» на 0,78 видимой части между панелями — позади 22 %, менять нечего.
        XCTAssertTrue((0.20...0.25).contains(1 - MapViewport.meY))
    }

    // MARK: - Плавность

    func testSmootherGlidesWithoutOvershootAndArrives() {
        var smoother = Cam.Smoother()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let start = Cam.Frame(zoom: 18, pitchDegrees: 0, carShare: 0.62)
        let goal = Cam.Frame(zoom: 17, pitchDegrees: 40, carShare: 0.72)
        XCTAssertEqual(smoother.step(toward: start, at: t0), start, "первый кадр — сразу")
        var previous = start
        for second in 1...15 {
            let f = smoother.step(toward: goal, at: t0 + Double(second))
            XCTAssertLessThanOrEqual(f.zoom, previous.zoom)
            XCTAssertGreaterThanOrEqual(f.zoom, goal.zoom, "без перелёта")
            XCTAssertGreaterThanOrEqual(f.pitchDegrees, previous.pitchDegrees)
            XCTAssertLessThanOrEqual(f.pitchDegrees, goal.pitchDegrees)
            if second == 1 {
                // 25.A: отъезд не быстрее уровня за 8 с (было «за секунду
                // ниже 17,8» — экспонента τ 2 с, которая и повторяла скачки цели).
                XCTAssertLessThan(f.zoom, 18, "движется сразу")
                XCTAssertGreaterThanOrEqual(f.zoom, 18 - AppConfig.driveZoomOutLevelsPerSecond - 0.011,
                                            "но не быстрее предела отъезда")
            }
            previous = f
        }
        XCTAssertEqual(previous, goal, "доходит ровно до цели")
    }

    func testSteadyTargetDoesNotDrift() {
        var smoother = Cam.Smoother()
        let t0 = Date(timeIntervalSince1970: 0)
        let goal = Cam.Frame(zoom: 17.23, pitchDegrees: 36.5, carShare: 0.7)
        _ = smoother.step(toward: goal, at: t0)
        for second in 1...30 {
            XCTAssertEqual(smoother.step(toward: goal, at: t0 + Double(second)), goal)
        }
    }

    func testLongPauseJumpsStraightToTarget() {
        var smoother = Cam.Smoother()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = smoother.step(toward: Cam.Frame(zoom: 18, pitchDegrees: 0, carShare: 0.62), at: t0)
        let goal = Cam.Frame(zoom: 16.5, pitchDegrees: 45, carShare: 0.75)
        XCTAssertEqual(smoother.step(toward: goal, at: t0 + 60), goal)
    }

    // MARK: - Поворот карты (снимок CarPlay 21.10, 08:28)

    /// MapLibre молча выбрасывает отрицательный курс камеры. Карта шла на 2°
    /// (на север по маршруту), машина повернула налево на запад: развёрнутый
    /// «кратчайший» угол давал −90°, движок его не применял, и карта стояла
    /// на севере, пока стрелка «я» смотрела влево (прогон: курс 321°, карта
    /// 30° — тридцать секунд). Камере — только [0, 360).
    func testCameraHeadingAfterALeftTurnThroughNorthIsNeverNegative() {
        XCTAssertEqual(EngineMapPresentation.heading(270, near: 2), -90,
                       "развёрнутый угол — для стрелки, камере такой нельзя")
        XCTAssertEqual(EngineMapPresentation.cameraHeading(270, current: 2), 270)
        XCTAssertEqual(EngineMapPresentation.cameraHeading(321, current: 30), 321)
        // После перестроения «назад» карта стояла на 90°, а машина ехала на 271°.
        XCTAssertEqual(EngineMapPresentation.cameraHeading(271, current: 90), 271)
        XCTAssertEqual(EngineMapPresentation.cameraHeading(1, current: 359), 1)
        for current in stride(from: -720.0, through: 720, by: 37) {
            for course in stride(from: 0.0, through: 359.5, by: 13.5) {
                let heading = EngineMapPresentation.cameraHeading(course, current: current)
                XCTAssertGreaterThanOrEqual(heading, 0, "карта \(current)°, курс \(course)°")
                XCTAssertLessThan(heading, 360)
                XCTAssertEqual(heading, course, accuracy: 1e-9)
            }
        }
    }

    /// Без курса карта держит свой поворот — тоже в [0, 360).
    func testCameraHeadingWithoutCourseKeepsTheMapTurn() {
        XCTAssertEqual(EngineMapPresentation.cameraHeading(-1, current: 123), 123)
        XCTAssertEqual(EngineMapPresentation.cameraHeading(.nan, current: 123), 123)
        XCTAssertEqual(EngineMapPresentation.cameraHeading(-1, current: -30), 330)
        XCTAssertEqual(EngineMapPresentation.cameraHeading(-1, current: 725), 5)
        XCTAssertEqual(EngineMapPresentation.cameraHeading(720.5, current: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(EngineMapPresentation.cameraHeading(-1, current: .nan), 0)
    }
}
