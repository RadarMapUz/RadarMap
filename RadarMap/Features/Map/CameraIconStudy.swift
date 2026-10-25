//
//  CameraIconStudy.swift
//  RadarMap
//
//  Этап 1 задачи 29.C (владелец, 25.10: «камеры иконку одного стиля сделать,
//  а то все разного — один красивый значок нужно придумать»). Три варианта
//  единого языка значков — только для выбора, в выпуск не идёт (DEBUG).
//
//  Сейчас значки собраны из SF Symbols разного рода: залитый фотоаппарат,
//  контурный спидометр, точка с волнами, маяк, полущит — разная толщина,
//  разная плотность, разная сетка. Здесь все восемь глифов нарисованы на
//  одной сетке 24×24 одной моделью (тело / линия / вырез / точка), и каждый
//  вариант задаёт ей свой характер — контур, силуэт или знак — и свою форму
//  основы. Цвета — прежние, проверенные PaletteTests: варианты отличаются
//  формой, не цветом.
//
//  Ключи: `-cameraIconVariant a|b|c` — значки варианта на карте движка;
//  `-dumpCameraIconSheets <папка>` — листы всех типов × состояний в PNG.
//

#if DEBUG
import SwiftUI
import CoreImage
import os

enum CameraIconVariant: String, CaseIterable, Sendable {
    case coin = "a", pin = "b", sign = "c", coinSolid = "d"

    var title: String {
        switch self {
        case .coin: return "A · «Монета»"
        case .pin:  return "B · «Метка»"
        case .sign: return "C · «Знак»"
        case .coinSolid: return "A′ · «Монета, силуэт» (рекомендация)"
        }
    }

    var subtitle: String {
        switch self {
        case .coin: return "круг, белый кант, мягкая тень · глиф — контур 2,2 на сетке 24, скруглённые концы (как Apple Maps)"
        case .pin:  return "капля с хвостиком к точке камеры (на пути и цель), фон — без хвоста · глиф — залитый силуэт с вырезами (как Яндекс/Waze)"
        case .coinSolid: return "форма A (круг, белый кант, мягкая тень) + глиф B (залитый силуэт): плотнее читается на 24 pt и боковым зрением"
        case .sign: return "скруглённый квадрат дорожного знака, белый кант + тонкая внутренняя кромка · глиф — жирный контур 2,6 с полупрозрачной заливкой (как Amap)"
        }
    }

    /// Вариант из ключа запуска — значки на карте движка.
    static var launch: CameraIconVariant? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-cameraIconVariant"), index + 1 < args.count else { return nil }
        return CameraIconVariant(rawValue: args[index + 1].lowercased())
    }

    fileprivate var family: CameraGlyphArt.Family {
        switch self {
        case .coin: return .line
        case .pin, .coinSolid: return .solid
        case .sign: return .bold
        }
    }
}

enum CameraIconTier: Sendable { case alert, path, calm }

enum CameraIconBadge: Sendable { case ghost, own }

// MARK: - Глифы: одна сетка 24×24, одна модель

enum CameraGlyphArt {
    enum Family { case line, solid, bold }

    fileprivate enum Role {
        /// Силуэт: контур (line), заливка (solid), жирный контур + полупрозрачная заливка (bold).
        case body
        /// Открытая линия цветом глифа во всех характерах (волны, стойка, ноги).
        case line
        /// Открытая линия ВНУТРИ тела: в силуэте — вырез цветом заливки.
        case cutStroke
        /// Мелкая залитая деталь внутри тела: в силуэте — вырез.
        case cutFill
        /// Кольцо внутри тела (объектив): контур; в силуэте — залитый вырез.
        case cutRing
        /// Залитая точка цветом глифа всегда.
        case dot
    }

    fileprivate struct Part { let role: Role; let path: Path }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }

    /// Дуга точками: 0° — вправо, −90° — вверх (ось y вниз).
    private static func arc(_ c: CGPoint, _ r: CGFloat, from: Double, to: Double, steps: Int = 24) -> [CGPoint] {
        (0...steps).map { i in
            let a = (from + (to - from) * Double(i) / Double(steps)) * .pi / 180
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
    }

    private static func polyline(_ points: [CGPoint], closed: Bool = false) -> Path {
        var p = Path()
        p.addLines(points)
        if closed { p.closeSubpath() }
        return p
    }

    private static func waves(_ c: CGPoint, radii: [CGFloat], half: Double, sides: [Double]) -> [Part] {
        radii.flatMap { r in
            sides.map { mid in Part(role: .line, path: polyline(arc(c, r, from: mid - half, to: mid + half))) }
        }
    }

    fileprivate static func parts(_ kind: CameraType) -> [Part] {
        switch kind {
        case .stationaryCamera:
            // Камера видеофиксации: корпус с козырьком, наклонён к дороге,
            // на кронштейне. Объектив уже корпуса — не раструб (не «рупор»).
            let tilt = CGAffineTransform(translationX: 11, y: 10).rotated(by: 14 * .pi / 180)
                .translatedBy(x: -11, y: -10)
            var body = Path(roundedRect: CGRect(x: 3, y: 7, width: 12.5, height: 6.5), cornerRadius: 1.8)
            body.addRoundedRect(in: CGRect(x: 15.5, y: 8.1, width: 4.6, height: 4.3),
                                cornerSize: CGSize(width: 1.2, height: 1.2))
            var visor = Path()
            visor.move(to: CGPoint(x: 2.6, y: 4.6)); visor.addLine(to: CGPoint(x: 19.6, y: 4.6))
            var mount = Path()
            mount.move(to: CGPoint(x: 7.5, y: 14.2)); mount.addLine(to: CGPoint(x: 7.5, y: 19))
            mount.move(to: CGPoint(x: 4, y: 19.6)); mount.addLine(to: CGPoint(x: 11, y: 19.6))
            return [Part(role: .body, path: body.applying(tilt)), Part(role: .line, path: visor.applying(tilt)),
                    Part(role: .line, path: mount),
                    Part(role: .cutFill, path: circle(6.4, 10.25, 1.2).applying(tilt))]
        case .stationaryRadar:
            // Радар: шкала спидометра со стрелкой.
            let c = CGPoint(x: 12, y: 14.5)
            let body = polyline(arc(c, 8.6, from: 165, to: 375, steps: 40), closed: true)
            var needle = Path()
            needle.move(to: c)
            needle.addLine(to: CGPoint(x: c.x + 5.6 * cos(-50 * .pi / 180), y: c.y + 5.6 * sin(-50 * .pi / 180)))
            return [Part(role: .body, path: body), Part(role: .cutStroke, path: needle),
                    Part(role: .cutFill, path: circle(c.x, c.y, 1.9))]
        case .intelligentRadar:
            // Камера + радар: объектив в корпусе и волны измерения.
            let body = Path(roundedRect: CGRect(x: 3, y: 6, width: 11.5, height: 12), cornerRadius: 3.2)
            return [Part(role: .body, path: body), Part(role: .cutRing, path: circle(8.75, 12, 2.9))]
                + waves(CGPoint(x: 14.5, y: 12), radii: [3.6, 7], half: 42, sides: [0])
        case .mobileRadar:
            // Передвижной радар: источник и волны в обе стороны (кнопка «Радар!»).
            return [Part(role: .dot, path: circle(12, 12, 2.6))]
                + waves(CGPoint(x: 12, y: 12), radii: [5.6, 9.2], half: 38, sides: [0, 180])
        case .tripod:
            // Тренога: прибор на трёх ногах.
            let body = Path(roundedRect: CGRect(x: 4.5, y: 3.5, width: 15, height: 7.5), cornerRadius: 2)
            var legs = Path()
            for end in [CGPoint(x: 5.5, y: 20.5), CGPoint(x: 12, y: 20.5), CGPoint(x: 18.5, y: 20.5)] {
                legs.move(to: CGPoint(x: 12, y: 11)); legs.addLine(to: end)
            }
            return [Part(role: .body, path: body), Part(role: .line, path: legs),
                    Part(role: .cutRing, path: circle(15.2, 7.25, 1.9))]
        case .dpsPost:
            // Пост ДПС: щит со звездой.
            var shield = Path()
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
            return [Part(role: .body, path: shield), Part(role: .cutFill, path: polyline(star, closed: true))]
        case .accident:
            // ДТП: треугольник с восклицательным знаком.
            var triangle = Path()
            triangle.move(to: CGPoint(x: 12, y: 3.5))
            triangle.addLine(to: CGPoint(x: 21, y: 19.5))
            triangle.addLine(to: CGPoint(x: 3, y: 19.5))
            triangle.closeSubpath()
            var bar = Path()
            bar.move(to: CGPoint(x: 12, y: 9.6)); bar.addLine(to: CGPoint(x: 12, y: 13.8))
            return [Part(role: .body, path: triangle), Part(role: .cutStroke, path: bar),
                    Part(role: .cutFill, path: circle(12, 16.7, 1.3))]
        case .other:
            return [Part(role: .body, path: circle(12, 12, 6.5)), Part(role: .cutFill, path: circle(12, 12, 2.2))]
        }
    }

    /// Глиф в квадрате `rect`: `ink` — цвет глифа, `knock` — цвет заливки
    /// значка (им вырезаются детали силуэта).
    static func draw(_ kind: CameraType, family: Family, in context: GraphicsContext, rect: CGRect,
                     ink: Color, knock: Color) {
        var ctx = context
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / 24, y: rect.height / 24)
        let width: CGFloat
        let style: StrokeStyle
        switch family {
        case .line:  width = 2.2; style = StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
        case .solid: width = 2.6; style = StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
        case .bold:  width = 2.7; style = StrokeStyle(lineWidth: 2.7, lineCap: .butt, lineJoin: .miter, miterLimit: 3)
        }
        let cut = StrokeStyle(lineWidth: family == .solid ? 2.4 : width, lineCap: .round, lineJoin: .round)
        for part in parts(kind) {
            switch (part.role, family) {
            case (.body, .line):
                ctx.stroke(part.path, with: .color(ink), style: style)
            case (.body, .solid):
                ctx.fill(part.path, with: .color(ink))
                ctx.stroke(part.path, with: .color(ink), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            case (.body, .bold):
                ctx.fill(part.path, with: .color(ink.opacity(0.32)))
                ctx.stroke(part.path, with: .color(ink), style: style)
            case (.line, _):
                ctx.stroke(part.path, with: .color(ink), style: style)
            case (.cutStroke, .solid):
                ctx.stroke(part.path, with: .color(knock), style: cut)
            case (.cutStroke, _):
                ctx.stroke(part.path, with: .color(ink), style: style)
            case (.cutFill, .solid):
                ctx.fill(part.path, with: .color(knock))
            case (.cutFill, _), (.dot, _):
                ctx.fill(part.path, with: .color(ink))
            case (.cutRing, .solid):
                ctx.fill(part.path, with: .color(knock))
            case (.cutRing, .line):
                ctx.stroke(part.path, with: .color(ink), style: StrokeStyle(lineWidth: 1.8))
            case (.cutRing, .bold):
                ctx.fill(part.path, with: .color(knock))
                ctx.stroke(part.path, with: .color(ink), style: StrokeStyle(lineWidth: 2.2))
            }
        }
    }
}

// MARK: - Значок

struct CameraIconView: View {
    let kind: CameraType
    let tier: CameraIconTier
    let night: Bool
    let variant: CameraIconVariant
    var badge: CameraIconBadge? = nil
    /// Размер основы вместо размера тира (CarPlay, списки, тревога).
    var side: CGFloat? = nil
    /// Ореол тревоги (на карте его рисует слой camera-halo).
    var halo = false
    /// Метка: остриё в центре картинки — движок ставит центр картинки в точку.
    var tipAtCentre = false

    static let haloRadius: CGFloat = 26

    var baseSide: CGFloat {
        if let side { return side }
        switch tier {
        case .alert: return 38
        case .path:  return 30
        case .calm:  return variant == .pin ? 22 : 24
        }
    }

    private var hasTail: Bool { variant == .pin && tier != .calm }
    private var tail: CGFloat { baseSide * 0.3 }
    private var pad: CGFloat { halo ? max(4, Self.haloRadius - baseSide / 2 + 1) : 4 }

    var canvasSize: CGSize {
        let w = baseSide + 2 * pad
        guard hasTail else { return CGSize(width: w, height: w) }
        let h = baseSide + tail + 2 * pad
        return tipAtCentre ? CGSize(width: w, height: 2 * (h - pad)) : CGSize(width: w, height: h)
    }

    // Цвета — прежние (Theme.Types, CameraMarkerLook): варианты различаются
    // формой. ДТП — постоянный красный: ночной danger (#FF7A70) с белым
    // глифом не дотягивает до 4,5:1.
    private var fill: Color {
        if tier == .calm { return Color(uiColor: Theme.rgb(night ? 0xAEB6C2 : 0x3D4652)) }
        switch kind {
        case .accident: return Color(uiColor: Theme.rgb(0xC62828))
        case .other:    return Color(uiColor: Theme.rgb(0x556070))
        default:        return kind.tint
        }
    }

    private var ink: Color {
        if tier == .calm { return night ? Color(uiColor: Theme.rgb(0x14181D)) : .white }
        return kind.glyphTint
    }

    private var rim: Color {
        tier == .calm && night ? Color(uiColor: Theme.rgb(0x14181D)) : .white
    }

    private var rimWidth: CGFloat { max(2, baseSide * 0.08) }

    var body: some View {
        Canvas { context, _ in draw(in: context) }
            .frame(width: canvasSize.width, height: canvasSize.height)
    }

    /// Основа значка — путь в квадрате головы `rect` (у метки — с хвостом).
    private func shape(_ rect: CGRect, tail: CGFloat) -> Path {
        switch variant {
        case .coin, .coinSolid:
            return Path(ellipseIn: rect)
        case .sign:
            return Path(roundedRect: rect, cornerRadius: rect.width * 0.3, style: .continuous)
        case .pin:
            guard tail > 0 else { return Path(ellipseIn: rect) }
            let r = rect.width / 2
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let d = r + tail
            let alpha = acos(r / d) * 180 / .pi            // угол точки касания от «вниз»
            let start = 90 - alpha, end = 90 + alpha - 360  // по верху, против часовой
            var p = Path()
            p.move(to: CGPoint(x: c.x, y: c.y + d))
            let steps = 48
            for i in 0...steps {
                let a = (start + (end - start) * Double(i) / Double(steps)) * .pi / 180
                p.addLine(to: CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
            }
            p.closeSubpath()
            return p
        }
    }

    private func draw(in context: GraphicsContext) {
        let head = CGRect(x: pad, y: pad, width: baseSide, height: baseSide)
        let tailLength = hasTail ? tail : 0
        let centre = CGPoint(x: head.midX, y: head.midY)
        if halo {
            let r = Self.haloRadius
            context.fill(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(Color(uiColor: Theme.rgb(0xD93025)).opacity(0.18)))
        }
        let outer = shape(head, tail: tailLength)
        // Мягкая тень — под основой, не под глифом.
        var shadow = context
        shadow.addFilter(.shadow(color: .black.opacity(night ? 0.5 : 0.28), radius: 1.6, x: 0, y: 1))
        shadow.fill(outer, with: .color(rim))
        context.fill(outer, with: .color(rim))
        let inset = rimWidth
        let innerHead = head.insetBy(dx: inset, dy: inset)
        // Хвост внутренней заливки укорачивается так, чтобы кант шёл ровно.
        let r = head.width / 2
        let innerTail = tailLength > 0 ? max(0, tailLength - inset * (r + tailLength) / r + inset) : 0
        let inner = shape(innerHead, tail: innerTail)
        context.fill(inner, with: .color(fill))
        if variant == .sign {
            // Внутренняя кромка — как у дорожного знака.
            let keyline = innerHead.insetBy(dx: 1.4, dy: 1.4)
            context.stroke(Path(roundedRect: keyline, cornerRadius: keyline.width * 0.27, style: .continuous),
                           with: .color(ink.opacity(0.35)), lineWidth: 0.8)
        }
        let glyphSide = baseSide * (variant == .sign ? 0.56 : 0.6)
        let glyph = CGRect(x: centre.x - glyphSide / 2, y: centre.y - glyphSide / 2, width: glyphSide, height: glyphSide)
        CameraGlyphArt.draw(kind, family: variant.family, in: context, rect: glyph, ink: ink, knock: fill)
        if let badge { drawBadge(badge, head: head, in: context) }
    }

    private func drawBadge(_ badge: CameraIconBadge, head: CGRect, in context: GraphicsContext) {
        let s: CGFloat = 16
        let box = CGRect(x: head.maxX - s * 0.62, y: head.minY - s * 0.38, width: s, height: s)
        let outer = variant == .sign ? Path(roundedRect: box, cornerRadius: 4.5, style: .continuous) : Path(ellipseIn: box)
        let innerBox = box.insetBy(dx: 1.5, dy: 1.5)
        let inner = variant == .sign ? Path(roundedRect: innerBox, cornerRadius: 3.4, style: .continuous) : Path(ellipseIn: innerBox)
        context.fill(outer, with: .color(.white))
        context.fill(inner, with: .color(Color(uiColor: Theme.rgb(badge == .ghost ? 0x46525E : 0x177A41))))
        switch badge {
        case .ghost:
            let text = context.resolve(Text("?").font(.system(size: 10.5, weight: .heavy, design: .rounded)).foregroundStyle(.white))
            context.draw(text, at: CGPoint(x: box.midX, y: box.midY))
        case .own:
            var check = Path()
            check.move(to: CGPoint(x: box.minX + 4.8, y: box.minY + 8.2))
            check.addLine(to: CGPoint(x: box.minX + 7.0, y: box.minY + 10.4))
            check.addLine(to: CGPoint(x: box.minX + 11.3, y: box.minY + 5.8))
            context.stroke(check, with: .color(.white), style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Растр для движка и листы

@MainActor
enum CameraIconStudy {

    static let kinds: [CameraType] = [.stationaryCamera, .stationaryRadar, .intelligentRadar,
                                      .mobileRadar, .tripod, .dpsPost, .accident, .other("")]

    static func image(_ view: some View, scale: CGFloat = 3) -> UIImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.uiImage
    }

    /// Картинка движка для облика `suffix` (EngineMapView.markerLooks).
    static func mapImage(kind: CameraType, suffix: String, variant: CameraIconVariant) -> UIImage? {
        let tier: CameraIconTier
        var night = false
        switch suffix {
        case "-alert":  tier = .alert
        case "-calm-d": tier = .calm
        case "-calm-n": tier = .calm; night = true
        default:        tier = .path
        }
        return image(CameraIconView(kind: kind, tier: tier, night: night, variant: variant, tipAtCentre: true))
    }

    static func badgeImage(_ badge: CameraIconBadge, variant: CameraIconVariant) -> UIImage? {
        image(BadgeOnly(badge: badge, variant: variant))
    }

    private struct BadgeOnly: View {
        let badge: CameraIconBadge
        let variant: CameraIconVariant
        var body: some View {
            Canvas { context, _ in
                let box = CGRect(x: 0, y: 0, width: 16, height: 16)
                let outer = variant == .sign ? Path(roundedRect: box, cornerRadius: 4.5, style: .continuous) : Path(ellipseIn: box.insetBy(dx: 0.75, dy: 0.75))
                let innerBox = box.insetBy(dx: 2.25, dy: 2.25)
                let inner = variant == .sign ? Path(roundedRect: innerBox, cornerRadius: 3.2, style: .continuous) : Path(ellipseIn: innerBox)
                context.fill(outer, with: .color(.white))
                context.fill(inner, with: .color(Color(uiColor: Theme.rgb(badge == .ghost ? 0x46525E : 0x177A41))))
                if badge == .ghost {
                    context.draw(context.resolve(Text("?").font(.system(size: 10.5, weight: .heavy, design: .rounded)).foregroundStyle(.white)),
                                 at: CGPoint(x: 8, y: 8))
                } else {
                    var check = Path()
                    check.move(to: CGPoint(x: 4.8, y: 8.2)); check.addLine(to: CGPoint(x: 7, y: 10.4)); check.addLine(to: CGPoint(x: 11.3, y: 5.8))
                    context.stroke(check, with: .color(.white), style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: 16, height: 16)
        }
    }

    // MARK: Листы

    /// Дейтеранопия (Machado 2009, тяжесть 1.0) в линейном RGB.
    static func deutan(_ image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let filter = CIFilter(name: "CIColorMatrix")!
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 0.367322, y: 0.860646, z: -0.227968, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0.280085, y: 0.672501, z: 0.047413, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: -0.011820, y: 0.042940, z: 0.968881, w: 0), forKey: "inputBVector")
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: cg, scale: image.scale, orientation: .up)
    }

    static func dumpSheets(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for variant in CameraIconVariant.allCases {
            let strip = image(PathStrip(variant: variant), scale: 2)
            let deutanStrip = strip.flatMap(deutan)
            let sheet = VariantSheet(variant: variant, deutan: deutanStrip)
            guard let png = image(sheet, scale: 2)?.pngData() else {
                Log.network.error("29.C: лист \(variant.rawValue, privacy: .public) не отрисовался")
                continue
            }
            let url = directory.appendingPathComponent("sheet_\(variant.rawValue).png")
            do { try png.write(to: url) } catch {
                Log.network.error("29.C: не записан \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        Log.network.info("29.C: листы значков записаны в \(directory.path, privacy: .public)")
    }

    fileprivate static let dayMap = Color(uiColor: Theme.rgb(0xEEF1F4))
    fileprivate static let nightMap = Color(uiColor: Theme.rgb(0x1A1E24))
    fileprivate static let carPlayBG = Color(uiColor: Theme.rgb(0x1C1C1E))

    fileprivate static func name(_ kind: CameraType) -> String {
        switch kind {
        case .stationaryCamera: return "Стационарная камера"
        case .stationaryRadar:  return "Стационарный радар"
        case .intelligentRadar: return "Интеллект. + радар"
        case .mobileRadar:      return "Передвижной радар"
        case .tripod:           return "Тренога"
        case .dpsPost:          return "Пост ДПС"
        case .accident:         return "ДТП"
        case .other:            return "Прочее"
        }
    }

    private struct PathStrip: View {
        let variant: CameraIconVariant
        var body: some View {
            HStack(spacing: 14) {
                ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in
                    CameraIconView(kind: kind, tier: .path, night: false, variant: variant)
                }
            }
            .padding(10)
            .background(dayMap)
        }
    }

    private struct VariantSheet: View {
        let variant: CameraIconVariant
        let deutan: UIImage?

        private let columns: [(String, Bool)] = [
            ("Цель (тревога)", false), ("На пути", false), ("Фон", false), ("Бейджи", false),
            ("Цель", true), ("На пути", true), ("Фон", true), ("CarPlay 40", true),
        ]

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(variant.title).font(.system(size: 34, weight: .bold))
                    Text(variant.subtitle).font(.system(size: 16)).foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    Text("").frame(width: 190, alignment: .leading)
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        Text(column.0).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(column.1 ? Color.white : Color.black)
                            .frame(width: 104, height: 34)
                            .background(column.1 ? nightMap : dayMap)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in row(kind) }
                }
                HStack(alignment: .center, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Размеры (тревога 72 · карточка 46 · список 34 · полоса 24)").font(.system(size: 14, weight: .semibold))
                        HStack(alignment: .center, spacing: 18) {
                            ForEach([72.0, 46, 34, 24], id: \.self) { side in
                                CameraIconView(kind: .stationaryCamera, tier: .path, night: false, variant: variant, side: side)
                            }
                            ForEach([72.0, 46, 34, 24], id: \.self) { side in
                                CameraIconView(kind: .stationaryRadar, tier: .path, night: false, variant: variant, side: side)
                            }
                        }
                        .padding(12).background(dayMap)
                    }
                    if let deutan {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("«На пути» глазами дейтеранопа").font(.system(size: 14, weight: .semibold))
                            Image(uiImage: deutan)
                        }
                    }
                }
            }
            .padding(28)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        }

        private func row(_ kind: CameraType) -> some View {
            HStack(spacing: 0) {
                Text(name(kind)).font(.system(size: 15, weight: .medium)).frame(width: 190, alignment: .leading)
                cell(night: false) { CameraIconView(kind: kind, tier: .alert, night: false, variant: variant, halo: true) }
                cell(night: false) { CameraIconView(kind: kind, tier: .path, night: false, variant: variant) }
                cell(night: false) { CameraIconView(kind: kind, tier: .calm, night: false, variant: variant) }
                cell(night: false) {
                    HStack(spacing: 2) {
                        CameraIconView(kind: kind, tier: .path, night: false, variant: variant, badge: .ghost).opacity(0.6)
                        CameraIconView(kind: kind, tier: .calm, night: false, variant: variant, badge: .own)
                    }
                }
                cell(night: true) { CameraIconView(kind: kind, tier: .alert, night: true, variant: variant, halo: true) }
                cell(night: true) { CameraIconView(kind: kind, tier: .path, night: true, variant: variant) }
                cell(night: true) { CameraIconView(kind: kind, tier: .calm, night: true, variant: variant) }
                cell(night: true, background: carPlayBG) {
                    CameraIconView(kind: kind, tier: .path, night: true, variant: variant, side: 40)
                }
            }
        }

        private func cell(night: Bool, background: Color? = nil, @ViewBuilder _ content: () -> some View) -> some View {
            content()
                .frame(width: 104, height: 72)
                .background(background ?? (night ? nightMap : dayMap))
        }
    }
}
#endif
