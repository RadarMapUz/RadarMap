//
//  CameraMarkerLookTests.swift
//  RadarMapTests
//
//  Вариант C «Точка» (владелец, 13.11): все стационарные — один облик
//  (точка вне пути, булавка на пути, красная булавка в тревоге), тренога и
//  передвижной радар — другой ФОРМОЙ, красный — только у тревоги, ни одна
//  камера не пропадает, тревога сверху, пометки не спорят с тревогой.
//

import XCTest
@testable import RadarMap

final class CameraMarkerLookTests: XCTestCase {

    private typealias Look = CameraMarkerLook

    func testPathMeansAheadOnOurRoute() {
        let path = Look.pathIDs(route: [(id: 1, along: 100), (id: 2, along: 900), (id: 3, along: 2_500)],
                                progress: 1_000, passedTolerance: 30, nearest: nil)
        XCTAssertEqual(path, [3], "позади по маршруту — уже не на пути")
        XCTAssertEqual(Look.tier(id: 3, alert: nil, path: path), .path)
        XCTAssertEqual(Look.tier(id: 1, alert: nil, path: path), .calm)
        XCTAssertEqual(Look.tier(id: 9, alert: nil, path: path), .calm, "соседний квартал — спокойная")
    }

    func testJustPassedCameraStillCountsWithinGPSNoise() {
        let path = Look.pathIDs(route: [(id: 1, along: 990)], progress: 1_000, passedTolerance: 30, nearest: nil)
        XCTAssertEqual(path, [1])
    }

    func testWithoutRouteTheHUDCameraIsOnThePath() {
        // Без маршрута — та же камера, что в HUD «136 м до камеры».
        let path = Look.pathIDs(route: [], progress: nil, passedTolerance: 30, nearest: 7)
        XCTAssertEqual(path, [7])
        XCTAssertEqual(Look.pathIDs(route: [(id: 1, along: 500)], progress: nil, passedTolerance: 30,
                                    nearest: nil), [], "маршрута нет — его камеры не наши")
    }

    /// Порядок поверх: тревога > тренога > на пути > спокойная.
    func testAlertThenTripodThenPathThenCalm() {
        XCTAssertEqual(Look.tier(id: 4, alert: 4, path: []), .alert)
        XCTAssertEqual(Look.tier(id: 4, alert: 4, path: [4]), .alert)
        let alert = Look.sortKey(.alert, figure: .pin)
        let tripod = Look.sortKey(.calm, figure: .diamond)
        XCTAssertEqual(tripod, Look.sortKey(.path, figure: .diamond), "тренога всегда в полный рост")
        XCTAssertGreaterThan(alert, tripod)
        XCTAssertGreaterThan(tripod, Look.sortKey(.path, figure: .pin))
        XCTAssertGreaterThan(Look.sortKey(.path, figure: .pin), Look.sortKey(.calm, figure: .pin))
    }

    // MARK: - Формы

    /// Владелец: «все радары одинаковые, только треногу по-другому нужно
    /// отмечать». Стационарные — одна форма и одна картинка; тренога и
    /// передвижной радар — другая ФОРМА (ромб), а не оттенок.
    func testStationaryAreOneMarkTripodIsAnotherShape() {
        let stationary: [CameraType] = [.stationaryCamera, .stationaryRadar, .intelligentRadar]
        for kind in stationary {
            XCTAssertEqual(kind.mapGlyph, .camera, kind.symbolName)
            XCTAssertEqual(Look.figure(kind.mapGlyph), .pin)
            for tier in [Look.Tier.calm, .path, .alert] {
                XCTAssertEqual(Look.icon(glyph: kind.mapGlyph, tier: tier, daylight: true),
                               Look.icon(glyph: .camera, tier: tier, daylight: true))
            }
        }
        for kind in [CameraType.tripod, .mobileRadar] {
            XCTAssertEqual(Look.figure(kind.mapGlyph), .diamond, kind.symbolName)
        }
        XCTAssertNotEqual(CameraType.tripod.mapGlyph, CameraType.mobileRadar.mapGlyph, "глиф говорит, что это")
        XCTAssertEqual(Look.figure(CameraType.accident.mapGlyph), .triangle)
        XCTAssertEqual(Look.figure(CameraType.dpsPost.mapGlyph), .pin)
        // Ромб ни в одном облике не совпадает формой с точкой или булавкой.
        let pinShapes = Set(Look.rasters(.camera).map(\.shape))
        let liveShapes = Set(Look.rasters(.tripod).map(\.shape))
        XCTAssertTrue(pinShapes.isDisjoint(with: liveShapes))
    }

    /// Тренога — всегда в полный размер: она возникла только что, её надо
    /// видеть и не на пути. Спокойная камера — точка.
    func testTripodNeverShrinksToADot() throws {
        for tier in [Look.Tier.calm, .path] {
            let suffix = Look.suffix(.diamond, tier: tier, daylight: true, own: false, ghost: false)
            let raster = try XCTUnwrap(Look.rasters(.tripod).first { $0.suffix == suffix })
            XCTAssertEqual(raster.shape, .diamond)
            XCTAssertGreaterThanOrEqual(raster.side, Look.pinSide)
        }
        let calm = try XCTUnwrap(Look.rasters(.camera).first { $0.suffix == "-calm-d" })
        XCTAssertEqual(calm.shape, .dot)
    }

    /// Красный — только у тревоги (и ДТП — оно само опасность). Камера на
    /// пути больше не краснеет: маршрут не превращается в красную цепочку.
    func testRedOnlyAtAlert() {
        for glyph in [CameraGlyph.camera, .post, .other, .tripod, .mobileRadar] {
            for raster in Look.rasters(glyph) where raster.suffix != "-alert" {
                XCTAssertNotEqual(raster.fill, Look.alertRGB, "\(glyph)\(raster.suffix) красный не в тревоге")
            }
            let alert = Look.rasters(glyph).first { $0.suffix == "-alert" }
            XCTAssertEqual(alert?.fill, Look.alertRGB, "\(glyph): тревога — красная")
            for daylight in [true, false] {
                XCTAssertNotEqual(Look.dotColor(glyph: glyph, tier: .path, daylight: daylight), Look.hex(Look.alertRGB))
                XCTAssertNotEqual(Look.dotColor(glyph: glyph, tier: .calm, daylight: daylight), Look.hex(Look.alertRGB))
                XCTAssertEqual(Look.dotColor(glyph: glyph, tier: .alert, daylight: daylight), Look.hex(Look.alertRGB))
            }
        }
    }

    // MARK: - Имена и растры

    /// Каждое имя, которое называет `icon`, есть среди растров движка — иначе
    /// камера этого облика не рисуется вовсе.
    func testEveryIconSuffixHasARaster() {
        for glyph in CameraGlyph.allCases {
            let suffixes = Set(Look.rasters(glyph).map(\.suffix))
            XCTAssertEqual(suffixes.count, Look.rasters(glyph).count, "\(glyph): облики не повторяются")
            for tier in [Look.Tier.calm, .path, .alert] {
                for daylight in [true, false] {
                    for own in [true, false] {
                        for ghost in [true, false] {
                            let name = Look.icon(glyph: glyph, tier: tier, daylight: daylight, own: own, ghost: ghost)
                            let suffix = String(name.dropFirst(Look.imageBase(glyph).count))
                            XCTAssertTrue(suffixes.contains(suffix), name)
                        }
                    }
                }
            }
        }
    }

    func testDayAndNightDiffer() {
        XCTAssertNotEqual(Look.icon(glyph: .camera, tier: .calm, daylight: true),
                          Look.icon(glyph: .camera, tier: .calm, daylight: false), "графит дня и ночи разный")
        XCTAssertNotEqual(Look.icon(glyph: .camera, tier: .path, daylight: true),
                          Look.icon(glyph: .camera, tier: .path, daylight: false))
        XCTAssertEqual(Look.icon(glyph: .camera, tier: .alert, daylight: true), "radar-camera-camera-alert")
    }

    /// Булавка стоит остриём на точке камеры; точка, ромб и треугольник — центром.
    func testPinStandsOnItsTip() {
        XCTAssertEqual(Look.anchor(.pin, tier: .path), "bottom")
        XCTAssertEqual(Look.anchor(.pin, tier: .alert), "bottom")
        XCTAssertEqual(Look.anchor(.pin, tier: .calm), "center", "точка — центром")
        XCTAssertEqual(Look.anchor(.diamond, tier: .alert), "center")
        XCTAssertEqual(Look.anchor(.triangle, tier: .path), "center")
        XCTAssertGreaterThan(Look.pinHeadLift(side: Look.pinAlertSide), Look.pinAlertSide / 2)
    }

    /// Тревога крупнее «на пути», та — крупнее точки.
    func testSizesRankByTier() {
        XCTAssertGreaterThan(Look.pinAlertSide, Look.pinSide)
        XCTAssertGreaterThan(Look.pinSide, Look.dotSide)
        XCTAssertGreaterThan(Look.diamondAlertSide, Look.diamondSide)
        XCTAssertGreaterThan(Look.triangleAlertSide, Look.triangleSide)
    }

    // MARK: - Пометки

    func testBadges() {
        XCTAssertEqual(Look.badge(figure: .diamond, tier: .calm, unconfirmed: true, familiar: false), Look.ghostBadge)
        XCTAssertEqual(Look.badge(figure: .diamond, tier: .alert, unconfirmed: true, familiar: false), Look.ghostBadge,
                       "слух остаётся слухом и в тревоге")
        XCTAssertEqual(Look.badge(figure: .pin, tier: .path, unconfirmed: false, familiar: true), Look.ownBadge)
        XCTAssertEqual(Look.badge(figure: .pin, tier: .alert, unconfirmed: false, familiar: true), "",
                       "идёт предупреждение — «своя» лишняя")
        XCTAssertEqual(Look.badge(figure: .pin, tier: .calm, unconfirmed: false, familiar: true), "",
                       "своя точка вне пути — зелёная сама, пометка 16 pt закрыла бы её")
        XCTAssertEqual(Look.badge(figure: .pin, tier: .calm, unconfirmed: false, familiar: false), "")
    }

    /// Своя камера вне пути видна без пометки: точка зелёная.
    func testOwnCalmDotIsGreen() throws {
        let day = try XCTUnwrap(Look.rasters(.camera).first { $0.suffix == "-own-d" })
        let night = try XCTUnwrap(Look.rasters(.camera).first { $0.suffix == "-own-n" })
        XCTAssertEqual(day.fill, Look.ownDayRGB)
        XCTAssertEqual(night.fill, Look.ownNightRGB)
        XCTAssertEqual(Look.icon(glyph: .camera, tier: .calm, daylight: true, own: true), "radar-camera-camera-own-d")
    }

    /// Пометка у правого верха головы булавки, а не у острия: для каждого
    /// места в стиле есть сдвиг, у булавки он выше головы.
    func testBadgeSitsOnTheHead() {
        let places = Dictionary(uniqueKeysWithValues: Look.badgePlaces.map { ($0.key, $0.offset) })
        XCTAssertEqual(places.count, 9)
        let pin = Look.badgeOffset(.pin, tier: .path)
        XCTAssertLessThan(pin.y, -Look.pinHeadLift(side: Look.pinSide), "пометка — у головы")
        XCTAssertGreaterThan(pin.x, 0)
        let diamond = Look.badgeOffset(.diamond, tier: .path)
        XCTAssertLessThan(diamond.y, 0)
        XCTAssertGreaterThan(diamond.y, -Look.diamondSide)
    }

    // MARK: - Видимость

    /// «Камера не исчезает»: точка вне пути видна на любом полотне карты в
    /// обе темы — заливка или кант ≥ 3:1 к фону (порог нетекстового
    /// элемента WCAG). Полотна — из server/omt/make_style.py.
    func testCalmDotIsVisibleOnEveryGround() throws {
        let grounds: [(daylight: Bool, name: String, rgb: UInt32)] = [
            (true, "земля", 0xF2F3F5), (true, "дорога", 0xFFFFFF), (true, "магистраль", 0xFFE2A8),
            (true, "парк", 0xCDEAC0), (true, "вода", 0xA9D5F7), (true, "дом", 0xE4E6EA),
            (false, "земля", 0x16181C), (false, "дорога", 0x40454F), (false, "магистраль", 0x626874),
            (false, "парк", 0x16271E), (false, "вода", 0x172A40), (false, "дом", 0x24272E),
            (false, "машина", 0x141619),
        ]
        for glyph in [CameraGlyph.camera, .post, .other] {
            for (daylight, name, ground) in grounds {
                for own in [false, true] {
                    let suffix = Look.suffix(.pin, tier: .calm, daylight: daylight, own: own, ghost: false)
                    let dot = try XCTUnwrap(Look.rasters(glyph).first { $0.suffix == suffix })
                    let best = max(contrast(dot.fill, ground), contrast(dot.rim, ground))
                    XCTAssertGreaterThanOrEqual(best, 3, "\(glyph)\(suffix) на «\(name)»")
                }
            }
        }
    }

    /// Глиф читается на своей фигуре (≥ 4,5:1): белый на графите и красном,
    /// тёмный на янтаре.
    func testGlyphIsReadableOnEveryFigure() {
        for glyph in CameraGlyph.allCases {
            for raster in Look.rasters(glyph) where raster.shape != .dot {
                XCTAssertGreaterThanOrEqual(contrast(raster.fill, raster.ink), 4.5, "\(glyph)\(raster.suffix)")
            }
        }
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func lum(_ hex: UInt32) -> Double {
            func c(_ v: UInt32) -> Double {
                let x = Double(v) / 255
                return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * c((hex >> 16) & 0xFF) + 0.7152 * c((hex >> 8) & 0xFF) + 0.0722 * c(hex & 0xFF)
        }
        let la = lum(a), lb = lum(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
