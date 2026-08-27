//
//  GlyphLookTests.swift
//  RadarMapTests
//
//  Как выглядят пиктограммы схемы.
//
//  Смотреть на них надо ГЛАЗАМИ, а не по коду: значок живёт на восьми
//  пунктах, и то, что в исходнике выглядит подробным, на экране бывает серым
//  пятном. Этот класс рендерит их в файл, чтобы на них можно было взглянуть,
//  и заодно сторожит два числа, которые ломаются молча.
//

import SwiftUI
import UIKit
import XCTest
@testable import RadarMap

@MainActor
final class GlyphLookTests: XCTestCase {

    private func render<V: View>(_ view: V, scale: CGFloat) throws -> UIImage {
        let renderer = ImageRenderer(content: view.padding(6 * scale)
            .background(SketchPalette.ground))
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage)
    }

    /// Размер САМОГО значка, без полей вокруг: поля одинаковые со всех сторон
    /// и делают любую пропорцию ближе к квадрату.
    private func bare<V: View>(_ view: V) throws -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage).size
    }

    func testGlyphSheetForTheEye() throws {
        // Лист со всеми значками: в рабочем размере и крупно. Крупный — чтобы
        // видеть, что нарисовано; мелкий — чтобы видеть, что от этого доживает
        // до экрана.
        let sheet = VStack(spacing: 14) {
            HStack(spacing: 14) {
                TrafficLightGlyph(scale: 2)
                SpeedBumpGlyph(scale: 2)
                StopLineGlyph(scale: 2)
                UTurnGlyph(scale: 2)
                CameraDotGlyph(scale: 2, isAlert: true)
                CameraDotGlyph(scale: 2, isAlert: false)
            }
            HStack(spacing: 26) {
                TrafficLightGlyph(scale: 9)
                SpeedBumpGlyph(scale: 9)
                UTurnGlyph(scale: 9)
                CameraDotGlyph(scale: 9, isAlert: true)
            }
        }
        let image = try render(sheet, scale: 9)
        if let png = image.pngData() {
            let out = URL(fileURLWithPath: "/tmp/glyphs.png")
            try? png.write(to: out)
            print("лист значков:", out.path)
        }
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testTrafficLightIsTallerThanItIsWide() throws {
        // Вертикальный корпус — то, по чему светофор опознаётся формой за долю
        // секунды. Стань он квадратным, и от лежачего его будет не отличить.
        let size = try bare(TrafficLightGlyph(scale: 4))
        XCTAssertGreaterThan(size.height, size.width * 1.6,
                             "корпус стал квадратным: \(size)")
    }

    func testCameraAlertIsBiggerThanTheRest() throws {
        // Десяток одинаковых точек по краям читается сыпью, а не картой.
        let alert = try bare(CameraDotGlyph(scale: 4, isAlert: true))
        let plain = try bare(CameraDotGlyph(scale: 4, isAlert: false))
        XCTAssertGreaterThan(alert.width, plain.width)
    }
}
