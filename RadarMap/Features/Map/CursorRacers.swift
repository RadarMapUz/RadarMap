//
//  CursorRacers.swift
//  RadarMap
//
//  Гоночные значки «я»: болид, суперкар, ралли (владелец, 12.10: «значок
//  карты чуть круче — тачки крутые гоночные, разнообразие, и сама иконка
//  детализированная»).
//
//  Те же уговоры, что у машины и спорткара (шапка CursorVehicles.swift): вид
//  строго сверху носом вверх, свет слева, белая кайма, тень без сдвига, всё
//  статично. Отличие — детали: открытые колёса с протектором, крылья,
//  жалюзи, люстра фар. Ради них рамка гоночных крупнее
//  (CursorStyle.frameSize, 32×44): в рамке 30×36 колесо болида — два
//  пикселя.
//
//  Цвет каждого — свой, и ни один не красный: красный на этой карте —
//  камера и тревога (см. MapPalette).
//
//  Силуэт — по-прежнему правая половина и её зеркало (HalfOutline), парные
//  детали — зеркальной парой: CursorStyleTests проверяет симметрию по
//  пикселям, и значок с кривой половиной ездит боком.
//

import SwiftUI

// MARK: - Болид

/// Болид «Формулы»: узкий нос, переднее и заднее антикрылья, четыре открытых
/// колеса на рычагах подвески, понтоны, кокпит с жёлтым шлемом и дугой halo.
struct FormulaCursor: View {
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            FormulaShape(part: .suspension).stroke(MapPalette.carbon, lineWidth: 1.1 * scale)
            RacerTyres(shape: FormulaShape(part: .tyres), tread: FormulaShape(part: .tread), scale: scale)
            FormulaShape(part: .frontWing).fill(MapPalette.carbon)
            FormulaShape(part: .endplates).fill(MapPalette.formulaBody)
            FormulaShape(part: .frontWing).stroke(.white.opacity(0.85), lineWidth: 0.8 * scale)
            FormulaShape(part: .body).fill(LinearGradient(colors: [MapPalette.formulaTop,
                                                                   MapPalette.formulaBody],
                                                          startPoint: .top, endPoint: .bottom))
            FormulaShape(part: .body).fill(CursorLight.side)
            // Ливрея: белая полоса по носу, карбоновый хребет мотора и
            // чёрные входы понтонов — поверх кузова, внутри его контура.
            FormulaShape(part: .noseStripe).fill(.white.opacity(0.92))
                .clipShape(FormulaShape(part: .body))
            FormulaShape(part: .spine).fill(MapPalette.carbon)
                .clipShape(FormulaShape(part: .body))
            FormulaShape(part: .inlets).fill(MapPalette.carbon)
            FormulaShape(part: .cockpit).fill(MapPalette.carbon)
            FormulaShape(part: .helmet).fill(MapPalette.helmet)
            FormulaShape(part: .visor).fill(MapPalette.glass)
            FormulaShape(part: .halo).stroke(MapPalette.carbon,
                                             style: StrokeStyle(lineWidth: 1.2 * scale, lineCap: .round))
            FormulaShape(part: .body).stroke(.white.opacity(0.9), lineWidth: 1.1 * scale)
            FormulaShape(part: .rearWing).fill(MapPalette.carbon)
            FormulaShape(part: .rearFlap).fill(MapPalette.formulaBody)
            FormulaShape(part: .rearWing).stroke(.white.opacity(0.85), lineWidth: 0.8 * scale)
        }
        .compositingGroup()
        .modifier(CursorShadow(glow: MapPalette.formulaBody, scale: scale))
    }
}

private struct FormulaShape: Shape {
    enum Part {
        case body, noseStripe, spine, inlets, cockpit, helmet, visor, halo
        case frontWing, endplates, rearWing, rearFlap, tyres, tread, suspension
    }
    let part: Part

    /// Ширина по колёсам и крыльям к длине.
    private static let aspect: CGFloat = 0.64

    func path(in rect: CGRect) -> Path {
        let box = CursorBox(in: rect, aspect: Self.aspect)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        switch part {
        case .body:
            // Нос → кокпит → понтоны → «бутылка» к коробке передач.
            return HalfOutline(start: p(0.5, 0.05), curves: [
                .init(p(0.545, 0.12), p(0.525, 0.05), p(0.54, 0.08)),
                .init(p(0.565, 0.30), p(0.55, 0.18), p(0.56, 0.25)),
                .init(p(0.70, 0.42), p(0.60, 0.34), p(0.69, 0.36)),
                .init(p(0.72, 0.62), p(0.735, 0.48), p(0.735, 0.56)),
                .init(p(0.585, 0.86), p(0.70, 0.72), p(0.61, 0.80)),
                .init(p(0.50, 0.88), p(0.565, 0.88), p(0.53, 0.88)),
            ]).path(in: box)
        case .noseStripe:
            return RacerPath.rect(box, p(0.485, 0.04), p(0.515, 0.34), radius: 0)
        case .spine:
            return RacerPath.rect(box, p(0.465, 0.50), p(0.535, 0.88), radius: 0.02)
        case .inlets:
            // Входы понтонов — косые щели: круглые читались глазами.
            return RacerPath.mirroredPolygon(box, [p(0.60, 0.375), p(0.70, 0.415), p(0.705, 0.45), p(0.615, 0.415)])
        case .cockpit:
            return Path(ellipseIn: box.rect(p(0.44, 0.34), p(0.56, 0.49)))
        case .helmet:
            return Path(ellipseIn: box.rect(p(0.462, 0.375), p(0.538, 0.45)))
        case .visor:
            return RacerPath.rect(box, p(0.47, 0.378), p(0.53, 0.398), radius: 0.01)
        case .halo:
            // Дуга вокруг кокпита спереди и стойка на оси.
            var path = Path()
            path.move(to: box(p(0.435, 0.47)))
            path.addCurve(to: box(p(0.5, 0.335)), control1: box(p(0.425, 0.39)),
                          control2: box(p(0.46, 0.335)))
            path.addCurve(to: box(p(0.565, 0.47)), control1: box(p(0.54, 0.335)),
                          control2: box(p(0.575, 0.39)))
            path.move(to: box(p(0.5, 0.335)))
            path.addLine(to: box(p(0.5, 0.305)))
            return path
        case .frontWing:
            return RacerPath.rect(box, p(0.03, 0.035), p(0.97, 0.085), radius: 0.02)
        case .endplates:
            return RacerPath.mirroredRect(box, p(0.03, 0.025), p(0.085, 0.105), radius: 0.015)
        case .rearWing:
            return RacerPath.rect(box, p(0.12, 0.885), p(0.88, 0.96), radius: 0.02)
        case .rearFlap:
            return RacerPath.rect(box, p(0.12, 0.885), p(0.88, 0.905), radius: 0.01)
        case .tyres:
            return RacerPath.mirroredRect(box, p(0.02, 0.13), p(0.20, 0.29), radius: 0.05)
                + RacerPath.mirroredRect(box, p(0.0, 0.64), p(0.22, 0.84), radius: 0.05)
        case .tread:
            // Протектор — светлая середина шины: колесо, а не чёрный брусок.
            return RacerPath.mirroredRect(box, p(0.07, 0.155), p(0.15, 0.265), radius: 0.03)
                + RacerPath.mirroredRect(box, p(0.055, 0.665), p(0.165, 0.815), radius: 0.03)
        case .suspension:
            return RacerPath.mirroredLines(box, [
                (p(0.20, 0.18), p(0.45, 0.17)), (p(0.20, 0.25), p(0.45, 0.28)),
                (p(0.22, 0.70), p(0.62, 0.66)), (p(0.22, 0.79), p(0.58, 0.80)),
            ])
        }
    }
}

// MARK: - Суперкар

/// Суперкар-клин: острый нос, кабина сдвинута вперёд, воздухозаборники в
/// талии, жалюзи над мотором, щелевые фары. Лайм — цвет, которого на карте
/// больше нет ни у чего.
struct SupercarCursor: View {
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            RacerTyres(shape: SupercarShape(part: .tyres), tread: SupercarShape(part: .tread), scale: scale)
            SupercarShape(part: .body).fill(LinearGradient(colors: [MapPalette.limeTop,
                                                                    MapPalette.limeBody],
                                                           startPoint: .top, endPoint: .bottom))
            SupercarShape(part: .body).fill(CursorLight.side)
            SupercarShape(part: .creases).stroke(MapPalette.limeBase.opacity(0.7), lineWidth: 0.7 * scale)
            SupercarShape(part: .intakes).fill(MapPalette.carbon)
            SupercarShape(part: .glass).fill(CursorLight.glass)
            SupercarShape(part: .roof).fill(LinearGradient(colors: [MapPalette.limeTop,
                                                                    MapPalette.limeBody],
                                                           startPoint: .leading, endPoint: .trailing))
            SupercarShape(part: .roof).fill(CursorLight.side)
            SupercarShape(part: .louvres).stroke(MapPalette.carbon,
                                                 style: StrokeStyle(lineWidth: 1.0 * scale, lineCap: .round))
            SupercarShape(part: .headlights).fill(MapPalette.headlight)
            SupercarShape(part: .diffuser).fill(MapPalette.carbon)
            SupercarShape(part: .taillights).fill(MapPalette.taillight)
            SupercarShape(part: .body).stroke(.white.opacity(0.9), lineWidth: 1.1 * scale)
        }
        .compositingGroup()
        .modifier(CursorShadow(glow: MapPalette.limeBody, scale: scale))
    }
}

private struct SupercarShape: Shape {
    enum Part {
        case body, creases, intakes, glass, roof, louvres, headlights, taillights, diffuser, tyres, tread
    }
    let part: Part

    /// Ниже и длиннее ралли: клин узнают по пропорции раньше, чем по цвету.
    private static let aspect: CGFloat = 0.52
    /// Доля ширины под шины, выступающие из арок.
    private static let inset: CGFloat = 0.06

    func path(in rect: CGRect) -> Path {
        let box = CursorBox(in: rect, aspect: Self.aspect)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        func b(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: Self.inset + u * (1 - 2 * Self.inset), y: v)
        }
        switch part {
        case .body:
            // Почти прямые грани: клин читается углами, а не округлостью.
            // Острый узкий нос, талия с заборниками, широкие задние «бёдра».
            return HalfOutline(start: b(0.5, 0), curves: [
                .init(b(0.70, 0.02), b(0.58, 0.0), b(0.66, 0.005)),
                .init(b(0.90, 0.14), b(0.80, 0.05), b(0.88, 0.09)),
                .init(b(0.97, 0.30), b(0.93, 0.20), b(0.97, 0.25)),
                .init(b(0.89, 0.44), b(0.97, 0.36), b(0.90, 0.40)),
                .init(b(1.00, 0.64), b(0.89, 0.50), b(1.00, 0.56)),
                .init(b(0.98, 0.90), b(1.00, 0.76), b(1.00, 0.84)),
                .init(b(0.84, 0.995), b(0.96, 0.96), b(0.90, 0.99)),
                .init(b(0.50, 1.00), b(0.72, 1.00), b(0.60, 1.00)),
            ]).path(in: box)
        case .creases:
            return RacerPath.mirroredLines(box, [(b(0.40, 0.06), b(0.40, 0.26))])
        case .intakes:
            return RacerPath.mirroredPolygon(box, [b(0.89, 0.42), b(0.75, 0.50), b(0.97, 0.61)])
        case .glass:
            // Каплевидная кабина: большое лобовое спереди, тонкие боковые.
            return HalfOutline(start: b(0.5, 0.27), curves: [
                .init(b(0.73, 0.34), b(0.62, 0.27), b(0.71, 0.30)),
                .init(b(0.72, 0.56), b(0.76, 0.42), b(0.76, 0.50)),
                .init(b(0.50, 0.66), b(0.66, 0.62), b(0.58, 0.66)),
            ]).path(in: box)
        case .roof:
            // Крыша — узкая и ближе к корме: лобовое читается стеклом, а не
            // тёмным кольцом вокруг крыши.
            return HalfOutline(start: b(0.5, 0.41), curves: [
                .init(b(0.64, 0.43), b(0.58, 0.41), b(0.63, 0.415)),
                .init(b(0.65, 0.555), b(0.66, 0.47), b(0.66, 0.53)),
                .init(b(0.50, 0.59), b(0.62, 0.58), b(0.56, 0.59)),
            ]).path(in: box)
        case .louvres:
            var path = Path()
            for v in stride(from: 0.71, through: 0.85, by: 0.035) {
                path.move(to: box(b(0.37, v)))
                path.addLine(to: box(b(0.63, v)))
            }
            return path
        case .headlights:
            return RacerPath.mirroredPolygon(box, [b(0.24, 0.07), b(0.40, 0.03), b(0.42, 0.055), b(0.28, 0.10)])
        case .taillights:
            return RacerPath.rect(box, b(0.14, 0.952), b(0.86, 0.972), radius: 0.01)
        case .diffuser:
            return RacerPath.rect(box, b(0.30, 0.975), b(0.70, 0.998), radius: 0.01)
        case .tyres:
            return RacerPath.mirroredRect(box, p(0.02, 0.18), p(0.13, 0.31), radius: 0.04)
                + RacerPath.mirroredRect(box, p(0.0, 0.63), p(0.12, 0.81), radius: 0.04)
        case .tread:
            return RacerPath.mirroredRect(box, p(0.04, 0.20), p(0.07, 0.29), radius: 0.02)
                + RacerPath.mirroredRect(box, p(0.02, 0.65), p(0.055, 0.79), radius: 0.02)
        }
    }
}

// MARK: - Ралли

/// Раллийный хэтчбек: расширенные арки, люстра из четырёх фар на капоте,
/// заборник на крыше, номерной круг, большое антикрыло и брызговики.
/// Синий с белой крышей и золотыми полосами — «я» остаётся синим.
struct RallyCursor: View {
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            RacerTyres(shape: RallyShape(part: .tyres), tread: RallyShape(part: .tread), scale: scale)
            RallyShape(part: .mudflaps).fill(MapPalette.carbon)
            RallyShape(part: .body).fill(LinearGradient(colors: [MapPalette.rallyTop,
                                                                 MapPalette.rallyBody],
                                                        startPoint: .top, endPoint: .bottom))
            RallyShape(part: .body).fill(CursorLight.side)
            RallyShape(part: .stripes).fill(MapPalette.rallyGold)
                .clipShape(RallyShape(part: .body))
            RallyShape(part: .glass).fill(CursorLight.glass)
            RallyShape(part: .roof).fill(MapPalette.rallyRoof)
            RallyShape(part: .roof).fill(CursorLight.side)
            RallyShape(part: .roofScoop).fill(MapPalette.carbon)
            RallyShape(part: .roundel).fill(MapPalette.rallyBody)
            RallyShape(part: .roundel).stroke(MapPalette.rallyGold, lineWidth: 0.8 * scale)
            RallyShape(part: .hoodScoop).fill(MapPalette.carbon)
            RallyShape(part: .lightBar).fill(MapPalette.carbon)
            RallyShape(part: .lights).fill(MapPalette.spotlight)
            RallyShape(part: .lightCores).fill(.white)
            RallyShape(part: .body).stroke(.white.opacity(0.9), lineWidth: 1.1 * scale)
            RallyShape(part: .wing).fill(MapPalette.carbon)
            RallyShape(part: .wing).stroke(.white.opacity(0.85), lineWidth: 0.8 * scale)
            RallyShape(part: .taillights).fill(MapPalette.taillight)
        }
        .compositingGroup()
        .modifier(CursorShadow(glow: MapPalette.rallyBody, scale: scale))
    }
}

private struct RallyShape: Shape {
    enum Part {
        case body, stripes, glass, roof, roofScoop, roundel, hoodScoop, lightBar, lights, lightCores
        case wing, taillights, mudflaps, tyres, tread
    }
    let part: Part

    private static let aspect: CGFloat = 0.56
    private static let inset: CGFloat = 0.06

    func path(in rect: CGRect) -> Path {
        let box = CursorBox(in: rect, aspect: Self.aspect)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        func b(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: Self.inset + u * (1 - 2 * Self.inset), y: v)
        }
        switch part {
        case .body:
            return HalfOutline(start: b(0.5, 0), curves: [
                .init(b(0.86, 0.02), b(0.68, 0.0), b(0.80, 0.005)),
                .init(b(0.98, 0.12), b(0.94, 0.04), b(0.975, 0.08)),
                .init(b(1.00, 0.30), b(0.99, 0.17), b(1.00, 0.24)),   // передняя арка
                .init(b(0.95, 0.42), b(1.00, 0.36), b(0.95, 0.39)),
                .init(b(0.96, 0.60), b(0.95, 0.48), b(0.95, 0.55)),
                .init(b(1.00, 0.74), b(0.98, 0.64), b(1.00, 0.69)),   // задняя арка
                .init(b(0.95, 0.95), b(1.00, 0.84), b(0.99, 0.91)),
                .init(b(0.50, 1.00), b(0.85, 0.995), b(0.65, 1.00)),
            ]).path(in: box)
        case .stripes:
            return RacerPath.mirroredRect(box, b(0.39, 0), b(0.44, 1), radius: 0)
        case .glass:
            return HalfOutline(start: b(0.5, 0.27), curves: [
                .init(b(0.85, 0.31), b(0.68, 0.27), b(0.82, 0.28)),
                .init(b(0.86, 0.80), b(0.88, 0.45), b(0.88, 0.66)),
                .init(b(0.50, 0.84), b(0.82, 0.83), b(0.66, 0.84)),
            ]).path(in: box)
        case .roof:
            return HalfOutline(start: b(0.5, 0.37), curves: [
                .init(b(0.80, 0.39), b(0.66, 0.37), b(0.78, 0.375)),
                .init(b(0.80, 0.76), b(0.82, 0.50), b(0.82, 0.66)),
                .init(b(0.50, 0.78), b(0.76, 0.775), b(0.64, 0.78)),
            ]).path(in: box)
        case .roofScoop:
            return RacerPath.rect(box, b(0.42, 0.39), b(0.58, 0.45), radius: 0.02)
        case .roundel:
            // Круг в точках, а не в долях: коробка не квадратная.
            let centre = box(b(0.5, 0.59))
            let radius = box.size.width * 0.11
            return Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                          width: radius * 2, height: radius * 2))
        case .hoodScoop:
            return RacerPath.rect(box, b(0.43, 0.17), b(0.57, 0.22), radius: 0.02)
        case .lightBar:
            return RacerPath.rect(box, b(0.17, 0.068), b(0.83, 0.122), radius: 0.03)
        case .lights, .lightCores:
            // Четыре круглые фары люстры, тоже в точках.
            let core = part == .lightCores
            var path = Path()
            for u in [0.26, 0.42, 0.58, 0.74] as [CGFloat] {
                let centre = box(b(u, 0.095))
                let radius = box.size.width * (core ? 0.025 : 0.055)
                path.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                           width: radius * 2, height: radius * 2))
            }
            return path
        case .wing:
            return RacerPath.rect(box, b(0.0, 0.875), b(1.0, 0.925), radius: 0.02)
        case .taillights:
            return RacerPath.mirroredRect(box, b(0.10, 0.955), b(0.26, 0.978), radius: 0.01)
        case .mudflaps:
            return RacerPath.mirroredRect(box, p(0.04, 0.80), p(0.13, 0.845), radius: 0.01)
        case .tyres:
            return RacerPath.mirroredRect(box, p(0.0, 0.14), p(0.12, 0.28), radius: 0.04)
                + RacerPath.mirroredRect(box, p(0.0, 0.64), p(0.12, 0.79), radius: 0.04)
        case .tread:
            return RacerPath.mirroredRect(box, p(0.02, 0.16), p(0.06, 0.26), radius: 0.02)
                + RacerPath.mirroredRect(box, p(0.02, 0.66), p(0.06, 0.77), radius: 0.02)
        }
    }
}

// MARK: - Общее

/// Шины: чёрные, с белой каймой поверх тёмной карты и светлым протектором.
private struct RacerTyres<S: Shape, T: Shape>: View {
    let shape: S
    let tread: T
    let scale: CGFloat

    var body: some View {
        ZStack {
            shape.fill(MapPalette.tyre)
            tread.fill(MapPalette.tyreTread.opacity(0.6))
            shape.stroke(.white.opacity(0.55), lineWidth: 0.6 * scale)
        }
    }
}

/// Пути из долей коробки — прямоугольники, многоугольники и линии, парные
/// детали зеркалом относительно оси (как CursorBox.pair).
private enum RacerPath {
    static func mirror(_ point: CGPoint) -> CGPoint { CGPoint(x: 1 - point.x, y: point.y) }

    /// Прямоугольник по двум углам; `radius` — доля ширины коробки.
    static func rect(_ box: CursorBox, _ from: CGPoint, _ to: CGPoint, radius: CGFloat) -> Path {
        let frame = box.rect(from, to)
        let corner = min(box.size.width * radius, frame.width / 2, frame.height / 2)
        return Path(roundedRect: frame, cornerSize: CGSize(width: corner, height: corner))
    }

    static func mirroredRect(_ box: CursorBox, _ from: CGPoint, _ to: CGPoint, radius: CGFloat) -> Path {
        var path = rect(box, from, to, radius: radius)
        path.addPath(rect(box, mirror(from), mirror(to), radius: radius))
        return path
    }

    static func mirroredPolygon(_ box: CursorBox, _ points: [CGPoint]) -> Path {
        var path = Path()
        for side in [points, points.map(mirror)] {
            guard let first = side.first else { continue }
            path.move(to: box(first))
            for point in side.dropFirst() { path.addLine(to: box(point)) }
            path.closeSubpath()
        }
        return path
    }

    static func mirroredLines(_ box: CursorBox, _ lines: [(CGPoint, CGPoint)]) -> Path {
        var path = Path()
        for (a, b) in lines {
            path.move(to: box(a)); path.addLine(to: box(b))
            path.move(to: box(mirror(a))); path.addLine(to: box(mirror(b)))
        }
        return path
    }
}

private extension Path {
    static func + (lhs: Path, rhs: Path) -> Path {
        var path = lhs
        path.addPath(rhs)
        return path
    }
}
