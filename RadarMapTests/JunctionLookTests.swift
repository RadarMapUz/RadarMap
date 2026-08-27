//
//  JunctionLookTests.swift
//  RadarMapTests
//
//  Перекрёсток должен читаться ЦЕЛЬНЫМ.
//
//  Ways режутся на перекрёстках, и каждый кусок кончается своим срезанным
//  концом. Заглушка узла закрывает стык диском самой широкой из встретившихся
//  дорог — но только её шириной: там, где проспект встречает узкую улицу,
//  между ними оставался тёмный клин.
//
//  Меряется не «красиво», а конкретное: земли внутри перекрёстка быть не
//  должно.
//

import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import RadarMap

@MainActor
final class JunctionLookTests: XCTestCase {

    private let side: CGFloat = 420

    /// ОДНА на весь класс: освобождение @MainActor-класса посреди теста роняет
    /// хост, и прогон отчитывается «Executed 0 tests» вместо падения.
    private static let state = SketchState()

    /// Доля пикселей цвета земли в квадрате вокруг центра перекрёстка.
    private func groundShare(in box: CGFloat) throws -> Double {
        var scene = RoadSketch.Scene()
        scene.spanBucket = 160
        scene.spanAtBuild = 160
        // Проспект с запада на восток и узкая улица с юга — тот самый случай,
        // где заглушка шириной проспекта клин не закрывает.
        // Узел ОТОДВИНУТ от машины: курсор «я» стоит в центре вида и его
        // тёмный ореол считался бы землёй — мерили бы курсор, а не перекрёсток.
        let node: CGFloat = 60
        scene.network = [
            RoadSketch.Line(points: [CGPoint(x: -400, y: node), CGPoint(x: 0, y: node)],
                            kind: .primary, level: 0, isOneWay: false,
                            isDetailed: true, lanes: 6),
            RoadSketch.Line(points: [CGPoint(x: 0, y: node), CGPoint(x: 400, y: node)],
                            kind: .primary, level: 0, isOneWay: false,
                            isDetailed: true, lanes: 6),
            RoadSketch.Line(points: [CGPoint(x: 0, y: node), CGPoint(x: 0, y: node + 400)],
                            kind: .residential, level: 0, isOneWay: false,
                            isDetailed: true, lanes: 2),
        ]

        let view = RoadSketchView(scene: scene, state: Self.state)
            .frame(width: side, height: side)
            .background(SketchPalette.ground)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage)
        let cgImage = try XCTUnwrap(image.cgImage)

        let width = cgImage.width, height = cgImage.height
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        buffer.initialize(repeating: 0, count: width * height * 4)
        defer { buffer.deallocate() }
        let context = try XCTUnwrap(CGContext(
            data: buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Перекрёсток ищем ПО КАРТИНКЕ, а не берём центр вида: схема сдвигает
        // мир так, чтобы водитель сидел ниже и больше дороги было видно
        // впереди, и опора сцены на центр экрана не попадает.
        //
        // Проспект идёт поперёк — это строка с наибольшим числом пикселей
        // асфальта; улица идёт вдоль — такой же столбец. Их пересечение и
        // есть узел.
        func light(_ x: Int, _ y: Int) -> Double {
            let i = (y * width + x) * 4
            return (Double(buffer[i]) * 0.299 + Double(buffer[i + 1]) * 0.587
                    + Double(buffer[i + 2]) * 0.114) / 255
        }
        var bestRow = (y: height / 2, count: -1)
        for y in 0..<height {
            let count = (0..<width).reduce(0) { $0 + (light($1, y) > 0.12 ? 1 : 0) }
            if count > bestRow.count { bestRow = (y, count) }
        }
        var bestColumn = (x: width / 2, count: -1)
        for x in 0..<width {
            let count = (0..<height).reduce(0) { $0 + (light(x, $1) > 0.12 ? 1 : 0) }
            if count > bestColumn.count { bestColumn = (x, count) }
        }
        let half = Int(box / 2)
        let cx = bestColumn.x, cy = bestRow.y
        // Цвет земли берём из УГЛА той же картинки: там заведомо нет ни
        // дороги, ни каймы, а значение зависит от палитры и от того, как
        // ImageRenderer положил цвет в буфер.
        let corner = (width / 40) * 4 + (height / 40) * width * 4
        let ground = (r: Double(buffer[corner]), g: Double(buffer[corner + 1]),
                      b: Double(buffer[corner + 2]))
        var dark = 0, total = 0
        for y in (cy - half)..<(cy + half) {
            for x in (cx - half)..<(cx + half) {
                let i = (y * width + x) * 4
                total += 1
                // Сравниваем с ЦВЕТОМ ЗЕМЛИ, а не с яркостью. «Тёмное» — это
                // ещё и кайма дороги, которая темнее земли: по яркости тест
                // мерил бы кайму и называл её дырой.
                if abs(Double(buffer[i]) - ground.r) < 6,
                   abs(Double(buffer[i + 1]) - ground.g) < 6,
                   abs(Double(buffer[i + 2]) - ground.b) < 6 {
                    dark += 1
                }
            }
        }
        if let png = image.pngData() {
            let out = URL(fileURLWithPath: "/tmp/junction.png")
            try? png.write(to: out)
            print("снимок перекрёстка:", out.path, "· узел", cx, cy)
        }
        return Double(dark) / Double(max(total, 1))
    }

    func testNoGroundShowsThroughTheJunction() throws {
        // Дыра земли посреди перекрёстка читается как разрыв дороги — то есть
        // как ошибка карты ровно там, где водитель принимает решение.
        let share = try groundShare(in: 26)
        XCTAssertLessThan(share, 0.02,
                          "земля просвечивает в перекрёстке: \(share)")
    }
}
