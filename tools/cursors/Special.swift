import Foundation
import SceneKit
import simd

// MARK: - Пикап-клин: гранёный кузов из нержавейки

func wedgePickup() -> SCNNode {
    let L = 5.68, half = L / 2
    let apexY = 0.15
    // Верхняя линия — две прямые: от носа к вершине и от вершины к корме.
    func zt(_ y: Double) -> Double {
        y >= apexY ? lerp(1.86, 1.02, (y - apexY) / (half - apexY)) : lerp(1.86, 1.27, (apexY - y) / (apexY + half))
    }
    func wt(_ y: Double) -> Double {
        y >= apexY ? lerp(0.64, 0.84, (y - apexY) / (half - apexY)) : lerp(0.64, 0.80, (apexY - y) / (apexY + half))
    }
    let cuts: [Double] = [-half, -half + 0.06, -2.70, -0.62, -0.40, apexY, 0.25, 1.35, 1.50, 2.62, half - 0.07, half]
    let secs = cuts.map { y -> Section in
        let end = y <= -half + 0.001 || y >= half - 0.001
        let chamf = (y <= -half + 0.07 || y >= half - 0.08) ? 0.05 : 0
        let w = 1.0 - chamf - (end ? 0.02 : 0)
        let zm = y > 2.0 ? lerp(1.0, 0.93, (y - 2.0) / (half - 2.0)) : 1.0
        return Section(y: y, wb: w - 0.03, zb: 0.48, wm: w, zm: zm, wt: wt(y) - chamf, zt: zt(y) - chamf * 0.5,
                       rb: 0.002, rm: 0.002, rt: 0.002)
    }
    let lv = Livery(base: RGB(r: 0.70, g: 0.72, b: 0.74), metal: 0.72, rough: 0.38)
    // Шлифовка вдоль кузова: тонкие продольные штрихи светлее и темнее.
    var seed: UInt64 = 7
    func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
    for _ in 0..<500 {
        let x = rnd() * 2.2 - 1.1, w = 0.002 + rnd() * 0.004, k = 0.6 + rnd() * 0.16
        lv.fill(rect(x, -3, w, 6), Livery.Ink(color: RGB(r: k, g: k + 0.02, b: k + 0.04), rough: 0.3 + rnd() * 0.12))
    }
    // Световая полоса во всю ширину спереди и тёмно-бордовая сзади.
    lv.fill(rect(-0.98, half - 0.10, 1.96, 0.16, r: 0.02), Livery.Ink(color: RGB(r: 0.1, g: 0.1, b: 0.11), metal: 0.5, rough: 0.2))
    lv.fill(rect(-0.95, half - 0.07, 1.90, 0.05, r: 0.02), Livery.Ink(color: RGB(r: 1, g: 1, b: 1), glow: RGB(r: 1, g: 1, b: 1), metal: 0, rough: 0.2))
    lv.fill(rect(-0.98, -half - 0.06, 1.96, 0.14, r: 0.02), Livery.Ink(color: RGB(r: 0.12, g: 0.02, b: 0.03), metal: 0.4, rough: 0.2))
    lv.fill(rect(-0.94, -half + 0.015, 1.88, 0.035, r: 0.015), Livery.Ink(color: RGB(r: 0.42, g: 0.05, b: 0.08), glow: RGB(r: 0.22, g: 0.015, b: 0.03), metal: 0.2, rough: 0.1))
    // Крышка кузова: тёмные ламели.
    let vault = Livery.Ink(color: RGB(r: 0.44, g: 0.46, b: 0.48), metal: 0.9, rough: 0.42)
    lv.fill(rect(-0.82, -2.66, 1.64, 1.90), vault)
    for i in 0..<16 {
        let y = -2.62 + Double(i) * 0.118
        lv.fill(rect(-0.82, y, 1.64, 0.014), Livery.Ink(color: RGB(r: 0.12, g: 0.12, b: 0.13), rough: 0.6))
    }
    let steel = lv.material(coat: 0.3, coatRough: 0.2)
    let gl = Livery(base: RGB(r: 0.05, g: 0.06, b: 0.08), metal: 0.25, rough: 0.05)
    gl.gradient(rect(-1.2, 0.2, 2.4, 1.3), from: (CGPoint(x: 0, y: 1.35), RGB(r: 0.03, g: 0.037, b: 0.05)),
                to: (CGPoint(x: 0, y: 0.25), RGB(r: 0.11, g: 0.14, b: 0.18)))
    gl.gradient(rect(-1.2, -0.7, 2.4, 0.95), from: (CGPoint(x: 0, y: -0.6), RGB(r: 0.025, g: 0.03, b: 0.04)),
                to: (CGPoint(x: 0, y: 0.25), RGB(r: 0.07, g: 0.085, b: 0.11)))
    gl.glow(center: CGPoint(x: -0.25, y: 0.85), radius: 0.8, color: RGB(r: 0.26, g: 0.31, b: 0.39), alpha: 0.55)
    let glassMat = gl.material(coat: 1, coatRough: 0)
    let mats: [Int: SCNMaterial] = [P.paint.rawValue: steel, P.tint.rawValue: glassMat, P.glass.rawValue: glassMat,
                                    P.trim.rawValue: Mat.trim, P.rubber.rawValue: Mat.rubber, P.rim.rawValue: Mat.satin,
                                    P.chrome.rawValue: Mat.chrome]
    let body = loft(secs, k: 2, seg: 6, flat: true) { p, n in
        let top = n.z > 0.75 && abs(p.x) < 0.62
        if top && p.y > -0.40 && p.y < 1.35 { return p.y > 0.25 ? P.glass.rawValue : P.tint.rawValue }
        if n.z > 0.2 && n.z < 0.75 && p.y > -0.62 && p.y < 1.35 && p.z > 1.12 { return P.glass.rawValue }
        return P.paint.rawValue
    }
    let root = SCNNode()
    root.addChildNode(node(body, materials: mats))
    // Арки: гранёные накладки над колёсами.
    for sx in [-1.0, 1.0] { for sy in [-1.0, 1.0] {
        let c = V3(sx * 0.98, sy * 1.85, 0.95)
        root.addChildNode(piece(roundedBox(center: c, half: V3(0.05, 0.56, 0.06), r: 0.01, classify: zero), Mat.trim))
        root.addChildNode(node(wheel(center: V3(sx * 0.84, sy * 1.85, 0.43), r: 0.43, width: 0.30, side: sx, style: 1), materials: mats))
    } }
    // Зеркала-призмы.
    for sx in [-1.0, 1.0] {
        root.addChildNode(piece(ellipsoid(center: V3(sx * 1.07, 1.62, 1.18), radii: V3(0.10, 0.07, 0.05), power: 5, classify: zero), steel))
        root.addChildNode(piece(rod(V3(sx * 0.92, 1.66, 1.12), V3(sx * 1.0, 1.63, 1.17), r: 0.02), Mat.trim))
    }
    return root
}

// MARK: - Мотоцикл с гонщиком

func motorcycle() -> SCNNode {
    let root = SCNNode()
    let paintLv = Livery(base: RGB(r: 0.06, g: 0.30, b: 0.78), metal: 0.55, rough: 0.24)
    // Белые полосы по баку и обтекателю, двойная фара, фонарь.
    paintLv.fill(rect(-0.035, -1.2, 0.07, 2.4), Livery.Ink(color: RGB(r: 0.95, g: 0.96, b: 0.97), metal: 0.2))
    for sx in [-1.0, 1.0] {
        paintLv.fill(CGPath(ellipseIn: CGRect(x: sx * 0.07 - 0.045, y: 0.86, width: 0.09, height: 0.10), transform: nil),
                     Livery.Ink(color: RGB(r: 0.95, g: 0.97, b: 1), glow: RGB(r: 0.9, g: 0.95, b: 1), metal: 0.2, rough: 0.05))
    }
    paintLv.fill(rect(-0.06, -1.08, 0.12, 0.06, r: 0.02), Livery.Ink(color: RGB(r: 0.42, g: 0.05, b: 0.08), glow: RGB(r: 0.2, g: 0.01, b: 0.03), metal: 0.2))
    let paint = paintLv.material()
    let mats: [Int: SCNMaterial] = [P.rubber.rawValue: Mat.rubber, P.trim.rawValue: Mat.trim, P.rim.rawValue: Mat.satin, P.chrome.rawValue: Mat.chrome]
    // Колесо по оси симметрии: диск с обеих сторон, иначе силуэт кривой.
    for (y, r, w) in [(-0.70, 0.31, 0.19), (0.72, 0.30, 0.12)] {
        var both = wheel(center: V3(0, y, r), r: r, width: w, side: 1)
        both.append(mirroredX(both))
        root.addChildNode(node(both, materials: mats))
    }
    // Обтекатель, бак, хвост — один лофт по длине.
    let prof: [(Double, Double, Double, Double)] = [   // y, полуширина, низ, верх
        (-1.08, 0.025, 0.86, 0.90), (-1.0, 0.06, 0.80, 0.93), (-0.75, 0.10, 0.74, 0.92), (-0.50, 0.13, 0.66, 0.86),
        (-0.15, 0.18, 0.55, 0.90), (0.10, 0.21, 0.52, 1.02), (0.32, 0.20, 0.52, 1.05), (0.50, 0.19, 0.55, 1.02),
        (0.72, 0.17, 0.60, 1.00), (0.88, 0.12, 0.66, 0.93), (0.98, 0.04, 0.72, 0.84)]
    let ys = stations(-1.08, 0.98, 80)
    let cW = Curve(prof.map { ($0.0, $0.1) }), cB = Curve(prof.map { ($0.0, $0.2) }), cT = Curve(prof.map { ($0.0, $0.3) })
    let secs = ys.map { y in
        Section(y: y, wb: cW(y) * 0.6, zb: cB(y), wm: cW(y), zm: lerp(cB(y), cT(y), 0.45), wt: cW(y) * 0.7, zt: cT(y),
                rb: 0.04, rm: 0.08, rt: 0.06, crown: 0.02)
    }
    root.addChildNode(node(loft(secs, k: 8, seg: 3) { p, _ in
        if p.y > -0.48 && p.y < -0.12 && p.z > 0.8 { return 1 }   // сиденье
        return 0
    }, materials: [0: paint, 1: Mat.trim]))
    // Ветровое стекло.
    root.addChildNode(piece(ellipsoid(center: V3(0, 0.66, 1.06), radii: V3(0.13, 0.17, 0.05), power: 2.2, classify: zero), Mat.tint))
    // Руль-клипоны и зеркала.
    for sx in [-1.0, 1.0] {
        root.addChildNode(piece(rod(V3(sx * 0.10, 0.50, 1.00), V3(sx * 0.33, 0.44, 0.98), r: 0.022), Mat.trim))
        root.addChildNode(piece(rod(V3(sx * 0.28, 0.45, 0.985), V3(sx * 0.37, 0.43, 0.98), r: 0.03), Mat.rubber))
        root.addChildNode(piece(rod(V3(sx * 0.16, 0.68, 1.02), V3(sx * 0.30, 0.66, 1.05), r: 0.012), Mat.trim))
        root.addChildNode(piece(ellipsoid(center: V3(sx * 0.33, 0.655, 1.05), radii: V3(0.06, 0.035, 0.03), power: 2.5, classify: zero), paint))
    }
    // Гонщик: куртка, руки, бёдра, шлем.
    let suitLv = Livery(base: RGB(r: 0.07, g: 0.075, b: 0.09), metal: 0.1, rough: 0.55)
    for sx in [-1.0, 1.0] {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: sx * 0.20, y: 0.05)); p.addLine(to: CGPoint(x: sx * 0.13, y: -0.35))
        p.addLine(to: CGPoint(x: sx * 0.08, y: -0.35)); p.addLine(to: CGPoint(x: sx * 0.14, y: 0.05)); p.closeSubpath()
        suitLv.fill(p, Livery.Ink(color: RGB(r: 0.92, g: 0.93, b: 0.95), rough: 0.4))
    }
    let suit = suitLv.material(coat: 0)
    root.addChildNode(piece(ellipsoid(center: V3(0, -0.12, 1.30), radii: V3(0.22, 0.30, 0.17), power: 2.3, classify: zero), suit))
    root.addChildNode(piece(ellipsoid(center: V3(0, -0.36, 1.08), radii: V3(0.17, 0.14, 0.14), classify: zero), suit))
    for sx in [-1.0, 1.0] {
        root.addChildNode(piece(rod(V3(sx * 0.18, 0.05, 1.36), V3(sx * 0.27, 0.28, 1.18), r: 0.055), suit))
        root.addChildNode(piece(rod(V3(sx * 0.27, 0.28, 1.18), V3(sx * 0.31, 0.43, 1.02), r: 0.045), suit))
        root.addChildNode(piece(ellipsoid(center: V3(sx * 0.31, 0.44, 1.02), radii: V3(0.045, 0.05, 0.04), classify: zero), Mat.gloss))
        root.addChildNode(piece(rod(V3(sx * 0.13, -0.32, 1.02), V3(sx * 0.24, 0.02, 0.86), r: 0.075), suit))
        root.addChildNode(piece(rod(V3(sx * 0.24, 0.02, 0.86), V3(sx * 0.17, -0.30, 0.60), r: 0.06), suit))
    }
    let helmLv = Livery(base: RGB(r: 0.94, g: 0.95, b: 0.97), metal: 0.1, rough: 0.15)
    helmLv.fill(rect(-0.03, -0.2, 0.06, 0.5), Livery.Ink(color: RGB(r: 0.06, g: 0.30, b: 0.78)))
    helmLv.fill(CGPath(ellipseIn: CGRect(x: -0.11, y: 0.19, width: 0.22, height: 0.12), transform: nil),
                Livery.Ink(color: RGB(r: 0.05, g: 0.06, b: 0.08), metal: 0.6, rough: 0.05))
    root.addChildNode(piece(ellipsoid(center: V3(0, 0.14, 1.50), radii: V3(0.135, 0.16, 0.13), classify: zero), helmLv.material()))
    return root
}
