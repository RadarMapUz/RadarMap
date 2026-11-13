//
//  CameraMarkerArt.swift
//  RadarMap
//
//  Рисование значка камеры на карте — вариант C «Точка» (владелец, 13.11,
//  задача 90; облик и правила — CameraMarkerLook). CoreGraphics в системе
//  координат UIKit (y вниз), как у CameraCoin: точка, булавка, ромб,
//  треугольник. Растр для движка — CameraIconArt.marker.
//

import CoreGraphics


nonisolated enum CameraMarkerArt {

    typealias Raster = CameraMarkerLook.Raster

    /// Поле под тень вокруг фигуры (pt).
    static let shadowPad: CGFloat = CameraCoin.shadowPad

    static func rimWidth(_ look: Raster) -> CGFloat {
        switch look.shape {
        case .dot:      return 1.6
        case .pin:      return max(2, look.side * 0.08)
        case .diamond:  return max(1.6, look.side * 0.06)
        case .triangle: return max(2, look.side * 0.08)
        }
    }

    /// Холст значка (pt), в целых точках: рендерер растра округляет размер до
    /// пикселя, и дробный холст сдвинул бы остриё булавки с нижнего края.
    /// Булавка: остриё — на нижнем крае (якорь bottom); остальные — центр
    /// фигуры в центре холста (якорь center).
    static func canvas(_ look: Raster) -> CGSize {
        let side = CGFloat(look.side), rim = rimWidth(look)
        let size: CGSize
        switch look.shape {
        case .dot:
            size = CGSize(width: side + 2 * shadowPad, height: side + 2 * shadowPad)
        case .pin:
            let width = side + 2 * (rim + shadowPad)
            size = CGSize(width: width, height: rim + shadowPad + side * (1 + CGFloat(CameraMarkerLook.pinTipShare)) + rim)
        case .diamond:
            let full = side * 1.2 + 2 * (rim + 1 + shadowPad)
            size = CGSize(width: full, height: full)
        case .triangle:
            let full = side * 1.12 + 2 * (rim + shadowPad)
            size = CGSize(width: full, height: full)
        }
        return CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }

    /// Значок на холсте `canvas(look)` с началом в (0, 0).
    static func draw(_ glyph: CameraGlyph, look: Raster, in cg: CGContext) {
        let size = canvas(look)
        let side = CGFloat(look.side), rim = rimWidth(look)
        switch look.shape {
        case .dot:
            let disc = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: CGColor(gray: 0, alpha: 0.3))
            cg.setFillColor(color(look.rim))
            cg.fillEllipse(in: disc)
            cg.restoreGState()
            cg.setFillColor(color(look.fill))
            cg.fillEllipse(in: disc.insetBy(dx: rim, dy: rim))
        case .pin:
            // Голова — по центру, остриё (с кантом) — ровно на нижнем крае.
            let head = CGRect(x: (size.width - side) / 2,
                              y: size.height - rim - side * (1 + CGFloat(CameraMarkerLook.pinTipShare)),
                              width: side, height: side)
            filled(pin(head: head), fill: look.fill, rim: look.rim, rimWidth: rim, in: cg)
            let share: CGFloat = 0.62
            let s = side * share
            glyph.draw(in: cg, rect: CGRect(x: head.midX - s / 2, y: head.midY - s / 2, width: s, height: s),
                       ink: color(look.ink))
        case .diamond:
            let rect = CGRect(x: size.width / 2 - side / 2, y: size.height / 2 - side / 2, width: side, height: side)
            let shape = diamond(in: rect.insetBy(dx: -side * 0.1, dy: -side * 0.1), radius: side * 0.14)
            if look.dashed {
                dashed(shape, fill: look.fill, rim: look.rim, rimWidth: max(1.8, side * 0.07), side: side, in: cg)
            } else {
                filled(shape, fill: look.fill, rim: look.rim, rimWidth: rim, outer: look.outer, in: cg)
            }
            let inner = rect.insetBy(dx: side * 0.14, dy: side * 0.14)
            glyph.draw(in: cg, rect: inner, ink: color(look.ink))
        case .triangle:
            let rect = CGRect(x: size.width / 2 - side / 2, y: size.height / 2 - side / 2, width: side, height: side)
            filled(triangle(in: rect.insetBy(dx: -side * 0.06, dy: -side * 0.06), radius: side * 0.12),
                   fill: look.fill, rim: look.rim, rimWidth: rim, in: cg)
            exclamation(in: triangleGlyphRect(rect), ink: look.ink, cg: cg)
        }
    }

    // MARK: - Формы

    static func color(_ rgb: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    /// Заливка с кантом снаружи (как у «Монеты») и мягкой тенью под основой.
    private static func filled(_ shape: CGPath, fill: UInt32, rim: UInt32, rimWidth: CGFloat,
                               outer: UInt32? = nil, in cg: CGContext) {
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(gray: 0, alpha: 0.3))
        cg.addPath(shape)
        cg.setFillColor(color(outer ?? rim))
        cg.fillPath()
        cg.restoreGState()
        cg.setLineJoin(.round)
        if let outer {
            cg.addPath(shape)
            cg.setStrokeColor(color(outer))
            cg.setLineWidth(rimWidth * 2 + 2)
            cg.strokePath()
        }
        cg.addPath(shape)
        cg.setStrokeColor(color(rim))
        cg.setLineWidth(rimWidth * 2)
        cg.strokePath()
        cg.addPath(shape)
        cg.setFillColor(color(fill))
        cg.fillPath()
    }

    /// Неподтверждённая отметка: пунктир канта.
    private static func dashed(_ shape: CGPath, fill: UInt32, rim: UInt32, rimWidth: CGFloat,
                               side: CGFloat, in cg: CGContext) {
        cg.addPath(shape)
        cg.setFillColor(color(fill))
        cg.fillPath()
        cg.saveGState()
        cg.addPath(shape)
        cg.setStrokeColor(color(rim))
        cg.setLineWidth(rimWidth)
        cg.setLineJoin(.round)
        cg.setLineDash(phase: 0, lengths: [side * 0.14, side * 0.09])
        cg.strokePath()
        cg.restoreGState()
    }

    /// Булавка: круглая голова `head`, остриё ниже головы на `pinTipShare` стороны.
    static func pin(head: CGRect) -> CGPath {
        let r = head.width / 2
        let center = CGPoint(x: head.midX, y: head.midY)
        let tip = CGPoint(x: head.midX, y: head.maxY + head.width * CGFloat(CameraMarkerLook.pinTipShare))
        let spread: CGFloat = 0.62
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: center.x - r * sin(spread), y: center.y + r * cos(spread)))
        path.addArc(center: center, radius: r, startAngle: .pi / 2 + spread, endAngle: .pi / 2 - spread, clockwise: false)
        path.closeSubpath()
        return path
    }

    /// Треугольник вершиной вверх, вписанный в `rect`, со скруглёнными углами.
    static func triangle(in rect: CGRect, radius: CGFloat) -> CGPath {
        let h = rect.width * 0.9
        let top = rect.midY - h * 0.55
        return rounded([CGPoint(x: rect.midX, y: top), CGPoint(x: rect.maxX, y: top + h),
                        CGPoint(x: rect.minX, y: top + h)], radius: radius)
    }

    /// Где знак в треугольнике: ниже центра, где он шире.
    static func triangleGlyphRect(_ rect: CGRect) -> CGRect {
        let s = rect.width * 0.5
        return CGRect(x: rect.midX - s / 2, y: rect.midY - s * 0.32, width: s, height: s)
    }

    static func diamond(in rect: CGRect, radius: CGFloat) -> CGPath {
        rounded([CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
                 CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)], radius: radius)
    }

    private static func rounded(_ points: [CGPoint], radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let n = points.count
        path.move(to: CGPoint(x: (points[0].x + points[n - 1].x) / 2, y: (points[0].y + points[n - 1].y) / 2))
        for i in 0..<n {
            path.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % n], radius: radius)
        }
        path.closeSubpath()
        return path
    }

    private static func exclamation(in rect: CGRect, ink: UInt32, cg: CGContext) {
        let s = rect.width
        cg.saveGState()
        cg.setStrokeColor(color(ink))
        cg.setFillColor(color(ink))
        cg.setLineCap(.round)
        cg.setLineWidth(max(2.2, s * 0.12))
        cg.move(to: CGPoint(x: rect.midX, y: rect.midY - s * 0.24))
        cg.addLine(to: CGPoint(x: rect.midX, y: rect.midY + s * 0.06))
        cg.strokePath()
        let r = max(1.4, s * 0.07)
        cg.fillEllipse(in: CGRect(x: rect.midX - r, y: rect.midY + s * 0.24 - r, width: 2 * r, height: 2 * r))
        cg.restoreGState()
    }
}
