//
//  CursorStyleTests.swift
//  RadarMapTests
//
//  Значок «я» на карте: хранение выбора, перевод старых значков и сами
//  картинки. Картинки проверяются по пикселям: ассет «есть и грузится» при
//  любой ошибке рендера, а кривой силуэт, красная деталь или две одинаковые
//  машины видны только в пикселях.
//

import SwiftUI
import UIKit
import XCTest
@testable import RadarMap

@MainActor
final class CursorStyleTests: XCTestCase {

    // MARK: - Хранение

    func testStoredValueRoundTrips() {
        for style in CursorStyle.allCases {
            XCTAssertEqual(CursorStyle(stored: style.rawValue), style)
        }
    }

    func testUnknownStoredValueFallsBackToArrow() {
        XCTAssertEqual(CursorStyle(stored: nil), .arrow)
        XCTAssertEqual(CursorStyle(stored: ""), .arrow)
        XCTAssertEqual(CursorStyle(stored: "boat"), .arrow)
        XCTAssertEqual(CursorStyle(stored: "Car"), .arrow)
    }

    func testOldStylesMoveToTheNearestNewOne() {
        // Выбор водителя не сбрасывается из-за того, что старый рисунок убран.
        XCTAssertEqual(CursorStyle(stored: "car"), .crossover)
        XCTAssertEqual(CursorStyle(stored: "car3D"), .crossover)
        XCTAssertEqual(CursorStyle(stored: "sport"), .sport)
        XCTAssertEqual(CursorStyle(stored: "formula"), .sport)
        XCTAssertEqual(CursorStyle(stored: "supercar"), .sport)
        XCTAssertEqual(CursorStyle(stored: "rally"), .sport)
        XCTAssertEqual(CursorStyle(stored: "spaceship"), .arrow)
        // Ни одно старое имя не совпадает с новым случаем, кроме спорткара.
        for (old, _) in CursorStyle.legacy {
            XCTAssertNil(CursorStyle(rawValue: old), old)
        }
    }

    func testSettingsRewriteOldStyleOnce() {
        let defaults = UserDefaults.standard, key = "cursorStyle"
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.set("formula", forKey: key)
        XCTAssertEqual(AppSettings().cursorStyle, .sport)
        XCTAssertEqual(defaults.string(forKey: key), "sport")
        // Неизвестное имя не трогаем: оно может быть из более новой версии.
        defaults.set("hovercraft", forKey: key)
        XCTAssertEqual(AppSettings().cursorStyle, .arrow)
        XCTAssertEqual(defaults.string(forKey: key), "hovercraft")
    }

    func testEveryStyleHasItsOwnTitle() {
        let titles = CursorStyle.allCases.map(\.title)
        XCTAssertFalse(titles.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        XCTAssertEqual(Set(titles).count, titles.count, "две плитки с одной подписью: \(titles)")
    }

    // MARK: - Картинки

    /// Картинки машин из каталога, @3x: 44×60 pt — рамка плюс поля под тень.
    private func assets() throws -> [(CursorStyle, Bitmap)] {
        try CursorStyle.allCases.compactMap { style in
            guard let name = style.assetName else { return nil }
            let image = try XCTUnwrap(UIImage(named: name, in: .main, compatibleWith: UITraitCollection(displayScale: 3)),
                                      "\(name): нет картинки в каталоге")
            let pad = CursorStyle.padding * 2
            XCTAssertEqual(image.size, CGSize(width: style.frameSize.width + pad, height: style.frameSize.height + pad), name)
            return (style, Bitmap(try XCTUnwrap(image.cgImage)))
        }
    }

    func testEveryVehicleHasAnAsset() throws {
        XCTAssertEqual(try assets().count, CursorStyle.allCases.count - 1)
        XCTAssertNil(CursorStyle.arrow.assetName)
    }

    func testEveryVehicleDrawsSomething() throws {
        for (style, bitmap) in try assets() {
            // Узкий мотоцикл — ~12 % холста, машины — 25–35 %; соринка — меньше.
            let opaque = bitmap.alpha.filter { $0 > 200 }.count
            XCTAssertGreaterThan(opaque, bitmap.width * bitmap.height * 8 / 100,
                                 "\(style.rawValue): нарисовано слишком мало (\(opaque) пикс.)")
        }
    }

    func testVehiclesLookDifferent() throws {
        let all = try assets()
        for i in all.indices {
            for j in all.indices where j > i {
                let a = all[i].1.rgba, b = all[j].1.rgba
                var differing = 0
                for p in stride(from: 0, to: min(a.count, b.count), by: 4) {
                    let d = abs(Int(a[p]) - Int(b[p])) + abs(Int(a[p + 1]) - Int(b[p + 1])) + abs(Int(a[p + 2]) - Int(b[p + 2]))
                    if d > 96 { differing += 1 }
                }
                XCTAssertGreaterThan(differing, 500, "\(all[i].0) и \(all[j].0) неразличимы")
            }
        }
    }

    func testSilhouettesAreSymmetric() throws {
        // Свет слева красит половины по-разному, но контур у машины один с
        // обеих сторон: кривой силуэт — машина, которая едет боком.
        for (style, bitmap) in try assets() {
            let alpha = bitmap.alpha
            var worst = 0
            for y in 0..<bitmap.height {
                for x in 0..<(bitmap.width / 2) {
                    let left = Int(alpha[y * bitmap.width + x])
                    let right = Int(alpha[y * bitmap.width + (bitmap.width - 1 - x)])
                    worst = max(worst, abs(left - right))
                }
            }
            XCTAssertLessThanOrEqual(worst, 24, "\(style.rawValue): силуэт кривой (\(worst))")
        }
    }

    func testNoVehicleIsCameraRed() throws {
        // Красный на карте — камера. Стоп-сигналы тёмно-бордовые и мелкие.
        for (style, bitmap) in try assets() {
            var red = 0
            for p in stride(from: 0, to: bitmap.rgba.count, by: 4) where bitmap.rgba[p + 3] > 128 {
                let color = UIColor(red: CGFloat(bitmap.rgba[p]) / 255, green: CGFloat(bitmap.rgba[p + 1]) / 255,
                                    blue: CGFloat(bitmap.rgba[p + 2]) / 255, alpha: 1)
                var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
                color.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
                if (h < 0.04 || h > 0.95) && s > 0.6 && v > 0.55 { red += 1 }
            }
            XCTAssertLessThanOrEqual(red, 4, "\(style.rawValue): красные пиксели (\(red))")
        }
    }

    /// Значок в той же рамке, в какой его запекает движок карты.
    private func rendered(_ style: CursorStyle?) throws -> Bitmap {
        let cursor = style.map { MeCursor(scale: 1, style: $0) } ?? MeCursor(scale: 1)
        let frame = (style ?? .arrow).frameSize
        let renderer = ImageRenderer(content: cursor.frame(width: frame.width, height: frame.height).padding(CursorStyle.padding))
        renderer.scale = 2
        return Bitmap(try XCTUnwrap(renderer.uiImage?.cgImage))
    }

    func testDefaultCursorIsTheArrow() throws {
        XCTAssertEqual(try rendered(nil).rgba, try rendered(.arrow).rgba)
    }

    func testArrowIsDrawnAndSymmetric() throws {
        let bitmap = try rendered(.arrow)
        XCTAssertGreaterThan(bitmap.alpha.filter { $0 > 200 }.count, 30 * 36 * 4 / 4)
        let alpha = bitmap.alpha
        var worst = 0
        for y in 0..<bitmap.height {
            for x in 0..<(bitmap.width / 2) {
                worst = max(worst, abs(Int(alpha[y * bitmap.width + x]) - Int(alpha[y * bitmap.width + bitmap.width - 1 - x])))
            }
        }
        XCTAssertLessThanOrEqual(worst, 24)
    }

    func testPickerTileShowsTheAsset() throws {
        // Плитка выбора рисует ту же картинку, что поедет по карте: MeCursor
        // в рамке движка даёт холст 44×60 pt с машиной внутри.
        let bitmap = try rendered(.taxi)
        XCTAssertEqual(bitmap.width, 88)
        XCTAssertEqual(bitmap.height, 120)
        XCTAssertGreaterThan(bitmap.alpha.filter { $0 > 200 }.count, 88 * 120 / 5)
    }
}

/// Пиксели картинки RGBA8. Буфер выделяется явно и живёт дольше контекста —
/// тот же приём, что в RoadSketchPixelTests: массив Swift, отданный в
/// CGContext через inout, роняет процесс.
private struct Bitmap {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    var alpha: [UInt8] { stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] } }

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        let count = width * height * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
        defer { buffer.deallocate() }
        if let context = CGContext(data: buffer, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: width * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        rgba = Array(UnsafeBufferPointer(start: buffer, count: count))
    }
}
