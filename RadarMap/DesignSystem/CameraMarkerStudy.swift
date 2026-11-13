//
//  CameraMarkerStudy.swift
//  RadarMap
//
//  Задача 90: три варианта значков камер на выбор владельцу (13.11: «все
//  радары одинаковые, только трёхногу по-другому нужно отмечать»). Прототип,
//  в облик карты не встроен: выбранный вариант переезжает в CameraGlyph /
//  CameraMarkerLook как есть — рисование то же, CoreGraphics в системе
//  координат UIKit (y вниз), что у CameraCoin, и растр для движка делает
//  тот же UIGraphicsImageRenderer.
//
//  Во всех трёх: стационарная камера, радар и интеллектуальная — ОДИН значок;
//  тренога и передвижной радар — другой ФОРМОЙ, не только цветом; красный —
//  только у тревоги.
//    A «Плитка и треугольник» — графитовая плитка камеры, янтарный треугольник отметки водителей;
//    B «Дорожный знак» — белая табличка фотофиксации, треугольник предупреждающего знака;
//    C «Точка» — спокойная камера точкой без глифа, значок — только на пути, отметка водителей — ромб.
//

#if DEBUG
import CoreGraphics
import CoreText
import Foundation

nonisolated enum CameraMarkerStudy {

    enum Variant: String, CaseIterable, Sendable {
        case a, b, c
    }

    /// Что стоит на дороге — для карты, а не для реестра: все стационарные
    /// типы — одна `stationary`.
    enum Kind: String, CaseIterable, Sendable {
        case stationary, tripod, mobile, post, accident
    }

    enum State: String, CaseIterable, Sendable {
        case calm, path, alert
    }

    struct Mark: Sendable {
        var kind: Kind
        var state: State
        var unconfirmed = false
        var own = false
    }

    /// Поле вокруг значка под тень и ореол канта.
    static let pad: CGFloat = 4

    // MARK: - Цвета

    static let graphiteDay: UInt32 = 0x3D4652
    static let graphiteNight: UInt32 = 0xAEB6C2
    static let inkDark: UInt32 = 0x14181D
    static let pathDay: UInt32 = 0x1F252C
    static let red: UInt32 = 0xD93025
    static let signRed: UInt32 = 0xD90D1A
    static let amber: UInt32 = 0xFFB020
    static let slate: UInt32 = 0x46525E
    static let accidentRed: UInt32 = 0xC62828
    static let success: UInt32 = 0x177A41
    static let white: UInt32 = 0xFFFFFF

    static func color(_ rgb: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    // MARK: - Размер

    /// Сторона значка (pt) без поля.
    static func side(_ mark: Mark, _ variant: Variant) -> CGFloat {
        switch (variant, mark.kind) {
        case (.c, .stationary), (.c, .post):
            switch mark.state {
            case .calm:  return 11
            case .path:  return 28
            case .alert: return 36
            }
        case (_, .tripod), (_, .mobile):
            switch mark.state {
            case .calm:  return variant == .c ? 28 : 31
            case .path:  return variant == .c ? 30 : 34
            case .alert: return variant == .c ? 38 : 42
            }
        default:
            switch mark.state {
            case .calm:  return 22
            case .path:  return 28
            case .alert: return 36
            }
        }
    }

    /// Точка якоря внутри значка (доля высоты): булавка C стоит остриём.
    static func anchorsAtBottom(_ mark: Mark, _ variant: Variant) -> Bool {
        variant == .c && mark.state != .calm && (mark.kind == .stationary || mark.kind == .post)
    }

    // MARK: - Значок

    /// Значок с центром `center` (булавка C — остриём в `center`).
    static func draw(_ mark: Mark, variant: Variant, daylight: Bool, in cg: CGContext, at center: CGPoint) {
        let side = side(mark, variant)
        let alpha: CGFloat = mark.unconfirmed ? 0.6 : 1
        cg.saveGState()
        if mark.unconfirmed { cg.setAlpha(alpha) }
        if mark.state == .alert { drawHalo(in: cg, at: center, variant: variant, mark: mark) }
        switch variant {
        case .a: drawA(mark, side: side, daylight: daylight, in: cg, at: center)
        case .b: drawB(mark, side: side, daylight: daylight, in: cg, at: center)
        case .c: drawC(mark, side: side, daylight: daylight, in: cg, at: center)
        }
        cg.restoreGState()
        drawBadges(mark, side: side, variant: variant, in: cg, at: center)
    }

    private static func drawHalo(in cg: CGContext, at center: CGPoint, variant: Variant, mark: Mark) {
        let middle = anchorsAtBottom(mark, variant) ? CGPoint(x: center.x, y: center.y - 26) : center
        cg.setFillColor(color(red, 0.18))
        cg.fillEllipse(in: CGRect(x: middle.x - 30, y: middle.y - 30, width: 60, height: 60))
    }

    // MARK: A «Плитка и треугольник»

    private static func drawA(_ mark: Mark, side: CGFloat, daylight: Bool, in cg: CGContext, at c: CGPoint) {
        let rect = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
        switch mark.kind {
        case .stationary:
            let (fill, ink, rim): (UInt32, UInt32, UInt32) = switch mark.state {
            case .calm:  daylight ? (graphiteDay, white, white) : (graphiteNight, inkDark, inkDark)
            case .path:  daylight ? (pathDay, white, white) : (0x2B323B, white, white)
            case .alert: (red, white, white)
            }
            let shape = CGPath(roundedRect: rect, cornerWidth: side * 0.27, cornerHeight: side * 0.27, transform: nil)
            filled(shape, fill: fill, rim: rim, rimWidth: rimWidth(side, mark.state), in: cg)
            glyph(.camera, in: rect, share: 0.64, ink: ink, cg: cg)
        case .tripod, .mobile:
            let fill = mark.state == .alert ? red : amber
            let ink = mark.state == .alert ? white : 0x1C1C1E
            let shape = triangle(in: rect, radius: side * 0.12)
            if mark.unconfirmed {
                dashed(shape, fill: fill, rim: 0x1C1C1E, rimWidth: max(1.8, side * 0.07), side: side, in: cg)
            } else {
                filled(shape, fill: fill, rim: daylight ? 0x1C1C1E : white, rimWidth: max(1.6, side * 0.06),
                       outer: daylight ? white : nil, in: cg)
            }
            liveGlyph(mark.kind, in: triangleGlyphRect(rect), ink: ink, cg: cg)
        case .post:
            let fill: UInt32 = daylight ? slate : (mark.state == .calm ? graphiteNight : slate)
            let ink: UInt32 = (!daylight && mark.state == .calm) ? inkDark : white
            filled(CGPath(ellipseIn: rect, transform: nil), fill: fill, rim: (!daylight && mark.state == .calm) ? inkDark : white,
                   rimWidth: rimWidth(side, mark.state), in: cg)
            glyph(.post, in: rect, share: 0.62, ink: ink, cg: cg)
        case .accident:
            let shape = diamond(in: rect.insetBy(dx: -side * 0.08, dy: -side * 0.08), radius: side * 0.12)
            filled(shape, fill: accidentRed, rim: white, rimWidth: rimWidth(side, mark.state), in: cg)
            exclamation(in: rect, ink: white, cg: cg)
        }
    }

    // MARK: B «Дорожный знак»

    private static func drawB(_ mark: Mark, side: CGFloat, daylight: Bool, in cg: CGContext, at c: CGPoint) {
        let rect = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
        let plate: UInt32 = daylight ? white : 0xE4E8ED
        switch mark.kind {
        case .stationary:
            let (fill, rim, ink, width): (UInt32, UInt32, UInt32, CGFloat) = switch mark.state {
            case .calm:  daylight ? (plate, 0x5C636D, 0x3D4652, 1.5) : (0xB9C0CA, 0x14181D, 0x14181D, 1.5)
            case .path:  (plate, 0x1C1C1E, 0x1C1C1E, max(2.4, side * 0.09))
            case .alert: (plate, signRed, 0x1C1C1E, side * 0.13)
            }
            let shape = CGPath(roundedRect: rect, cornerWidth: side * 0.16, cornerHeight: side * 0.16, transform: nil)
            framed(shape, fill: fill, rim: rim, rimWidth: width, in: cg)
            glyph(.camera, in: rect, share: mark.state == .alert ? 0.56 : 0.64, ink: ink, cg: cg)
        case .tripod, .mobile:
            let shape = triangle(in: rect, radius: side * 0.1)
            let width = side * (mark.state == .alert ? 0.15 : 0.12)
            if mark.unconfirmed {
                dashed(shape, fill: plate, rim: signRed, rimWidth: width, side: side, in: cg)
            } else {
                framed(shape, fill: plate, rim: signRed, rimWidth: width, in: cg)
            }
            liveGlyph(mark.kind, in: triangleGlyphRect(rect).insetBy(dx: side * 0.02, dy: side * 0.02),
                      ink: 0x1C1C1E, cg: cg)
        case .post:
            let width = mark.state == .calm ? 1.5 : max(2.4, side * 0.09)
            framed(CGPath(ellipseIn: rect, transform: nil), fill: daylight ? plate : 0xB9C0CA,
                   rim: mark.state == .calm && daylight ? 0x5C636D : 0x1C1C1E, rimWidth: width, in: cg)
            glyph(.post, in: rect, share: 0.6, ink: 0x1C1C1E, cg: cg)
        case .accident:
            let shape = diamond(in: rect.insetBy(dx: -side * 0.1, dy: -side * 0.1), radius: side * 0.1)
            framed(shape, fill: amber, rim: 0x1C1C1E, rimWidth: max(1.6, side * 0.07), in: cg)
            exclamation(in: rect, ink: 0x1C1C1E, cg: cg)
        }
    }

    // MARK: C «Точка»

    private static func drawC(_ mark: Mark, side: CGFloat, daylight: Bool, in cg: CGContext, at c: CGPoint) {
        switch mark.kind {
        case .stationary, .post:
            if mark.state == .calm {
                // Своя камера на обзоре — зелёная точка: галочка на точке 11 pt не читается.
                let rect = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
                let fill: UInt32 = mark.own ? success : mark.kind == .post ? (daylight ? slate : 0x8A96A3)
                    : (daylight ? graphiteDay : graphiteNight)
                filled(CGPath(ellipseIn: rect, transform: nil), fill: fill,
                       rim: daylight ? white : inkDark, rimWidth: 1.6, in: cg)
                return
            }
            let fill: UInt32 = mark.state == .alert ? red
                : mark.kind == .post ? slate : (daylight ? graphiteDay : 0x2B323B)
            let head = CGRect(x: c.x - side / 2, y: c.y - side * 1.32, width: side, height: side)
            filled(pin(head: head), fill: fill, rim: white, rimWidth: rimWidth(side, mark.state), in: cg)
            glyph(mark.kind == .post ? .post : .camera, in: head, share: 0.62, ink: white, cg: cg)
        case .tripod, .mobile:
            let rect = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
            let fill = mark.state == .alert ? red : amber
            let ink: UInt32 = mark.state == .alert ? white : 0x1C1C1E
            let shape = diamond(in: rect.insetBy(dx: -side * 0.1, dy: -side * 0.1), radius: side * 0.14)
            if mark.unconfirmed {
                dashed(shape, fill: fill, rim: 0x1C1C1E, rimWidth: max(1.8, side * 0.07), side: side, in: cg)
            } else {
                filled(shape, fill: fill, rim: daylight ? 0x1C1C1E : white, rimWidth: max(1.6, side * 0.06),
                       outer: daylight ? white : nil, in: cg)
            }
            liveGlyph(mark.kind, in: rect.insetBy(dx: side * 0.14, dy: side * 0.14), ink: ink, cg: cg)
        case .accident:
            let rect = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
            let shape = triangle(in: rect.insetBy(dx: -side * 0.06, dy: -side * 0.06), radius: side * 0.12)
            filled(shape, fill: accidentRed, rim: white, rimWidth: rimWidth(side, mark.state), in: cg)
            exclamation(in: triangleGlyphRect(rect), ink: white, cg: cg)
        }
    }

    // MARK: - Пометки

    private static func drawBadges(_ mark: Mark, side: CGFloat, variant: Variant, in cg: CGContext, at c: CGPoint) {
        guard mark.unconfirmed || (mark.own && mark.state != .alert) else { return }
        if variant == .c, mark.state == .calm, mark.kind == .stationary || mark.kind == .post { return }
        let top = anchorsAtBottom(mark, variant) ? c.y - side * 1.32 : c.y - side / 2
        let middle = CGPoint(x: c.x + side * 0.42, y: top + side * 0.08)
        badge(text: mark.unconfirmed ? "?" : nil, fill: mark.unconfirmed ? slate : success, at: middle, in: cg)
    }

    /// Пометка 16 pt: «?» у неподтверждённой отметки, галочка у своей камеры.
    static func badge(text: String?, fill: UInt32, at c: CGPoint, in cg: CGContext) {
        let disc = CGRect(x: c.x - 7.25, y: c.y - 7.25, width: 14.5, height: 14.5)
        cg.setFillColor(color(white))
        cg.fillEllipse(in: disc)
        cg.setFillColor(color(fill))
        cg.fillEllipse(in: disc.insetBy(dx: 1.5, dy: 1.5))
        if let text {
            Self.text(text, size: 10, weight: .heavy, color: white, center: c, in: cg)
        } else {
            cg.saveGState()
            cg.setStrokeColor(color(white))
            cg.setLineWidth(1.9)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.move(to: CGPoint(x: c.x - 3.2, y: c.y + 0.2))
            cg.addLine(to: CGPoint(x: c.x - 1, y: c.y + 2.4))
            cg.addLine(to: CGPoint(x: c.x + 3.3, y: c.y - 2.2))
            cg.strokePath()
            cg.restoreGState()
        }
    }

    // MARK: - Кластер

    /// Кружок с числом камер на обзорном масштабе; `live` — внутри есть
    /// отметка водителей: её значок выглядывает сбоку, тренога не тонет в числе.
    static func drawCluster(count: Int, live: Bool, variant: Variant, daylight: Bool,
                            in cg: CGContext, at c: CGPoint) {
        let label = "\(count)"
        let side: CGFloat = count >= 10 ? 32 : 28
        let rect = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
        switch variant {
        case .a:
            let shape = CGPath(roundedRect: rect, cornerWidth: side * 0.27, cornerHeight: side * 0.27, transform: nil)
            filled(shape, fill: daylight ? graphiteDay : graphiteNight, rim: daylight ? white : inkDark,
                   rimWidth: 2, in: cg)
            text(label, size: 13, weight: .heavy, color: daylight ? white : inkDark, center: c, in: cg)
        case .b:
            let shape = CGPath(roundedRect: rect, cornerWidth: side * 0.16, cornerHeight: side * 0.16, transform: nil)
            framed(shape, fill: daylight ? white : 0xE4E8ED, rim: 0x1C1C1E, rimWidth: 2, in: cg)
            text(label, size: 13, weight: .heavy, color: 0x1C1C1E, center: c, in: cg)
        case .c:
            filled(CGPath(ellipseIn: rect, transform: nil), fill: daylight ? graphiteDay : graphiteNight,
                   rim: daylight ? white : inkDark, rimWidth: 2, in: cg)
            text(label, size: 13, weight: .heavy, color: daylight ? white : inkDark, center: c, in: cg)
        }
        guard live else { return }
        cg.saveGState()
        cg.translateBy(x: c.x + side * 0.55, y: c.y - side * 0.45)
        cg.scaleBy(x: 0.58, y: 0.58)
        draw(Mark(kind: .tripod, state: .calm), variant: variant, daylight: daylight, in: cg, at: .zero)
        cg.restoreGState()
    }

    // MARK: - Формы

    private static func rimWidth(_ side: CGFloat, _ state: State) -> CGFloat {
        state == .calm ? max(1.6, side * 0.07) : max(2, side * 0.08)
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
        if let outer {
            cg.addPath(shape)
            cg.setStrokeColor(color(outer))
            cg.setLineWidth(rimWidth * 2 + 2)
            cg.setLineJoin(.round)
            cg.strokePath()
        }
        cg.addPath(shape)
        cg.setStrokeColor(color(rim))
        cg.setLineWidth(rimWidth * 2)
        cg.setLineJoin(.round)
        cg.strokePath()
        cg.addPath(shape)
        cg.setFillColor(color(fill))
        cg.fillPath()
    }

    /// Рамка знака: кант внутри формы (у знака рамка — часть таблички).
    private static func framed(_ shape: CGPath, fill: UInt32, rim: UInt32, rimWidth: CGFloat, in cg: CGContext) {
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(gray: 0, alpha: 0.32))
        cg.addPath(shape)
        cg.setFillColor(color(rim))
        cg.fillPath()
        cg.restoreGState()
        cg.saveGState()
        cg.addPath(shape)
        cg.clip()
        cg.addPath(shape)
        cg.setFillColor(color(fill))
        cg.fillPath()
        cg.addPath(shape)
        cg.setStrokeColor(color(rim))
        cg.setLineWidth(rimWidth * 2)
        cg.strokePath()
        cg.restoreGState()
    }

    /// Неподтверждённая отметка: пунктир канта, как у призрака сейчас.
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

    /// Треугольник вершиной вверх, вписанный в `rect`, со скруглёнными углами.
    static func triangle(in rect: CGRect, radius: CGFloat) -> CGPath {
        let h = rect.width * 0.9
        let top = rect.midY - h * 0.55
        return rounded([CGPoint(x: rect.midX, y: top), CGPoint(x: rect.maxX, y: top + h),
                        CGPoint(x: rect.minX, y: top + h)], radius: radius)
    }

    /// Где глиф в треугольнике: ниже центра, где он шире.
    static func triangleGlyphRect(_ rect: CGRect) -> CGRect {
        let s = rect.width * 0.5
        return CGRect(x: rect.midX - s / 2, y: rect.midY - s * 0.32, width: s, height: s)
    }

    static func diamond(in rect: CGRect, radius: CGFloat) -> CGPath {
        rounded([CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
                 CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)], radius: radius)
    }

    /// Булавка: круглая голова `head`, остриё внизу на 0.32 стороны ниже головы.
    static func pin(head: CGRect) -> CGPath {
        let r = head.width / 2
        let center = CGPoint(x: head.midX, y: head.midY)
        let tip = CGPoint(x: head.midX, y: head.maxY + head.width * 0.32)
        let spread: CGFloat = 0.62
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: center.x - r * sin(spread), y: center.y + r * cos(spread)))
        path.addArc(center: center, radius: r, startAngle: .pi / 2 + spread, endAngle: .pi / 2 - spread, clockwise: false)
        path.closeSubpath()
        return path
    }

    private static func rounded(_ points: [CGPoint], radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let n = points.count
        let start = CGPoint(x: (points[0].x + points[n - 1].x) / 2, y: (points[0].y + points[n - 1].y) / 2)
        path.move(to: start)
        for i in 0..<n {
            path.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % n], radius: radius)
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Глифы

    private static func glyph(_ glyph: CameraGlyph, in rect: CGRect, share: CGFloat, ink: UInt32, cg: CGContext) {
        let s = rect.width * share
        glyph.draw(in: cg, rect: CGRect(x: rect.midX - s / 2, y: rect.midY - s / 2, width: s, height: s),
                   ink: color(ink))
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

    /// Глиф отметки водителей на сетке 24: тренога — камера на трёх ногах;
    /// передвижной радар — радар-пистолет с волной.
    static func liveGlyph(_ kind: Kind, in rect: CGRect, ink: UInt32, cg: CGContext) {
        let grid: CGFloat = 24
        let width = CameraGlyph.gridLineWidth(side: rect.width) * 1.05
        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.minY)
        cg.scaleBy(x: rect.width / grid, y: rect.height / grid)
        cg.setStrokeColor(color(ink))
        cg.setFillColor(color(ink))
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.setLineWidth(width)
        switch kind {
        case .mobile:
            // Радар-пистолет: корпус, рукоять назад и две дуги волны перед стволом.
            cg.addPath(CGPath(roundedRect: CGRect(x: 2, y: 7, width: 12, height: 6.5), cornerWidth: 2, cornerHeight: 2,
                              transform: nil))
            cg.strokePath()
            cg.move(to: CGPoint(x: 6, y: 13.5)); cg.addLine(to: CGPoint(x: 3.5, y: 20.5))
            cg.addLine(to: CGPoint(x: 7, y: 20.5)); cg.addLine(to: CGPoint(x: 9, y: 13.5))
            cg.strokePath()
            for r in [4.0, 7.5] as [CGFloat] {
                cg.addArc(center: CGPoint(x: 13.5, y: 10.5), radius: r, startAngle: -0.75, endAngle: 0.75, clockwise: false)
                cg.strokePath()
            }
        default:
            // Тренога: камера сверху, три ноги.
            cg.addPath(CGPath(roundedRect: CGRect(x: 5, y: 2.5, width: 14, height: 7.5), cornerWidth: 2, cornerHeight: 2,
                              transform: nil))
            cg.strokePath()
            cg.fillEllipse(in: CGRect(x: 7.4, y: 4.9, width: 2.8, height: 2.8))
            cg.move(to: CGPoint(x: 12, y: 10)); cg.addLine(to: CGPoint(x: 4.5, y: 21.5))
            cg.move(to: CGPoint(x: 12, y: 10)); cg.addLine(to: CGPoint(x: 12, y: 21.5))
            cg.move(to: CGPoint(x: 12, y: 10)); cg.addLine(to: CGPoint(x: 19.5, y: 21.5))
            cg.strokePath()
        }
        cg.restoreGState()
    }

    // MARK: - Текст

    enum Weight { case semibold, heavy }

    /// Текст по центру в системе координат y вниз (UIKit и перевёрнутый кадр).
    static func text(_ string: String, size: CGFloat, weight: Weight, color rgb: UInt32,
                     center: CGPoint, in cg: CGContext) {
        let base = CTFontCreateUIFontForLanguage(weight == .heavy ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let traits = [kCTFontWeightTrait: weight == .heavy ? 0.62 : 0.3] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
        let font = CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(rgb),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        cg.saveGState()
        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        cg.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y + bounds.midY)
        CTLineDraw(line, cg)
        cg.restoreGState()
    }
}
#endif
