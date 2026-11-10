import Foundation
import SceneKit
import simd

let zero: Classifier = { _, _ in 0 }
func piece(_ m: MeshPart, _ mat: SCNMaterial) -> SCNNode { node(m, materials: [0: mat]) }

/// Прут между двумя точками (рейлинги, багажник, руль).
func rod(_ a: V3, _ b: V3, r: Double) -> MeshPart {
    let d = b - a, len = simd_length(d)
    let steps = 12
    let axis = d / len
    let up = abs(axis.z) < 0.9 ? V3(0, 0, 1) : V3(1, 0, 0)
    let s1 = simd_normalize(simd_cross(axis, up)), s2 = simd_cross(axis, s1)
    let grid: [[V3]] = (0...4).map { i in
        let t = Double(i) / 4
        let c = a + d * t
        let rr = (i == 0 || i == 4) ? r * 0.6 : r
        return (0..<steps).map { j in
            let th = Double(j) / Double(steps) * 2 * .pi
            return c + (s1 * cos(th) + s2 * sin(th)) * rr
        }
    }
    return gridMesh(grid, caps: true, classify: zero)
}

// MARK: - Премиум седан

func premiumSedan() -> SCNNode {
    // Представительский: длинный капот, салон сдвинут назад, короткий багажник.
    var s = CarSpec(L: 5.18, W: 0.965,
                    top: [(-2.59, 0.72), (-2.49, 0.91), (-2.3, 0.985), (-1.95, 1.0), (0.62, 0.985),
                          (1.5, 0.955), (2.3, 0.90), (2.5, 0.84), (2.59, 0.66)],
                    yA: 0.62, yRF: -0.10, yRR: -1.32, yC: -1.97,
                    belt: 0.99, roofZ: 1.48, roofHalf: 0.64, wheelbase: 3.1, track: 1.64)
    s.rcF = 0.30; s.rcR = 0.26; s.bulgeF = 0.16; s.bulgeR = 0.07; s.crown = 0.06; s.roofCrown = 0.07
    s.roof = .sunroofBright; s.pillarsBlack = false; s.chromeSurround = true; s.windowChrome = true
    s.pillarA = 0.08; s.pillarC = 0.16
    s.lampDepth = 0.30; s.lampInner = 0.48
    s.tailBar = true; s.tailDepth = 0.20; s.tailInner = 0.46
    s.waist = { y in 1 - 0.015 * smooth(1 - abs(y + 0.3) / 1.2) }
    let lv = s.livery(paint: RGB(r: 0.03, g: 0.034, b: 0.042), metal: 0.7, rough: 0.2, lamps: .slim)
    // Отсвет студии на чёрном лаке: капот, крыша по обе стороны люка, багажник.
    lv.glow(center: CGPoint(x: -0.26, y: 1.55), radius: 0.95, color: RGB(r: 0.30, g: 0.32, b: 0.36), alpha: 0.55)
    lv.glow(center: CGPoint(x: -0.20, y: s.yRF - 0.12), radius: 0.42, color: RGB(r: 0.34, g: 0.36, b: 0.40), alpha: 0.6)
    lv.glow(center: CGPoint(x: -0.20, y: s.yRR + 0.14), radius: 0.40, color: RGB(r: 0.30, g: 0.32, b: 0.36), alpha: 0.5)
    lv.glow(center: CGPoint(x: -0.24, y: -2.25), radius: 0.5, color: RGB(r: 0.28, g: 0.30, b: 0.34), alpha: 0.45)
    // Хромированная планка решётки по переднему краю.
    lv.fill(edgeBand(x0: -0.36, x1: 0.36, edge: s.front, depth: { _ in 0.05 }, overshoot: 0.05),
            Livery.Ink(color: RGB(r: 0.92, g: 0.93, b: 0.95), metal: 1, rough: 0.08))
    lv.fill(edgeBand(x0: -0.30, x1: 0.30, edge: { s.front($0) - 0.05 }, depth: { _ in 0.02 }, overshoot: 0),
            Livery.Ink(color: RGB(r: 0.02, g: 0.02, b: 0.02), metal: 0.5, rough: 0.3))
    // Хромовая кромка багажника.
    lv.fill(edgeBand(x0: -0.42, x1: 0.42, edge: { s.rear($0) + 0.06 }, depth: { _ in 0.022 }, overshoot: 0, front: false),
            Livery.Ink(color: RGB(r: 0.9, g: 0.91, b: 0.93), metal: 1, rough: 0.08))
    return s.build(paint: lv.material(), glass: s.glassLivery(pillar: RGB(r: 0.03, g: 0.034, b: 0.042), pillarMetal: 0.7, pillarRough: 0.2).material(coat: 1, coatRough: 0))
}

// MARK: - Такси

func taxi() -> SCNNode {
    var s = CarSpec(L: 4.48, W: 0.875,
                    top: [(-2.24, 0.78), (-2.12, 0.93), (-1.9, 0.985), (-1.5, 0.99), (0.6, 0.965),
                          (1.4, 0.93), (1.98, 0.86), (2.16, 0.78), (2.24, 0.64)],
                    yA: 0.62, yRF: 0.0, yRR: -0.96, yC: -1.52,
                    belt: 0.97, roofZ: 1.47, roofHalf: 0.60, wheelbase: 2.62, track: 1.50)
    s.rcF = 0.32; s.rcR = 0.30; s.bulgeF = 0.13; s.bulgeR = 0.07; s.crown = 0.05
    s.lampDepth = 0.34; s.lampInner = 0.50; s.tailDepth = 0.20; s.tailInner = 0.50
    let lv = s.livery(paint: RGB(r: 1.0, g: 0.76, b: 0.05), metal: 0.25, rough: 0.28, lamps: .classic)
    lv.fill(edgeBand(x0: -0.40, x1: 0.40, edge: s.front, depth: { _ in 0.05 }, overshoot: 0.05),
            Livery.Ink(color: RGB(r: 0.06, g: 0.06, b: 0.07), metal: 0.2, rough: 0.4))
    // Шашки на крыше: короб над крышей, сверху клетка 2×6.
    let signY = -0.42, signHalf = V3(0.36, 0.14, 0.10)
    let top = s.roofZ + 0.02 + signHalf.z
    let white = Livery.Ink(color: RGB(r: 0.96, g: 0.96, b: 0.95), glow: RGB(r: 0.18, g: 0.18, b: 0.17), metal: 0, rough: 0.25)
    let black = Livery.Ink(color: RGB(r: 0.03, g: 0.03, b: 0.035), metal: 0, rough: 0.25)
    lv.fill(rect(-signHalf.x - 0.05, signY - signHalf.y - 0.05, 2 * signHalf.x + 0.1, 2 * signHalf.y + 0.1), black)
    let cols = 6, rows = 2
    let cw = 2 * signHalf.x / Double(cols), ch = 2 * signHalf.y / Double(rows)
    for i in 0..<cols { for j in 0..<rows where (i + j) % 2 == 0 {
        lv.fill(rect(-signHalf.x + Double(i) * cw, signY - signHalf.y + Double(j) * ch, cw, ch), white)
    } }
    let paint = lv.material()
    let sign = piece(roundedBox(center: V3(0, signY, top - signHalf.z), half: signHalf, r: 0.035, classify: zero), paint)
    let base = piece(roundedBox(center: V3(0, signY, s.roofZ + 0.01), half: V3(0.30, 0.10, 0.03), r: 0.02, classify: zero), Mat.trim)
    return s.build(paint: paint, glass: s.glassLivery(pillar: RGB(r: 1.0, g: 0.76, b: 0.05), pillarMetal: 0.25, pillarRough: 0.28).material(coat: 1, coatRough: 0), extras: [base, sign])
}

// MARK: - Кроссовер

func crossover() -> SCNNode {
    var s = CarSpec(L: 4.55, W: 0.93,
                    top: [(-2.275, 0.95), (-2.2, 1.04), (-2.05, 1.08), (0.78, 1.06),
                          (1.5, 1.01), (2.05, 0.95), (2.22, 0.88), (2.275, 0.74)],
                    yA: 0.78, yRF: 0.18, yRR: -1.62, yC: -2.08,
                    belt: 1.07, roofZ: 1.66, roofHalf: 0.67, wheelbase: 2.70, track: 1.62)
    s.sill = 0.40; s.rcF = 0.32; s.rcR = 0.26; s.bulgeF = 0.12; s.bulgeR = 0.04; s.crown = 0.05
    s.roof = .sunroof; s.pillarsBlack = true; s.rearBow = 0.1
    s.lampDepth = 0.26; s.lampInner = 0.52; s.tailDepth = 0.14; s.tailInner = 0.50; s.tailBar = true
    s.wheelR = 0.36; s.wheelW = 0.24
    let lv = s.livery(paint: RGB(r: 0.07, g: 0.36, b: 0.42), metal: 0.6, rough: 0.26, lamps: .slim)
    lv.fill(edgeBand(x0: -0.42, x1: 0.42, edge: s.front, depth: { _ in 0.06 }, overshoot: 0.05),
            Livery.Ink(color: RGB(r: 0.05, g: 0.05, b: 0.06), metal: 0.3, rough: 0.35))
    var rails: [SCNNode] = []
    for sx in [-1.0, 1.0] {
        let x = sx * (s.roofHalf - 0.06)
        rails.append(piece(rod(V3(x, -1.52, s.roofZ + 0.035), V3(x, 0.08, s.roofZ + 0.035), r: 0.022), Mat.satin))
        for y in [-1.45, 0.02] {
            rails.append(piece(rod(V3(x, y, s.roofZ - 0.01), V3(x, y, s.roofZ + 0.03), r: 0.02), Mat.trim))
        }
    }
    return s.build(paint: lv.material(), glass: s.glassLivery().material(coat: 1, coatRough: 0), extras: rails)
}

// MARK: - Спорткар

func sportCoupe() -> SCNNode {
    var s = CarSpec(L: 4.50, W: 0.99,
                    top: [(-2.25, 0.80), (-2.12, 0.93), (-1.95, 0.95), (-1.6, 0.90), (0.32, 0.84),
                          (1.2, 0.76), (1.9, 0.66), (2.15, 0.60), (2.25, 0.50)],
                    yA: 0.32, yRF: -0.32, yRR: -0.92, yC: -1.72,
                    belt: 0.86, roofZ: 1.24, roofHalf: 0.56, wheelbase: 2.55, track: 1.62)
    s.sill = 0.20; s.rcF = 0.36; s.rcR = 0.34; s.bulgeF = 0.18; s.bulgeR = 0.05; s.crown = 0.04
    s.rm = 0.26; s.topRatio = 0.80; s.windshieldBow = 0.12; s.rearBow = 0.14; s.roofEdge = 0.14
    s.waist = { y in
        let hips = 0.04 * smooth(1 - abs(y + 1.27) / 0.8)
        let front = 0.02 * smooth(1 - abs(y - 1.27) / 0.7)
        let wasp = 0.04 * smooth(1 - abs(y + 0.1) / 0.8)
        return 0.96 + hips + front - wasp
    }
    s.lampDepth = 0.30; s.lampInner = 0.55; s.tailDepth = 0.14; s.tailInner = 0.42; s.tailBar = true
    s.wheelR = 0.34; s.wheelW = 0.25; s.handles = false; s.pillarsBlack = true
    let lv = s.livery(paint: RGB(r: 0.98, g: 0.40, b: 0.04), metal: 0.5, rough: 0.22, lamps: .slim)
    // Две гоночные полосы по оси — по капоту, крыше и крышке.
    let stripe = Livery.Ink(color: RGB(r: 0.06, g: 0.065, b: 0.075), metal: 0.4, rough: 0.25)
    for sx in [-1.0, 1.0] {
        lv.fill(rect(sx > 0 ? 0.07 : -0.22, -3, 0.15, 6), stripe)
    }
    lv.fill(edgeBand(x0: -0.5, x1: 0.5, edge: s.front, depth: { _ in 0.05 }, overshoot: 0.05),
            Livery.Ink(color: RGB(r: 0.04, g: 0.04, b: 0.045), metal: 0.2, rough: 0.4))
    let paint = lv.material()
    // Утиный хвост из карбона.
    let wing = piece(roundedBox(center: V3(0, -2.02, 0.98), half: V3(0.78, 0.09, 0.02), r: 0.02, classify: zero), Mat.gloss)
    return s.build(paint: paint, glass: s.glassLivery().material(coat: 1, coatRough: 0), extras: [wing])
}

let vehicles: [Vehicle] = [
    Vehicle(id: "premium", title: "Премиум седан", lengthPt: 43, lengthM: 5.18, build: premiumSedan),
    Vehicle(id: "taxi", title: "Такси", lengthPt: 40, lengthM: 4.48, build: taxi),
    Vehicle(id: "crossover", title: "Кроссовер", lengthPt: 41, lengthM: 4.55, build: crossover),
    Vehicle(id: "sport", title: "Спорткар", lengthPt: 41, lengthM: 4.50, build: sportCoupe),
    Vehicle(id: "suv", title: "Внедорожник", lengthPt: 44, lengthM: 5.0, build: bigSUV),
    Vehicle(id: "pickup", title: "Пикап-клин", lengthPt: 45, lengthM: 5.68, build: wedgePickup),
    Vehicle(id: "moto", title: "Мотоцикл", lengthPt: 36, lengthM: 2.16, build: motorcycle),
]


// MARK: - Большой внедорожник

func bigSUV() -> SCNNode {
    var s = CarSpec(L: 5.0, W: 1.0,
                    top: [(-2.5, 1.08), (-2.43, 1.21), (-2.3, 1.255), (1.02, 1.235),
                          (1.9, 1.18), (2.32, 1.11), (2.45, 1.04), (2.5, 0.92)],
                    yA: 1.02, yRF: 0.40, yRR: -1.98, yC: -2.32,
                    belt: 1.25, roofZ: 1.93, roofHalf: 0.77, wheelbase: 2.85, track: 1.70)
    s.sill = 0.45; s.rcF = 0.26; s.rcR = 0.22; s.bulgeF = 0.09; s.bulgeR = 0.03; s.crown = 0.035
    s.topRatio = 0.92; s.rm = 0.18; s.rt = 0.11; s.shoulder = 0.68
    s.roofCrown = 0.03; s.roofEdge = 0.09; s.windshieldBow = 0.05; s.rearBow = 0.16
    s.ghPinch = 0.05; s.ghBulgeF = 0.08; s.ghBulgeR = 0.03
    s.roof = .panoramic; s.panoInset = 0.17; s.chromeSurround = true
    s.wheelR = 0.41; s.wheelW = 0.28; s.rimStyle = 2; s.mirrorOut = 0.12
    s.lampDepth = 0.24; s.lampInner = 0.56; s.tailDepth = 0.12; s.tailInner = 0.55; s.tailBar = true
    let pearl = RGB(r: 0.95, g: 0.955, b: 0.96)
    let lv = s.livery(paint: pearl, metal: 0.35, rough: 0.2, lamps: .slim)
    // Решётка: хромовая рамка и горизонтальные ламели во всю ширину между фар.
    let chrome = Livery.Ink(color: RGB(r: 0.93, g: 0.94, b: 0.96), metal: 1, rough: 0.08)
    lv.fill(edgeBand(x0: -0.55, x1: 0.55, edge: s.front, depth: { _ in 0.11 }, overshoot: 0.05), chrome)
    lv.fill(edgeBand(x0: -0.51, x1: 0.51, edge: { s.front($0) - 0.02 }, depth: { _ in 0.07 }, overshoot: 0.05),
            Livery.Ink(color: RGB(r: 0.04, g: 0.04, b: 0.045), metal: 0.4, rough: 0.3))
    for k in 0..<3 {
        lv.fill(edgeBand(x0: -0.51, x1: 0.51, edge: { s.front($0) - 0.03 - Double(k) * 0.022 }, depth: { _ in 0.007 }, overshoot: 0), chrome)
    }
    // Рёбра капота.
    for sx in [-1.0, 1.0] {
        let p = CGMutablePath(); p.move(to: CGPoint(x: sx * 0.42, y: 1.08)); p.addCurve(to: CGPoint(x: sx * 0.36, y: 2.30), control1: CGPoint(x: sx * 0.44, y: 1.6), control2: CGPoint(x: sx * 0.40, y: 2.0))
        lv.stroke(p, width: 0.03, Livery.Ink(color: RGB(r: 0.74, g: 0.75, b: 0.77)))
        let q = p.copy(using: [CGAffineTransform(translationX: sx * 0.025, y: 0)])!
        lv.stroke(q, width: 0.015, Livery.Ink(color: RGB(r: 0.98, g: 0.98, b: 0.99)))
    }
    // Хромовая планка на двери багажника.
    lv.fill(edgeBand(x0: -0.5, x1: 0.5, edge: { s.rear($0) + 0.08 }, depth: { _ in 0.025 }, overshoot: 0, front: false), chrome)
    let paint = lv.material(coat: 1, coatRough: 0.02)
    var extras: [SCNNode] = []
    // Широкие арки: чёрные накладки.
    for sx in [-1.0, 1.0] { for sy in [-1.0, 1.0] {
        let c = V3(sx * (s.W + 0.01), sy * s.wheelbase / 2, 0.95)
        extras.append(piece(roundedBox(center: c, half: V3(0.045, 0.56, 0.09), r: 0.04, classify: zero), Mat.gloss))
    } }
    // Рейлинги во всю длину крыши на стойках.
    for sx in [-1.0, 1.0] {
        let x = sx * (s.roofHalf - 0.05)
        extras.append(piece(rod(V3(x, -1.88, s.roofZ + 0.05), V3(x, 0.30, s.roofZ + 0.05), r: 0.03), Mat.chrome))
        for y in [-1.82, -0.78, 0.24] {
            extras.append(piece(rod(V3(x, y, s.roofZ - 0.01), V3(x, y, s.roofZ + 0.05), r: 0.028), Mat.gloss))
        }
    }
    let glass = s.glassLivery(pillar: pearl, pillarMetal: 0.35, pillarRough: 0.2)
    return s.build(paint: paint, glass: glass.material(coat: 1, coatRough: 0), extras: extras)
}
