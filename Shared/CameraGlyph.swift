//
//  CameraGlyph.swift
//  RadarMap (+ виджеты, часы)
//
//  Значок камеры — стиль A «Монета» (29.C, выбор владельца 26.10: «камеры
//  иконку одного стиля сделать, а то все разного»). До 29.C значки были
//  SF Symbols разного рода — залитый фотоаппарат, контурный спидометр, точка
//  с волнами, маяк, полущит: разная толщина, плотность и сетка, и каждый
//  экран рисовал свой круг по-своему.
//
//  Теперь один источник на все поверхности (карта, HUD, оповещение, списки,
//  CarPlay, Live Activity, часы). С 26.10 («все камеры — одна иконка, а то
//  все разные, они вроде все радары», 29.C2) значок у всех камер ОДИН:
//  стационарная камера и радар, интеллектуальная, передвижной радар и тренога
//  — камера наблюдения на красном круге. Тип остаётся словом (карточка,
//  оповещение, голос); отдельный значок — только у того, что не камера:
//  пост ДПС, ДТП и «прочее».
//    * глиф — контур на одной сетке 24×24, линия 2,2 со скруглёнными концами,
//      но не тоньше 1,5 pt на мелком значке (`gridLineWidth`): на 24 pt
//      контур 2,2 давал 1,3 pt и терялся боковым зрением и на тёмном асфальте;
//    * основа — круг с белым кантом и мягкой тенью (`CameraCoin`).
//  Цвета сюда не входят: их даёт вызывающий (Theme в приложении,
//  WidgetPalette в виджетах), а рисование — CoreGraphics, чтобы им же
//  пользовались растры для движка и CarPlay, и Canvas SwiftUI.
//
//  Чистые пути; CameraGlyphTests.
//

import SwiftUI
import CoreGraphics

nonisolated enum CameraGlyph: String, CaseIterable, Sendable {
    /// Камера любого типа, пост ДПС, ДТП, неизвестная точка; тренога и
    /// передвижной радар — пока только на карте (90, `CameraType.mapGlyph`).
    case camera, post, accident, other, tripod, mobileRadar

    /// По имени символа типа (`CameraType.symbolName`): оно ходит строкой в
    /// Live Activity и на часы и служит именем картинки в стиле движка.
    /// nil — не камера (щит «камер нет», «нет геопозиции»): там свой символ.
    init?(symbol: String?) {
        switch symbol {
        // Все камеры, что меряют скорость или фиксируют нарушения, — один значок.
        case "camera.fill", "speedometer", "sensor.tag.radiowaves.forward.fill",
             "dot.radiowaves.left.and.right", "light.beacon.max.fill":
                                                   self = .camera
        case "shield.lefthalf.filled":             self = .post
        case "exclamationmark.triangle.fill":      self = .accident
        case "mappin":                             self = .other
        default:                                   return nil
        }
    }

    /// Заливка значка (Theme.Types; PaletteTests). Один источник на приложение
    /// (`CameraType.markerRGB`), стиль движка, виджеты и часы. Камера — красный
    /// камеры у всех её типов; ДТП — постоянный красный опасности (ночной
    /// #FF7A70 с белым глифом не дотягивал до 4,5:1), отличается от камеры
    /// глифом; неизвестный тип — графит, не синий интерфейса.
    /// Отметка водителей (90) — янтарь: светлая заливка, тёмный глиф (9,3:1);
    /// от красного камеры отличается светлотой и при дейтеранопии.
    var fillRGB: UInt32 {
        switch self {
        case .camera:   return 0xD93025
        case .post:     return 0x46525E
        case .accident: return 0xC62828
        case .other:    return 0x556070
        case .tripod, .mobileRadar: return 0xFFB020
        }
    }

    /// Глиф на своей заливке: белый на тёмных, тёмный на янтаре (≥ 4,5:1).
    var inkRGB: UInt32 {
        switch self {
        case .tripod, .mobileRadar: return 0x1C1C1E
        default: return 0xFFFFFF
        }
    }

    /// Сетка глифа.
    static let grid: CGFloat = 24
    /// Линия стиля A в единицах сетки.
    static let lineWidth: CGFloat = 2.2
    /// Тоньше этого линия не бывает (pt): мелкий значок толще своей сетки.
    static let minLinePoints: CGFloat = 1.5

    /// Толщина линии в единицах сетки для глифа стороной `side` pt.
    static func gridLineWidth(side: CGFloat) -> CGFloat {
        max(lineWidth, minLinePoints * grid / max(side, 1))
    }

    // MARK: - Части

    enum Role: Sendable { case stroke, fill }

    struct Part {
        let role: Role
        let path: CGPath
    }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil)
    }

    private static func lines(_ points: [CGPoint], closed: Bool = false) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        if closed { path.closeSubpath() }
        return path
    }

    /// Глиф на сетке 24×24.
    var parts: [Part] {
        switch self {
        case .camera:
            // Камера наблюдения: корпус с козырьком, наклонён к дороге, на
            // кронштейне. Объектив уже корпуса — иначе читается рупором. Один
            // значок на все типы камер: на 24 pt он читается «камерой» (как
            // и «до камеры» в HUD), а волны «радара» — это кнопка «Радар!»,
            // то есть «отметить», а не «здесь стоит».
            var tilt = CGAffineTransform(translationX: 11, y: 10).rotated(by: 14 * .pi / 180)
                .translatedBy(x: -11, y: -10)
            let body = CGMutablePath()
            body.addRoundedRect(in: CGRect(x: 3, y: 7, width: 12.5, height: 6.5), cornerWidth: 1.8, cornerHeight: 1.8)
            body.addRoundedRect(in: CGRect(x: 15.5, y: 8.1, width: 4.6, height: 4.3), cornerWidth: 1.2, cornerHeight: 1.2)
            let visor = Self.lines([CGPoint(x: 2.6, y: 4.6), CGPoint(x: 19.6, y: 4.6)])
            let mount = CGMutablePath()
            mount.move(to: CGPoint(x: 7.5, y: 14.2)); mount.addLine(to: CGPoint(x: 7.5, y: 19))
            mount.move(to: CGPoint(x: 4, y: 19.6)); mount.addLine(to: CGPoint(x: 11, y: 19.6))
            return [Part(role: .stroke, path: body.copy(using: &tilt) ?? body),
                    Part(role: .stroke, path: visor.copy(using: &tilt) ?? visor),
                    Part(role: .stroke, path: mount),
                    Part(role: .fill, path: Self.circle(6.4, 10.25, 1.2).copy(using: &tilt) ?? Self.circle(6.4, 10.25, 1.2))]
        case .post:
            // Пост ДПС: щит со звездой.
            let shield = CGMutablePath()
            shield.move(to: CGPoint(x: 12, y: 2.8))
            shield.addLine(to: CGPoint(x: 19.5, y: 5.6))
            shield.addLine(to: CGPoint(x: 19.5, y: 11.2))
            shield.addCurve(to: CGPoint(x: 12, y: 21.2), control1: CGPoint(x: 19.5, y: 15.8), control2: CGPoint(x: 16.4, y: 19.3))
            shield.addCurve(to: CGPoint(x: 4.5, y: 11.2), control1: CGPoint(x: 7.6, y: 19.3), control2: CGPoint(x: 4.5, y: 15.8))
            shield.addLine(to: CGPoint(x: 4.5, y: 5.6))
            shield.closeSubpath()
            let star = (0..<10).map { i -> CGPoint in
                let r: CGFloat = i.isMultiple(of: 2) ? 4.1 : 1.75
                let a = (-90 + Double(i) * 36) * .pi / 180
                return CGPoint(x: 12 + r * cos(a), y: 11.6 + r * sin(a))
            }
            return [Part(role: .stroke, path: shield), Part(role: .fill, path: Self.lines(star, closed: true))]
        case .accident:
            // ДТП: треугольник с восклицательным знаком.
            return [Part(role: .stroke, path: Self.lines([CGPoint(x: 12, y: 3.5), CGPoint(x: 21, y: 19.5),
                                                         CGPoint(x: 3, y: 19.5)], closed: true)),
                    Part(role: .stroke, path: Self.lines([CGPoint(x: 12, y: 9.6), CGPoint(x: 12, y: 13.8)])),
                    Part(role: .fill, path: Self.circle(12, 16.7, 1.3))]
        case .other:
            return [Part(role: .stroke, path: Self.circle(12, 12, 7.6)), Part(role: .fill, path: Self.circle(12, 12, 2.5))]
        case .tripod:
            // Тренога: камера сверху, три ноги.
            let legs = CGMutablePath()
            for foot in [CGPoint(x: 4.5, y: 21.5), CGPoint(x: 12, y: 21.5), CGPoint(x: 19.5, y: 21.5)] {
                legs.move(to: CGPoint(x: 12, y: 10)); legs.addLine(to: foot)
            }
            return [Part(role: .stroke, path: CGPath(roundedRect: CGRect(x: 5, y: 2.5, width: 14, height: 7.5),
                                                     cornerWidth: 2, cornerHeight: 2, transform: nil)),
                    Part(role: .fill, path: Self.circle(8.8, 6.3, 1.4)),
                    Part(role: .stroke, path: legs)]
        case .mobileRadar:
            // Радар-пистолет: корпус, рукоять назад и две дуги волны перед стволом.
            let grip = Self.lines([CGPoint(x: 6, y: 13.5), CGPoint(x: 3.5, y: 20.5),
                                   CGPoint(x: 7, y: 20.5), CGPoint(x: 9, y: 13.5)])
            let waves = CGMutablePath()
            for r in [4.0, 7.5] as [CGFloat] {
                waves.move(to: CGPoint(x: 13.5 + r * cos(-0.75), y: 10.5 + r * sin(-0.75)))
                waves.addArc(center: CGPoint(x: 13.5, y: 10.5), radius: r, startAngle: -0.75, endAngle: 0.75, clockwise: false)
            }
            return [Part(role: .stroke, path: CGPath(roundedRect: CGRect(x: 2, y: 7, width: 12, height: 6.5),
                                                     cornerWidth: 2, cornerHeight: 2, transform: nil)),
                    Part(role: .stroke, path: grip),
                    Part(role: .stroke, path: waves)]
        }
    }

    /// Глиф одной заливаемой фигурой в квадрате `rect`: линии обведены
    /// контуром той же толщины. Для SwiftUI-формы, которая берёт цвет из
    /// foregroundStyle (значок «камеры» внутри строки текста).
    func outline(in rect: CGRect) -> CGPath {
        let width = Self.gridLineWidth(side: rect.width)
        let out = CGMutablePath()
        for part in parts {
            switch part.role {
            case .stroke:
                out.addPath(part.path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
            case .fill:
                out.addPath(part.path)
            }
        }
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / Self.grid, y: rect.height / Self.grid)
        return out.copy(using: &transform) ?? out
    }

    // MARK: - Рисование

    /// Глиф в квадрате `rect` цветом `ink`.
    func draw(in cg: CGContext, rect: CGRect, ink: CGColor) {
        let width = Self.gridLineWidth(side: rect.width)
        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.minY)
        cg.scaleBy(x: rect.width / Self.grid, y: rect.height / Self.grid)
        cg.setStrokeColor(ink)
        cg.setFillColor(ink)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        for part in parts {
            cg.addPath(part.path)
            switch part.role {
            case .stroke:
                cg.setLineWidth(width)
                cg.strokePath()
            case .fill:
                cg.fillPath()
            }
        }
        cg.restoreGState()
    }
}

// MARK: - Основа «Монета»

/// Круг с белым кантом и мягкой тенью — основа значка камеры везде.
nonisolated enum CameraCoin {
    /// Доля диаметра под глиф.
    static let glyphShare: CGFloat = 0.6
    /// Поле вокруг круга под тень (pt).
    static let shadowPad: CGFloat = 3

    static func rimWidth(side: CGFloat) -> CGFloat { max(2, side * 0.08) }

    /// Значок в круге `disc`. `dashedRim` — неподтверждённая отметка водителей
    /// (пунктир канта, как на онбординге).
    static func draw(_ glyph: CameraGlyph, in cg: CGContext, disc: CGRect,
                     fill: CGColor, ink: CGColor, rim: CGColor,
                     shadow: Bool, dashedRim: Bool = false) {
        let side = min(disc.width, disc.height)
        let rimWidth = rimWidth(side: side)
        if shadow {
            // Тень — только под основой, не под глифом.
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 3,
                         color: CGColor(gray: 0, alpha: 0.3))
            cg.setFillColor(dashedRim ? fill : rim)
            cg.fillEllipse(in: disc)
            cg.restoreGState()
        }
        if dashedRim {
            cg.setFillColor(fill)
            cg.fillEllipse(in: disc)
            cg.saveGState()
            cg.setStrokeColor(rim)
            cg.setLineWidth(rimWidth)
            cg.setLineDash(phase: 0, lengths: [side * 0.12, side * 0.09])
            cg.strokeEllipse(in: disc.insetBy(dx: rimWidth / 2, dy: rimWidth / 2))
            cg.restoreGState()
        } else {
            cg.setFillColor(rim)
            cg.fillEllipse(in: disc)
            cg.setFillColor(fill)
            cg.fillEllipse(in: disc.insetBy(dx: rimWidth, dy: rimWidth))
        }
        let glyphSide = side * glyphShare
        glyph.draw(in: cg, rect: CGRect(x: disc.midX - glyphSide / 2, y: disc.midY - glyphSide / 2,
                                        width: glyphSide, height: glyphSide), ink: ink)
    }
}

// MARK: - SwiftUI

/// Значок «Монета» стороной `side` (тень выходит за рамку, не меняя раскладку).
struct CameraCoinView: View, Equatable {
    let glyph: CameraGlyph
    let fill: Color
    let ink: Color
    var rim: Color = .white
    let side: CGFloat
    var shadow = false
    var dashedRim = false

    var body: some View {
        let pad = shadow ? CameraCoin.shadowPad : 0
        Canvas { context, _ in
            let environment = context.environment
            let fill = fill.resolve(in: environment).cgColor
            let ink = ink.resolve(in: environment).cgColor
            let rim = rim.resolve(in: environment).cgColor
            context.withCGContext { cg in
                CameraCoin.draw(glyph, in: cg, disc: CGRect(x: pad, y: pad, width: side, height: side),
                                fill: fill, ink: ink, rim: rim, shadow: shadow, dashedRim: dashedRim)
            }
        }
        .frame(width: side + 2 * pad, height: side + 2 * pad)
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// Глиф формой: цвет — из foregroundStyle, как у SF Symbol в строке текста.
struct CameraGlyphShape: Shape {
    let glyph: CameraGlyph

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        return Path(glyph.outline(in: square))
    }
}

/// Один глиф без основы (Dynamic Island, кнопки шаблонов CarPlay, подписи).
struct CameraGlyphView: View, Equatable {
    let glyph: CameraGlyph
    let ink: Color
    let side: CGFloat

    var body: some View {
        Canvas { context, _ in
            let ink = ink.resolve(in: context.environment).cgColor
            context.withCGContext { cg in
                glyph.draw(in: cg, rect: CGRect(x: 0, y: 0, width: side, height: side), ink: ink)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
