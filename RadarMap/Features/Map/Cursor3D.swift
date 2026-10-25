//
//  Cursor3D.swift
//  RadarMap
//
//  Значок «Машина 3D» (29.B): кадр объёмной модели Car3DModel под заданным
//  поворотом и наклоном. Один рисунок на все кадры — карта на движке берёт
//  из него растры по ракурсу (Car3DSprites), плитка выбора значка и тесты
//  пикселей — кадр «нос вверх, лёгкий наклон».
//
//  Белый кант — обводка всех видимых граней под их заливкой: снаружи
//  силуэта остаётся полоска белого, внутри её закрывают сами грани.
//

import SwiftUI
import UIKit

struct Car3DCursor: View {
    var scale: CGFloat = 1
    /// Поворот машины по часовой от верха кадра, градусы.
    var yaw: Double = 0
    /// Наклон карты, градусы (0 — сверху).
    var pitch: Double = Car3DCursor.previewPitch

    /// Наклон кадра для плитки выбора и картинки до первого кадра карты.
    static let previewPitch = 35.0
    /// Пунктов на метр модели: машина 4,4 м — 38 pt сверху (крупнее плоских:
    /// объём читается только у значка, который больше стрелки).
    static let pointsPerMeter = 8.6

    var body: some View {
        Canvas { context, size in
            let faces = Car3DModel.project(yaw: yaw, pitch: pitch, scale: Self.pointsPerMeter * scale)
            context.translateBy(x: size.width / 2, y: size.height / 2)
            // Тень — пятно плана машины на земле, без сдвига: она вертится
            // вместе с картой, а свет — с экраном.
            var shadow = context
            shadow.addFilter(.blur(radius: 2.6 * scale))
            let squash = cos(min(max(0, pitch), 85) * .pi / 180)
            let longSide = Car3DModel.length * Self.pointsPerMeter * scale * 0.96
            let shortSide = Car3DModel.width * Self.pointsPerMeter * scale * 1.1
            let yawRad = yaw * .pi / 180
            // Габарит плана под поворотом, сплющенный по вертикали наклоном.
            let spanX = abs(sin(yawRad)) * longSide + abs(cos(yawRad)) * shortSide
            let spanY = (abs(cos(yawRad)) * longSide + abs(sin(yawRad)) * shortSide) * squash
            shadow.fill(Path(ellipseIn: CGRect(x: -spanX / 2, y: -spanY / 2, width: spanX, height: spanY)),
                        with: .color(.black.opacity(0.34)))
            let paths = faces.map { face -> Path in
                var path = Path()
                path.addLines(face.points)
                path.closeSubpath()
                return path
            }
            for path in paths {
                context.stroke(path, with: .color(.white),
                               style: StrokeStyle(lineWidth: 2.4 * scale, lineCap: .round, lineJoin: .round))
            }
            for (face, path) in zip(faces, paths) {
                let base = face.part.rgb
                let k = face.light
                context.fill(path, with: .color(Color(red: min(1, base.r * k), green: min(1, base.g * k),
                                                      blue: min(1, base.b * k))))
                // Тонкая тёмная кромка между гранями — объём без лишних деталей.
                context.stroke(path, with: .color(.black.opacity(0.18)), lineWidth: 0.4 * scale)
            }
        }
    }
}

/// Растры кадров для карты на движке: по ракурсу, лениво, раз на процесс.
/// Та же рамка и тот же ×3, что у остальных значков (EngineMapView.cursorImage).
@MainActor
enum Car3DSprites {
    private static var cache: [Car3DModel.Frame: UIImage] = [:]

    static func image(_ frame: Car3DModel.Frame) -> UIImage? {
        if let hit = cache[frame] { return hit }
        let size = CursorStyle.car3D.frameSize
        let renderer = ImageRenderer(content: Car3DCursor(yaw: Double(frame.yaw) * Car3DModel.yawStep,
                                                          pitch: Car3DModel.pitches[frame.pitch])
            .frame(width: size.width, height: size.height).padding(8))
        renderer.scale = 3
        let image = renderer.uiImage
        cache[frame] = image
        return image
    }
}
