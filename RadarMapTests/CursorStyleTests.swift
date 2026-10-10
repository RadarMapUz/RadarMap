//
//  CursorStyleTests.swift
//  RadarMapTests
//
//  Значок «я» на карте: хранение выбора, поворот на карте Apple и сами
//  картинки.
//
//  Картинки проверяются по пикселям, а не по коду — по той же причине, что и
//  схема (RoadSketchPixelTests): значок «собирается и не падает» при любой
//  ошибке в геометрии, а видно её только на экране. Здесь — три вещи, которые
//  обязаны быть верны при любой перерисовке: значок вообще нарисован, он
//  отличается от соседей, и он СИММЕТРИЧЕН — кривая половина силуэта даёт
//  машину, которая едет боком.
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
        // Значок из будущей версии, ручная правка, пустота — курсор обязан
        // нарисоваться всё равно, и нарисоваться прежним.
        XCTAssertEqual(CursorStyle(stored: nil), .arrow)
        XCTAssertEqual(CursorStyle(stored: ""), .arrow)
        XCTAssertEqual(CursorStyle(stored: "moto"), .arrow)
        XCTAssertEqual(CursorStyle(stored: "Car"), .arrow)
    }

    func testEveryStyleHasItsOwnTitle() {
        let titles = CursorStyle.allCases.map(\.title)
        XCTAssertFalse(titles.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        XCTAssertEqual(Set(titles).count, titles.count, "две плитки с одной подписью: \(titles)")
    }

    // MARK: - Картинки

    /// Значок в той же рамке, в какой его запекает движок карты.
    private func pixels(_ style: CursorStyle?) throws -> Bitmap {
        let cursor = style.map { MeCursor(scale: 1, style: $0) } ?? MeCursor(scale: 1)
        let renderer = ImageRenderer(content: cursor.frame(width: 30, height: 36).padding(8))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage?.cgImage)
        return Bitmap(image)
    }

    func testEveryStyleDrawsSomething() throws {
        for style in CursorStyle.allCases {
            let bitmap = try pixels(style)
            // Четверть рамки и больше непрозрачна: значок, а не соринка.
            let opaque = bitmap.alpha.filter { $0 > 200 }.count
            let frame = 30 * 36 * 4   // рамка значка в пикселях при ×2
            XCTAssertGreaterThan(opaque, frame / 4,
                                 "\(style.rawValue): нарисовано слишком мало (\(opaque) пикс.)")
        }
    }

    func testDefaultCursorIsTheArrow() throws {
        // Все вызовы, которые о выборе не знают, рисуют ровно прежнюю стрелку.
        XCTAssertEqual(try pixels(nil).rgba, try pixels(.arrow).rgba)
    }

    func testStylesLookDifferent() throws {
        let images = try CursorStyle.allCases.map { try pixels($0).alpha }
        for i in images.indices {
            for j in images.indices where j > i {
                let differing = zip(images[i], images[j]).filter { abs(Int($0) - Int($1)) > 64 }.count
                XCTAssertGreaterThan(differing, 200,
                                     "\(CursorStyle.allCases[i]) и \(CursorStyle.allCases[j]) неразличимы")
            }
        }
    }

    func testSilhouettesAreSymmetric() throws {
        // Форма (альфа) обязана быть зеркальной: свет падает слева и красит
        // половины по-разному, но контур у машины один с обеих сторон.
        for style in CursorStyle.allCases {
            let bitmap = try pixels(style)
            let alpha = bitmap.alpha   // вычисляемое свойство — один раз, не на пиксель
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
