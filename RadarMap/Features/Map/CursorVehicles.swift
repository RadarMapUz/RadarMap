//
//  CursorVehicles.swift
//  RadarMap
//
//  Выбираемые значки «я»: машина, спорткар, звездолёт. Вид строго сверху,
//  нос вверх — тот же уговор, что у стрелки, поэтому вращение по курсу во
//  всех трёх рендерах работает без поправок.
//
//  Правила рисования, общие для всех значков, — те же, что у стрелки:
//  • объём — тремя тонами одного цвета и боковым светом слева, а не
//    рисованной перспективой;
//  • белая кайма — она, а не цвет кузова, держит значок на светлой и на
//    тёмной карте;
//  • тень — мягкая и БЕЗ сдвига: в движке значок вращается вместе с картой,
//    и тень, отнесённая «вниз», ездила бы вокруг машины вслед за курсом;
//  • всё статично: ни одной анимации и ни одного пересчёта на тик — значок
//    живёт на экране всю поездку.
//
//  Геометрия — в долях «коробки» значка с СОБСТВЕННЫМ соотношением сторон:
//  рамка у всех курсоров одна (её задаёт рендер), а машина, вписанная в неё
//  растяжением, превратилась бы в бочку. Силуэт задаётся правой половиной,
//  левая — её зеркало: две руками написанные половины расходятся на
//  полпикселя, и машина едет боком.
//

import SwiftUI

// MARK: - Машина

/// Легковая машина: синяя, как стрелка, — «я» на этой карте синий, и смена
/// значка не должна менять цвет, по которому себя ищут взглядом.
struct CarCursor: View {
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            // Зеркала — под кузовом: кайма кузова перекрывает их корень, и
            // они читаются выступами, а не наклейками.
            CarShape(part: .mirrors).fill(SketchPalette.meBase)
            CarShape(part: .mirrors).stroke(.white.opacity(0.85), lineWidth: 0.9 * scale)
            CarShape(part: .body).fill(LinearGradient(colors: [SketchPalette.meTop,
                                                               SketchPalette.meBody],
                                                      startPoint: .top, endPoint: .bottom))
            CarShape(part: .body).fill(CursorLight.side)
            CarShape(part: .glass).fill(CursorLight.glass)
            // Крыша светлее капота: так кабина поднимается над кузовом.
            CarShape(part: .roof).fill(LinearGradient(colors: [SketchPalette.meTop,
                                                               SketchPalette.meBody],
                                                      startPoint: .leading, endPoint: .trailing))
            CarShape(part: .roof).fill(CursorLight.side)
            CarShape(part: .headlights).fill(SketchPalette.headlight)
            CarShape(part: .taillights).fill(SketchPalette.taillight)
            CarShape(part: .body).stroke(.white.opacity(0.9), lineWidth: 1.2 * scale)
        }
        .compositingGroup()
        .modifier(CursorShadow(glow: SketchPalette.meBody, scale: scale))
    }
}

/// Части машины. Одна фигура на все части, чтобы все они вписывались в ОДНУ
/// коробку и не разъезжались между собой ни в какой рамке.
private struct CarShape: Shape {
    enum Part { case body, glass, roof, mirrors, headlights, taillights }
    let part: Part

    /// Ширина к длине вместе с зеркалами. Кузов — 0,46: живая машина уже
    /// (0,39), но на тридцати пунктах честная пропорция читается карандашом.
    private static let aspect: CGFloat = 0.535
    /// Доля ширины коробки под зеркала с каждой стороны.
    private static let inset: CGFloat = 0.07

    func path(in rect: CGRect) -> Path {
        let box = CursorBox(in: rect, aspect: Self.aspect)
        // Координаты кузова: u — поперёк кузова (0…1 без зеркал), v — вдоль.
        func b(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: Self.inset + u * (1 - 2 * Self.inset), y: v)
        }
        switch part {
        case .body:
            return HalfOutline(start: b(0.5, 0), curves: [
                .init(b(0.96, 0.09), b(0.80, 0), b(0.94, 0.02)),       // скула бампера
                .init(b(1.00, 0.27), b(0.985, 0.14), b(1.00, 0.20)),   // переднее крыло
                .init(b(1.00, 0.80), b(0.985, 0.46), b(0.985, 0.64)),  // борт
                .init(b(0.93, 0.975), b(1.00, 0.90), b(0.975, 0.955)), // заднее крыло
                .init(b(0.50, 1.00), b(0.80, 1.00), b(0.64, 1.00)),    // бампер
            ]).path(in: box)
        case .glass:
            // Остекление целиком: лобовое, заднее и тонкие боковые — их
            // оставляет крыша, положенная сверху.
            return HalfOutline(start: b(0.5, 0.285), curves: [
                .init(b(0.87, 0.325), b(0.68, 0.285), b(0.82, 0.30)),
                .init(b(0.85, 0.79), b(0.885, 0.48), b(0.87, 0.66)),
                .init(b(0.50, 0.815), b(0.80, 0.81), b(0.65, 0.815)),
            ]).path(in: box)
        case .roof:
            return HalfOutline(start: b(0.5, 0.425), curves: [
                .init(b(0.80, 0.46), b(0.68, 0.425), b(0.79, 0.435)),
                .init(b(0.80, 0.67), b(0.815, 0.53), b(0.815, 0.61)),
                .init(b(0.50, 0.695), b(0.79, 0.69), b(0.66, 0.695)),
            ]).path(in: box)
        case .mirrors:
            return box.pair(CGRect(x: 0, y: 0.300, width: 0.13, height: 0.05))
        case .headlights:
            return box.pair(CGRect(x: b(0.10, 0).x, y: 0.025, width: 0.22, height: 0.045))
        case .taillights:
            return box.pair(CGRect(x: b(0.11, 0).x, y: 0.953, width: 0.20, height: 0.03))
        }
    }
}

// MARK: - Спорткар

/// Спорткар: ниже и шире машины, с узким носом, «осиной» талией, широкими
/// задними крыльями, полосами и антикрылом. Отличается силуэтом раньше, чем
/// цветом: значок узнают с полувзгляда, а цвет на солнце блёкнет первым.
struct SportCursor: View {
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            SportShape(part: .mirrors).fill(SketchPalette.sportBase)
            SportShape(part: .mirrors).stroke(.white.opacity(0.85), lineWidth: 0.9 * scale)
            SportShape(part: .body).fill(LinearGradient(colors: [SketchPalette.sportTop,
                                                                 SketchPalette.sportBody],
                                                        startPoint: .top, endPoint: .bottom))
            SportShape(part: .body).fill(CursorLight.side)
            // Полосы идут через капот, крышу и крышку мотора — поверх кузова,
            // но под стеклом: стекло полос не несёт.
            SportShape(part: .stripes).fill(.white.opacity(0.92))
                .clipShape(SportShape(part: .body))
            SportShape(part: .glass).fill(CursorLight.glass)
            SportShape(part: .roof).fill(LinearGradient(colors: [SketchPalette.sportTop,
                                                                 SketchPalette.sportBody],
                                                        startPoint: .leading, endPoint: .trailing))
            SportShape(part: .stripes).fill(.white.opacity(0.92))
                .clipShape(SportShape(part: .roof))
            SportShape(part: .roof).fill(CursorLight.side)
            SportShape(part: .headlights).fill(SketchPalette.headlight)
            SportShape(part: .taillights).fill(SketchPalette.taillight)
            SportShape(part: .wing).fill(SketchPalette.carbon)
            SportShape(part: .body).stroke(.white.opacity(0.9), lineWidth: 1.2 * scale)
        }
        .compositingGroup()
        .modifier(CursorShadow(glow: SketchPalette.sportBody, scale: scale))
    }
}

private struct SportShape: Shape {
    enum Part { case body, glass, roof, stripes, wing, mirrors, headlights, taillights }
    let part: Part

    /// Шире машины: кузов 0,54 к длине — приземистость сверху видна только
    /// шириной.
    private static let aspect: CGFloat = 0.60
    private static let inset: CGFloat = 0.05

    func path(in rect: CGRect) -> Path {
        let box = CursorBox(in: rect, aspect: Self.aspect)
        func b(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: Self.inset + u * (1 - 2 * Self.inset), y: v)
        }
        switch part {
        case .body:
            return HalfOutline(start: b(0.5, 0), curves: [
                .init(b(0.80, 0.035), b(0.66, 0), b(0.75, 0.01)),     // узкий нос
                .init(b(0.97, 0.21), b(0.90, 0.07), b(0.975, 0.13)),  // переднее крыло
                .init(b(0.89, 0.50), b(0.965, 0.31), b(0.89, 0.40)),  // талия
                .init(b(1.00, 0.77), b(0.89, 0.62), b(1.00, 0.66)),   // заднее крыло
                .init(b(0.95, 0.975), b(1.00, 0.88), b(0.985, 0.955)),
                .init(b(0.50, 1.00), b(0.84, 0.995), b(0.66, 1.00)),
            ]).path(in: box)
        case .glass:
            // Кабина сдвинута назад: длинный капот — первое, что говорит
            // «спорткар» на виде сверху.
            return HalfOutline(start: b(0.5, 0.34), curves: [
                .init(b(0.80, 0.45), b(0.68, 0.34), b(0.79, 0.38)),
                .init(b(0.74, 0.74), b(0.81, 0.56), b(0.79, 0.69)),
                .init(b(0.50, 0.76), b(0.69, 0.755), b(0.58, 0.76)),
            ]).path(in: box)
        case .roof:
            // Крыша почти во всю кабину: маленькая крыша в большом стекле
            // читалась шлемом в тёмном кольце, а не машиной.
            return HalfOutline(start: b(0.5, 0.47), curves: [
                .init(b(0.74, 0.51), b(0.64, 0.47), b(0.73, 0.48)),
                .init(b(0.71, 0.67), b(0.755, 0.57), b(0.745, 0.64)),
                .init(b(0.50, 0.685), b(0.67, 0.685), b(0.58, 0.685)),
            ]).path(in: box)
        case .stripes:
            return box.pair(CGRect(x: b(0.385, 0).x, y: 0, width: 0.07 * (1 - 2 * Self.inset),
                                   height: 1))
        case .wing:
            var path = Path()
            path.addRoundedRect(in: box.rect(b(0.03, 0.895), b(0.97, 0.945)),
                                cornerSize: CGSize(width: box.size.width * 0.03,
                                                   height: box.size.width * 0.03))
            return path
        case .mirrors:
            return box.pair(CGRect(x: 0, y: 0.355, width: 0.10, height: 0.04))
        case .headlights:
            return box.pair(CGRect(x: b(0.17, 0).x, y: 0.035, width: 0.19, height: 0.035))
        case .taillights:
            var path = Path()
            path.addRoundedRect(in: box.rect(b(0.16, 0.962), b(0.84, 0.982)),
                                cornerSize: CGSize(width: 1, height: 1))
            return path
        }
    }
}

// MARK: - Звездолёт

/// Звездолёт: светлый фюзеляж, синие стреловидные крылья, тёмный фонарь
/// кабины и маленькое пламя из сопла. Крылья синие не случайно: «я» на
/// карте синий, и даже шуточный значок остаётся своим по цвету.
///
/// Пламя статичное. Мерцание просится само, но значок живёт на экране всю
/// поездку, и непрерывная анимация ради шутки — это батарея, а не шутка.
struct SpaceshipCursor: View {
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            // Ореол пламени: размытая копия под ним — свет, а не мазок.
            ShipShape(part: .flame).fill(SketchPalette.flameTail.opacity(0.75))
                .blur(radius: 2 * scale)
            ShipShape(part: .flame).fill(LinearGradient(stops: [
                .init(color: SketchPalette.flameCore, location: 0),
                .init(color: SketchPalette.flameMid, location: 0.45),
                .init(color: SketchPalette.flameTail.opacity(0.85), location: 1),
            ], startPoint: .top, endPoint: .bottom))
            ShipShape(part: .wings).fill(LinearGradient(colors: [SketchPalette.meTop,
                                                                 SketchPalette.meBody,
                                                                 SketchPalette.meBase],
                                                        startPoint: .top, endPoint: .bottom))
            ShipShape(part: .wings).fill(CursorLight.side)
            ShipShape(part: .wings).stroke(.white.opacity(0.9), lineWidth: 1.1 * scale)
            ShipShape(part: .nozzle).fill(SketchPalette.nozzle)
            ShipShape(part: .hull).fill(LinearGradient(colors: [SketchPalette.hullTop,
                                                                SketchPalette.hullBody,
                                                                SketchPalette.hullBase],
                                                       startPoint: .leading, endPoint: .trailing))
            // Светлый фюзеляж на белой кайме не отделился бы от крыльев и от
            // дневной карты — его обводит тонкая тёмная линия поверх каймы.
            ShipShape(part: .hull).stroke(.white.opacity(0.9), lineWidth: 1.1 * scale)
            ShipShape(part: .hull).stroke(SketchPalette.hullBase, lineWidth: 0.5 * scale)
            ShipShape(part: .canopy).fill(CursorLight.glass)
            ShipShape(part: .glint).fill(.white.opacity(0.75))
        }
        .compositingGroup()
        .modifier(CursorShadow(glow: SketchPalette.meBody, scale: scale))
    }
}

private struct ShipShape: Shape {
    enum Part { case hull, wings, canopy, glint, nozzle, flame }
    let part: Part

    /// Почти квадрат: размах крыльев — вся ширина, длина вместе с пламенем.
    private static let aspect: CGFloat = 0.86

    func path(in rect: CGRect) -> Path {
        let box = CursorBox(in: rect, aspect: Self.aspect)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        switch part {
        case .hull:
            return HalfOutline(start: p(0.5, 0), curves: [
                .init(p(0.59, 0.20), p(0.548, 0.04), p(0.585, 0.11)),  // нос
                .init(p(0.615, 0.60), p(0.605, 0.33), p(0.615, 0.48)),
                .init(p(0.575, 0.79), p(0.615, 0.70), p(0.60, 0.76)),
                .init(p(0.50, 0.81), p(0.555, 0.805), p(0.53, 0.81)),
            ]).path(in: box)
        case .wings:
            // Стреловидное крыло: передняя кромка чуть выпуклая, задняя —
            // с изломом к фюзеляжу, концы скруглены.
            return HalfOutline(start: p(0.5, 0.31), curves: [
                .init(p(0.955, 0.685), p(0.68, 0.38), p(0.88, 0.57)),
                .init(p(0.955, 0.785), p(0.99, 0.715), p(0.99, 0.77)),
                .init(p(0.66, 0.745), p(0.86, 0.77), p(0.74, 0.745)),
                .init(p(0.50, 0.79), p(0.60, 0.745), p(0.55, 0.79)),
            ]).path(in: box)
        case .canopy:
            return Path(ellipseIn: box.rect(p(0.452, 0.16), p(0.548, 0.36)))
        case .glint:
            // Блик на фонаре — слева сверху, откуда падает весь свет значков.
            return Path(ellipseIn: box.rect(p(0.468, 0.185), p(0.50, 0.255)))
        case .nozzle:
            var path = Path()
            path.addRoundedRect(in: box.rect(p(0.44, 0.78), p(0.56, 0.845)),
                                cornerSize: CGSize(width: 1, height: 1))
            return path
        case .flame:
            return HalfOutline(start: p(0.5, 0.82), curves: [
                .init(p(0.565, 0.865), p(0.54, 0.82), p(0.565, 0.84)),
                .init(p(0.50, 1.00), p(0.565, 0.915), p(0.525, 0.965)),
            ]).path(in: box)
        }
    }
}

// MARK: - Общее

/// Свет и стекло, одинаковые у всех значков: свет падает слева — как у
/// стрелки, — и значки, поставленные рядом в настройках, освещены одним
/// солнцем.
private enum CursorLight {
    static let side = LinearGradient(stops: [
        .init(color: .white.opacity(0.32), location: 0),
        .init(color: .white.opacity(0.04), location: 0.45),
        .init(color: .black.opacity(0.26), location: 1),
    ], startPoint: .leading, endPoint: .trailing)

    static let glass = LinearGradient(colors: [SketchPalette.glassTop, SketchPalette.glass],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Тень значка: тёмная и короткая — посадка на полотно и отделение от
/// светлой карты; цветная и широкая — тот же ореол «я», что у стрелки. Обе
/// без сдвига (см. шапку файла).
private struct CursorShadow: ViewModifier {
    let glow: Color
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(0.5), radius: 2 * scale)
            .shadow(color: glow.opacity(0.35), radius: 5 * scale)
    }
}

/// Коробка значка в рамке: доли (0…1) → точки. Вписывается по центру с
/// заданным соотношением сторон, так что значок не тянется вслед за рамкой.
private struct CursorBox {
    let origin: CGPoint
    let size: CGSize

    nonisolated init(in frame: CGRect, aspect: CGFloat) {
        let height = min(frame.height, frame.width / aspect)
        size = CGSize(width: height * aspect, height: height)
        origin = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - height / 2)
    }

    nonisolated func callAsFunction(_ point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x * size.width, y: origin.y + point.y * size.height)
    }

    /// Прямоугольник по двум углам в долях.
    nonisolated func rect(_ from: CGPoint, _ to: CGPoint) -> CGRect {
        let a = self(from), b = self(to)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Пара овалов: левый по рамке в долях и его зеркало справа (фары,
    /// зеркала, полосы — всё парное у значков симметрично).
    nonisolated func pair(_ left: CGRect) -> Path {
        let right = CGRect(x: 1 - left.maxX, y: left.minY, width: left.width, height: left.height)
        var path = Path()
        for part in [left, right] {
            let frame = rect(CGPoint(x: part.minX, y: part.minY),
                             CGPoint(x: part.maxX, y: part.maxY))
            path.addRoundedRect(in: frame, cornerSize: CGSize(width: min(frame.width, frame.height) / 2,
                                                             height: min(frame.width, frame.height) / 2))
        }
        return path
    }
}

/// Симметричный силуэт: правая половина кривыми Безье от носа (точка на оси)
/// к корме (снова на оси), левая — её зеркало, пройденное обратно.
private struct HalfOutline {
    struct Curve {
        let to: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        nonisolated init(_ to: CGPoint, _ control1: CGPoint, _ control2: CGPoint) {
            self.to = to
            self.control1 = control1
            self.control2 = control2
        }
    }

    let start: CGPoint
    let curves: [Curve]

    nonisolated func path(in box: CursorBox) -> Path {
        func mirror(_ point: CGPoint) -> CGPoint { CGPoint(x: 1 - point.x, y: point.y) }
        var path = Path()
        path.move(to: box(start))
        for curve in curves {
            path.addCurve(to: box(curve.to), control1: box(curve.control1),
                          control2: box(curve.control2))
        }
        let points = [start] + curves.map(\.to)
        for index in curves.indices.reversed() {
            let curve = curves[index]
            path.addCurve(to: box(mirror(points[index])), control1: box(mirror(curve.control2)),
                          control2: box(mirror(curve.control1)))
        }
        path.closeSubpath()
        return path
    }
}
