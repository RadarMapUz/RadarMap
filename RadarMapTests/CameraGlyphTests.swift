//
//  CameraGlyphTests.swift
//  RadarMapTests
//
//  Значок камеры «Монета» (29.C): один источник глифа и цвета на все
//  поверхности. Тесты держат то, что глазами не проверить на каждом билде:
//  строка типа переводится в глиф без потерь (иначе Live Activity и часы
//  молча нарисуют «прочее»), глиф не вылезает за сетку, линия на мелком
//  значке не тоньше 1,5 pt, глиф читается на своей заливке, глифы типов
//  различимы силуэтом, а цвет типа — одно число на приложение, движок и
//  виджеты.
//

import XCTest
import UIKit
import SwiftUI
@testable import RadarMap

final class CameraGlyphTests: XCTestCase {

    private let kinds: [CameraType] = [.stationaryCamera, .stationaryRadar, .intelligentRadar,
                                       .mobileRadar, .tripod, .dpsPost, .accident, .other("x")]

    func testTypeStringTranslatesBackWithoutLoss() {
        for kind in kinds {
            XCTAssertEqual(CameraGlyph(symbol: kind.symbolName), kind.glyph, kind.symbolName)
        }
        XCTAssertEqual(Set(kinds.map(\.glyph)), Set(CameraGlyph.allCases), "у каждого глифа есть тип")
        // Состояния Live Activity — не камеры: им свой символ, не «прочее».
        XCTAssertNil(CameraGlyph(symbol: "checkmark.shield.fill"))
        XCTAssertNil(CameraGlyph(symbol: "location.slash.fill"))
        XCTAssertNil(CameraGlyph(symbol: nil))
    }

    /// Владелец, 26.10 (29.C2): «все камеры — одна иконка, они вроде все
    /// радары». Всё, что меряет скорость или фиксирует нарушения, — один глиф
    /// и один цвет; отдельно — только не камеры: пост ДПС, ДТП, «прочее».
    func testEveryCameraTypeIsOneIcon() {
        let cameras: [CameraType] = [.stationaryCamera, .stationaryRadar, .intelligentRadar, .mobileRadar, .tripod]
        for kind in cameras {
            XCTAssertEqual(kind.glyph, .camera, kind.symbolName)
            XCTAssertEqual(kind.markerRGB, CameraType.stationaryCamera.markerRGB, kind.symbolName)
            XCTAssertEqual(hex(kind.tint), hex(Theme.Types.camera), kind.symbolName)
            XCTAssertEqual(CameraMarkerLook.icon(glyph: kind.glyph, tier: .path, daylight: true),
                           CameraMarkerLook.icon(glyph: .camera, tier: .path, daylight: true))
        }
        XCTAssertEqual(CameraType.dpsPost.glyph, .post)
        XCTAssertEqual(CameraType.accident.glyph, .accident)
        XCTAssertEqual(CameraType.other("x").glyph, .other)
        // Тип остаётся словом: значок один, названия — разные.
        XCTAssertEqual(Set(cameras.map(\.displayName)).count, cameras.count)
    }

    func testEveryGlyphStaysOnItsGrid() {
        let half = CameraGlyph.lineWidth / 2
        for glyph in CameraGlyph.allCases {
            let box = glyph.parts.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
            XCTAssertGreaterThanOrEqual(box.minX - half, 0, "\(glyph) слева")
            XCTAssertGreaterThanOrEqual(box.minY - half, 0, "\(glyph) сверху")
            XCTAssertLessThanOrEqual(box.maxX + half, CameraGlyph.grid, "\(glyph) справа")
            XCTAssertLessThanOrEqual(box.maxY + half, CameraGlyph.grid, "\(glyph) снизу")
            // Глиф занимает сетку, а не точку в углу: одна оптическая величина.
            XCTAssertGreaterThan(max(box.width, box.height), CameraGlyph.grid * 0.6, "\(glyph) мелкий")
        }
    }

    /// На 24 pt контур 2,2 давал 1,3 pt — терялся боковым зрением и на тёмном
    /// асфальте поездки. Пол — 1,5 pt; крупный значок держит линию стиля.
    func testLineIsNeverThinnerThanTheFloor() {
        for side in stride(from: 8.0, through: 90.0, by: 1.0) {
            let grid = CameraGlyph.gridLineWidth(side: side)
            XCTAssertGreaterThanOrEqual(grid, CameraGlyph.lineWidth)
            XCTAssertGreaterThanOrEqual(grid * side / CameraGlyph.grid, CameraGlyph.minLinePoints - 1e-9, "\(side) pt")
        }
        // Значок «на пути» на карте (30 pt, глиф 18 pt) — линия стиля, не утолщённая.
        XCTAssertEqual(CameraGlyph.gridLineWidth(side: 30 * CameraCoin.glyphShare), CameraGlyph.lineWidth, accuracy: 0.001)
    }

    func testInkIsReadableOnItsFill() {
        for glyph in CameraGlyph.allCases {
            XCTAssertGreaterThanOrEqual(contrast(glyph.inkRGB, glyph.fillRGB), 4.5, "\(glyph)")
        }
    }

    /// Цвет типа — одно число на SwiftUI, стиль движка и виджеты/часы.
    func testTypeColourIsOneSource() {
        for kind in kinds {
            XCTAssertEqual(kind.markerRGB, kind.glyph.fillRGB)
            XCTAssertEqual(EngineMapStyle.typeHex(kind), String(format: "#%06X", kind.glyph.fillRGB))
            XCTAssertEqual(WidgetPalette.cameraFill(symbol: kind.symbolName), kind.glyph.fillRGB)
            XCTAssertEqual(WidgetPalette.cameraGlyph(symbol: kind.symbolName), kind.glyph.inkRGB)
            XCTAssertEqual(hex(kind.tint), kind.glyph.fillRGB, "\(kind.symbolName): Theme разошёлся с глифом")
        }
    }

    /// Глиф нарисован (не пустой круг) и не выходит за круг.
    func testGlyphIsDrawnInsideTheCoin() throws {
        for glyph in CameraGlyph.allCases {
            let mask = try inkMask(glyph, side: 24)
            XCTAssertGreaterThan(mask.ink, mask.total / 20, "\(glyph): глифа почти нет")
            XCTAssertEqual(mask.outside, 0, "\(glyph): глиф за кругом")
        }
    }

    /// Камера, пост ДПС, ДТП и «прочее» различимы СИЛУЭТОМ на мелком значке:
    /// на графитовой спокойной камере цвета нет, а камера и ДТП оба красные.
    func testGlyphsAreDistinguishableBySilhouette() throws {
        let glyphs = CameraGlyph.allCases
        let masks = try glyphs.map { try inkMask($0, side: 24).bits }
        for i in masks.indices {
            for j in masks.indices where j > i {
                let both = zip(masks[i], masks[j]).filter { $0 && $1 }.count
                let any = zip(masks[i], masks[j]).filter { $0 || $1 }.count
                let distance = 1 - Double(both) / Double(max(any, 1))
                XCTAssertGreaterThan(distance, 0.35, "\(glyphs[i]) и \(glyphs[j]) — одно пятно")
            }
        }
    }

    // MARK: - Помощники

    /// Пиксели глифа (красный на чёрном) стороной `side` в @3x.
    private func inkMask(_ glyph: CameraGlyph, side: CGFloat) throws -> (bits: [Bool], ink: Int, total: Int, outside: Int) {
        let image = CameraIconArt.image(glyph, side: side, fill: 0x000000, ink: 0xFF0000, rim: 0x000000,
                                        shadow: false, scale: 3)
        let cg = try XCTUnwrap(image.cgImage)
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bits = [Bool](repeating: false, count: w * h)
        var ink = 0, outside = 0
        let r = Double(w) / 2
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let red = Int(data[i])
                if red > 128 {
                    bits[y * w + x] = true
                    ink += 1
                    let dx = Double(x) + 0.5 - r, dy = Double(y) + 0.5 - r
                    if dx * dx + dy * dy > r * r { outside += 1 }
                }
            }
        }
        return (bits, ink, w * h, outside)
    }

    private func luminance(_ hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func hex(_ colour: Color) -> UInt32 {
        let ui = UIColor(colour).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
    }
}
