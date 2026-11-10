import Foundation
import SceneKit
import simd

/// Материалы деталей по номерам (классификатор граней возвращает номер).
enum P: Int {
    case paint = 0, glass, roof, pillar, chrome, trim, rubber, rim, satin, tint, gloss
}

enum RoofStyle { case paint, panoramic, contrast(SCNMaterial), sunroof, sunroofBright }

/// Легковой кузов: лофт низа + лофт остекления + детали.
struct CarSpec {
    var L: Double, W: Double
    var sill = 0.32
    var top: [(Double, Double)]
    /// Множитель полуширины по y (талия, «бёдра»); по умолчанию 1.
    var waist: (Double) -> Double = { _ in 1 }
    var rcF = 0.42, rcR = 0.36, bulgeF = 0.10, bulgeR = 0.06
    var topRatio = 0.86, shoulder = 0.62, rm = 0.30, rt = 0.16, crown = 0.03, rb = 0.08
    // Остекление.
    var yA: Double, yRF: Double, yRR: Double, yC: Double
    var belt: Double, roofZ: Double, roofHalf: Double
    var roofCrown = 0.05, roofEdge = 0.10
    var windshieldBow = 0.08, rearBow = 0.06
    var roof: RoofStyle = .paint
    var pillarsBlack = false
    var chromeSurround = false
    // Колёса.
    var wheelR = 0.33, wheelW = 0.23, wheelbase: Double, track: Double
    var rimStyle = 0
    // Фары и фонари.
    var lampDepth = 0.30, lampInner = 0.45
    var tailDepth = 0.16, tailInner = 0.52, tailBar = false
    var grilleChrome = false
    var mirrorOut = 0.10
    var handles = true
    var pillarA = 0.07, pillarC = 0.12, panoInset = 0.10
    var windowChrome = false

    func planW(_ y: Double) -> Double {
        var w = W * waist(y)
        let dF = L / 2 - y, dR = y + L / 2
        if dF < rcF { w -= rcF - (max(0, rcF * rcF - (rcF - dF) * (rcF - dF))).squareRoot() }
        if dR < rcR { w -= rcR - (max(0, rcR * rcR - (rcR - dR) * (rcR - dR))).squareRoot() }
        return max(w, 0.02)
    }

    /// Расстояние от точки до края кузова в плане спереди/сзади (по оси y).
    func frontGap(_ p: V3) -> Double { edgeY(abs(p.x), front: true) - p.y }
    func rearGap(_ p: V3) -> Double { p.y - edgeY(abs(p.x), front: false) }

    func edgeY(_ x: Double, front: Bool) -> Double {
        // Поиск y, где полуширина плана равна x, у нужного конца.
        var lo = front ? 0.0 : -L / 2, hi = front ? L / 2 : 0.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            let inside = planW(mid) >= x
            if front { if inside { lo = mid } else { hi = mid } } else { if inside { hi = mid } else { lo = mid } }
        }
        let y = (lo + hi) / 2
        let w = max(planW(y), 1e-3)
        let b = front ? bulgeF : -bulgeR
        return y + b * max(0, 1 - (x / w) * (x / w))
    }

    var topCurve: Curve { Curve(top) }

    func bodySections() -> [Section] {
        let tc = topCurve
        return stations(-L / 2, L / 2, 170).map { y in
            let w = planW(y)
            let zt = tc(y)
            let dF = L / 2 - y, dR = y + L / 2
            let endLift = 0.10 * max(smooth(1 - dF / 0.7), smooth(1 - dR / 0.7))
            let zb = sill + endLift
            let wF = smooth(1 - dF / 0.55), wR = smooth(1 - dR / 0.55)
            return Section(y: y, wb: w * 0.93, zb: zb, wm: w, zm: zb + shoulder * (zt - zb),
                           wt: w * topRatio, zt: zt, rb: rb, rm: rm, rt: rt, crown: crown,
                           bulge: bulgeF * wF - bulgeR * wR)
        }
    }

    /// Профиль крыши по y (высота остекления).
    var roofCurve: Curve {
        let h = roofZ - belt
        return Curve([(yC, belt + 0.015), (yC + (yRR - yC) * 0.5, belt + h * (0.5 + rearBow)),
                      (yRR, roofZ - 0.012), ((yRR + yRF) / 2, roofZ), (yRF, roofZ - 0.012),
                      (yA + (yRF - yA) * 0.5, belt + h * (0.5 + windshieldBow)), (yA, belt + 0.015)])
    }

    func greenhouseTop(_ y: Double) -> Double {
        let base = ghBase(y) * 0.97
        if y > yRF { return lerp(roofHalf, base, smooth((y - yRF) / (yA - yRF))) }
        if y < yRR { return lerp(roofHalf, base, smooth((yRR - y) / (yRR - yC))) }
        return roofHalf
    }

    var ghBulgeF = 0.12, ghBulgeR = 0.08, ghPinch = 0.10

    func ghBulge(_ y: Double) -> Double {
        ghBulgeF * smooth((y - (yRF - 0.3)) / (yA - yRF + 0.3))
            - ghBulgeR * smooth(((yRR + 0.3) - y) / (yRR - yC + 0.3))
    }

    func ghBase(_ y: Double) -> Double {
        let ends = max(smooth((y - yRF) / (yA - yRF)), smooth((yRR - y) / (yRR - yC)))
        return planW(y) * topRatio * 0.985 * (1 - ghPinch * ends * ends)
    }

    func greenhouseSections() -> [Section] {
        let rc = roofCurve
        return stations(yC, yA, 120).map { y in
            let wb = ghBase(y)
            let zt = rc(y)
            return Section(y: y, wb: wb, zb: belt - 0.10, wm: wb, zm: belt,
                           wt: min(wb, greenhouseTop(y)), zt: max(zt, belt + 0.01),
                           rb: 0.01, rm: 0.02, rt: roofEdge, crown: roofCrown, bulge: ghBulge(y))
        }
    }

    func bodyClass(_ p: V3, _ n: V3) -> Int {
        // Фары и фонари — рисунком (livery); здесь только решётка на торце.
        let ax = abs(p.x)
        let upper = n.z > -0.15
        let fg = frontGap(p)
        if upper && fg < 0.05 && ax < lampInner * W - 0.04 && ax > 0.05 && p.z < topCurve(p.y) - 0.03 {
            return grilleChrome ? P.chrome.rawValue : P.trim.rawValue
        }
        return P.paint.rawValue
    }

    func glassClass(_ p: V3, _ n: V3) -> Int {
        let ax = abs(p.x)
        let top = greenhouseTop(p.y)
        let roofZone = p.y < yRF - 0.04 && p.y > yRR + 0.04
        if n.z > 0.72 && roofZone {
            if ax > top - 0.05 { return P.paint.rawValue }
            if case .contrast = roof { return P.roof.rawValue }
            return P.paint.rawValue
        }
        if p.z < belt + 0.045 && n.z < 0.9 { return chromeSurround ? P.chrome.rawValue : P.trim.rawValue }
        return P.glass.rawValue
    }

    func build(paint: SCNMaterial, glass: SCNMaterial = Mat.glass, extras: [SCNNode] = []) -> SCNNode {
        var mats: [Int: SCNMaterial] = [
            P.paint.rawValue: paint, P.glass.rawValue: glass, P.chrome.rawValue: Mat.chrome,
            P.trim.rawValue: Mat.trim, P.rubber.rawValue: Mat.rubber, P.rim.rawValue: Mat.satin,
            P.gloss.rawValue: Mat.gloss, P.tint.rawValue: Mat.tint, P.satin.rawValue: Mat.satin,
        ]
        mats[P.pillar.rawValue] = pillarsBlack ? Mat.gloss : paint
        if case .contrast(let m) = roof { mats[P.roof.rawValue] = m } else { mats[P.roof.rawValue] = paint }
        let root = SCNNode()
        root.addChildNode(node(loft(bodySections(), k: 10, seg: 5) { bodyClass($0, $1) }, materials: mats))
        root.addChildNode(node(loft(greenhouseSections(), k: 8, seg: 6) { glassClass($0, $1) }, materials: mats))
        // Колёса.
        for sx in [-1.0, 1.0] { for sy in [-1.0, 1.0] {
            let c = V3(sx * (track / 2), sy * wheelbase / 2, wheelR)
            root.addChildNode(node(wheel(center: c, r: wheelR, width: wheelW, side: sx, style: rimStyle), materials: mats))
        } }
        // Зеркала: корпус в цвет кузова на чёрной ножке.
        let mY = yA - 0.10, mZ = belt + 0.07
        let bodyX = planW(mY) * topRatio
        for sx in [-1.0, 1.0] {
            let housing = V3(sx * (W + mirrorOut - 0.04), mY, mZ)
            root.addChildNode(node(ellipsoid(center: housing, radii: V3(0.105, 0.06, 0.06), power: 2.6) { _, _ in P.paint.rawValue }, materials: mats))
            let arm = V3(sx * (bodyX + W + mirrorOut - 0.10) / 2, mY + 0.01, mZ - 0.02)
            root.addChildNode(node(ellipsoid(center: arm, radii: V3((W + mirrorOut - bodyX) / 2, 0.035, 0.025)) { _, _ in P.trim.rawValue }, materials: mats))
        }
        if handles {
            let hz = sill + shoulder * (belt - sill) + 0.05
            for sx in [-1.0, 1.0] { for hy in [yA - 0.55, (yRR + yC) / 2 + 0.15] {
                let x = sx * (planW(hy) * 0.995)
                root.addChildNode(node(ellipsoid(center: V3(x, hy, hz), radii: V3(0.02, 0.085, 0.018)) { _, _ in P.chrome.rawValue }, materials: mats))
            } }
        }
        extras.forEach { root.addChildNode($0) }
        return root
    }
}

/// Колесо: шина (тело вращения) и диск со спицами.
func wheel(center c: V3, r: Double, width: Double, side: Double, style: Int = 0) -> MeshPart {
    let hw = width / 2
    let rimR = r * 0.68
    var prof: [(r: Double, a: Double)] = []
    // Скруглённое сечение шины: внутренний обод → протектор → боковина.
    let corners: [(Double, Double)] = [(rimR, -hw * 0.92), (r - 0.04, -hw), (r, -hw * 0.75), (r, hw * 0.75), (r - 0.04, hw), (rimR, hw * 0.92)]
    for (rr, aa) in corners { prof.append((rr, aa)) }
    var part = revolve(profile: prof, center: c, steps: 56) { _, _ in P.rubber.rawValue }
    // Диск: тарелка и спицы на внешней стороне.
    let face = c + V3(side * hw * 0.85, 0, 0)
    let dish = revolve(profile: [(0.001, 0), (rimR * 0.98, -side * 0.03), (rimR, -side * 0.06), (0.001, -side * 0.06)],
                       center: face, steps: 40) { _, _ in P.trim.rawValue }
    part.append(dish)
    let spokes = style == 2 ? 10 : (style == 1 ? 6 : 5)
    for s in 0..<spokes {
        let th = Double(s) / Double(spokes) * 2 * .pi
        let mid = face + V3(side * 0.012, cos(th) * rimR * 0.5, sin(th) * rimR * 0.5)
        var spoke = ellipsoid(center: .zero, radii: V3(0.02, rimR * 0.5, 0.035), rows: 6, cols: 8) { _, _ in P.rim.rawValue }
        let ct = cos(th), st = sin(th)
        spoke.positions = spoke.positions.map { q in V3(q.x, q.y * ct - q.z * st, q.y * st + q.z * ct) + mid }
        spoke.normals = spoke.normals.map { q in V3(q.x, q.y * ct - q.z * st, q.y * st + q.z * ct) }
        part.append(spoke)
    }
    part.append(revolve(profile: [(0.001, 0), (0.06, 0), (0.06, side * 0.03), (0.001, side * 0.035)],
                        center: face, steps: 20) { _, _ in P.chrome.rawValue })
    return part
}

enum LampLook { case classic, slim, round }

extension CarSpec {
    func front(_ x: Double) -> Double { edgeY(abs(x), front: true) }
    func rear(_ x: Double) -> Double { edgeY(abs(x), front: false) }

    /// Базовый рисунок: фары, фонари, зазоры панелей — по плану кузова.
    func livery(paint: RGB, metal: Double = 0.55, rough: Double = 0.3, lamps: LampLook = .classic,
                gaps: Bool = true) -> Livery {
        let lv = Livery(base: paint, metal: metal, rough: rough)
        let x0 = lampInner * W, x1 = W * 0.995
        // Фара: корпус, линза, полоса ходовых огней.
        let housing = Livery.Ink(color: RGB(r: 0.10, g: 0.11, b: 0.13), metal: 0.9, rough: 0.22)
        let lens = Livery.Ink(color: RGB(r: 0.86, g: 0.90, b: 0.96), glow: RGB(r: 0.45, g: 0.50, b: 0.58), metal: 0.3, rough: 0.06)
        let drl = Livery.Ink(color: RGB(r: 1, g: 1, b: 1), glow: RGB(r: 1, g: 1, b: 1), metal: 0, rough: 0.2)
        func depth(_ k0: Double, _ k1: Double, _ e: Double) -> (Double) -> Double {
            { x in lampDepth * (k0 + (k1 - k0) * pow(max(0, (x - x0) / (x1 - x0)), e)) }
        }
        switch lamps {
        case .classic:
            lv.fill(edgeBand(x0: x0, x1: x1, edge: front, depth: depth(0.6, 1.1, 1.3)), housing, mirror: true)
            lv.fill(edgeBand(x0: x0 + 0.025, x1: x1 - 0.03, edge: front, depth: { depth(0.6, 1.1, 1.3)($0) - 0.03 }, overshoot: 0.05), lens, mirror: true)
            lv.fill(edgeBand(x0: x0 + 0.04, x1: x1 - 0.08, edge: { front($0) - depth(0.6, 1.1, 1.3)($0) + 0.05 }, depth: { _ in 0.025 }, overshoot: 0), drl, mirror: true)
        case .slim:
            lv.fill(edgeBand(x0: x0, x1: x1, edge: front, depth: depth(0.45, 1.0, 1.6)), housing, mirror: true)
            lv.fill(edgeBand(x0: x0 + 0.02, x1: x1 - 0.03, edge: front, depth: { depth(0.45, 1.0, 1.6)($0) - 0.025 }, overshoot: 0.05), lens, mirror: true)
            lv.fill(edgeBand(x0: x0 + 0.03, x1: x1 - 0.06, edge: { front($0) - depth(0.45, 1.0, 1.6)($0) + 0.05 }, depth: { _ in 0.03 }, overshoot: 0), drl, mirror: true)
        case .round:
            break
        }
        // Фонари: тёмно-бордовые, с чуть светлее внутренней полосой — не красный камеры.
        let t0 = tailInner * W, t1 = W * 0.99
        let tail = Livery.Ink(color: RGB(r: 0.26, g: 0.03, b: 0.05), glow: RGB(r: 0.10, g: 0.0, b: 0.015), metal: 0.3, rough: 0.12)
        let tailCore = Livery.Ink(color: RGB(r: 0.42, g: 0.05, b: 0.08), glow: RGB(r: 0.22, g: 0.015, b: 0.03), metal: 0.2, rough: 0.1)
        lv.fill(edgeBand(x0: t0, x1: t1, edge: rear, depth: { x in tailDepth * (0.6 + 0.5 * (x - t0) / (t1 - t0)) }, front: false), tail, mirror: true)
        lv.fill(edgeBand(x0: t0 + 0.03, x1: t1 - 0.04, edge: { rear($0) + tailDepth * (0.6 + 0.5 * ($0 - t0) / (t1 - t0)) - 0.05 }, depth: { _ in 0.03 }, overshoot: 0, front: false), tailCore, mirror: true)
        if tailBar {
            lv.fill(edgeBand(x0: -t0, x1: t0, edge: rear, depth: { _ in 0.035 }, overshoot: 0.03, front: false), tail)
        }
        // Стеклянная крыша / люк — рисунком: скруглённые края, рамка, мягкий отсвет неба.
        switch roof {
        case .panoramic:
            let r0 = CGRect(x: -(roofHalf - panoInset), y: yRR + 0.10 + panoInset * 0.6, width: 2 * (roofHalf - panoInset), height: yRF - yRR - 0.16 - panoInset * 1.2)
            roofGlass(lv, r0, light: 0.0, chromeFrame: false)
            lv.fill(rect(-(roofHalf - panoInset), (yRF + yRR) / 2 - 0.012, 2 * (roofHalf - panoInset), 0.024),
                    Livery.Ink(color: RGB(r: 0.02, g: 0.02, b: 0.025), metal: 0.3, rough: 0.3))
        case .sunroof:
            let mid = (yRF + yRR) / 2 + 0.1
            roofGlass(lv, CGRect(x: -(roofHalf - 0.20), y: mid - 0.30, width: 2 * (roofHalf - 0.20), height: 0.60), light: 0.3, chromeFrame: false)
        case .sunroofBright:
            // Люк — отдельная панель посреди крыши: перед ним и за ним крыша в цвет кузова.
            let mid = (yRF + yRR) / 2 + 0.04
            let len = min(0.56, (yRF - yRR) * 0.48)
            roofGlass(lv, CGRect(x: -(roofHalf - 0.19), y: mid - len / 2, width: 2 * (roofHalf - 0.19), height: len), light: 1.0, chromeFrame: true)
        default: break
        }
        if windowChrome {
            // Хромовая кромка по верху боковых окон.
            let ink = Livery.Ink(color: RGB(r: 0.92, g: 0.93, b: 0.95), metal: 1, rough: 0.08)
            let p = CGMutablePath()
            let n = 40
            for i in 0...n {
                let y = lerp(yRR - 0.05, yRF + 0.05, Double(i) / Double(n))
                let pt = CGPoint(x: greenhouseTop(y) - 0.035, y: y)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            lv.stroke(p, width: 0.018, ink, mirror: true)
        }
        if gaps {
            // Линии капота и крышки багажника — тонкие тёмные зазоры.
            let gap = Livery.Ink(color: RGB(r: 0.0, g: 0.0, b: 0.0), metal: 0, rough: 0.6)
            let hx = W * 0.80
            let hood = CGMutablePath()
            hood.move(to: CGPoint(x: -hx, y: yA - 0.02))
            hood.addLine(to: CGPoint(x: -hx * 0.97, y: front(hx) - lampDepth * 0.9))
            hood.move(to: CGPoint(x: hx, y: yA - 0.02))
            hood.addLine(to: CGPoint(x: hx * 0.97, y: front(hx) - lampDepth * 0.9))
            lv.stroke(hood, width: 0.012, gap)
            if yC > -L / 2 + 0.5 {
                let tx = W * 0.78
                let trunk = CGMutablePath()
                trunk.move(to: CGPoint(x: -tx, y: yC + 0.02))
                trunk.addLine(to: CGPoint(x: -tx * 0.97, y: rear(tx) + tailDepth))
                trunk.addLine(to: CGPoint(x: tx * 0.97, y: rear(tx) + tailDepth))
                trunk.addLine(to: CGPoint(x: tx, y: yC + 0.02))
                trunk.move(to: CGPoint(x: -tx, y: yC + 0.02)); trunk.addLine(to: CGPoint(x: tx, y: yC + 0.02))
                lv.stroke(trunk, width: 0.012, gap)
            }
        }
        return lv
    }

    /// Стекло с нарисованным отражением неба: светлее к верху лобового,
    /// мягкая косая полоса слева.
    func glassLivery(pillar: RGB? = nil, pillarMetal: Double = 0.5, pillarRough: Double = 0.25) -> Livery {
        let lv = Livery(base: RGB(r: 0.05, g: 0.06, b: 0.08), metal: 0.25, rough: 0.05)
        defer {
            // Стойки рисунком по плану: гладкий край вместо ступенек сетки.
            let ink = pillarsBlack || pillar == nil
                ? Livery.Ink(color: RGB(r: 0.03, g: 0.03, b: 0.035), metal: 0.3, rough: 0.15)
                : Livery.Ink(color: pillar!, metal: pillarMetal, rough: pillarRough)
            func band(_ y0: Double, _ y1: Double, inner: Double, outer: Double) -> CGPath {
                let p = CGMutablePath()
                let n = 30
                for i in 0...n {
                    let y = lerp(y0, y1, Double(i) / Double(n))
                    let w = min(ghBase(y), greenhouseTop(y)) + outer
                    let pt = CGPoint(x: w, y: y + ghBulge(y) * 0.0)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                for i in (0...n).reversed() {
                    let y = lerp(y0, y1, Double(i) / Double(n))
                    let w = min(ghBase(y), greenhouseTop(y)) - inner
                    p.addLine(to: CGPoint(x: w, y: y))
                }
                p.closeSubpath()
                return p
            }
            lv.fill(band(yRF - 0.08, yA + 0.05, inner: pillarA, outer: 0.2), ink, mirror: true)
            lv.fill(band(yC - 0.05, yRR + 0.08, inner: pillarC, outer: 0.2), ink, mirror: true)
            let bY = (yRF + yRR) / 2 + 0.05
            lv.fill(rect(roofHalf - 0.02, bY - 0.05, 0.6, 0.10), Livery.Ink(color: RGB(r: 0.03, g: 0.03, b: 0.035), metal: 0.3, rough: 0.15), mirror: true)
        }
        // Тонировка почти графитовая, холодный градиент к верху и один мягкий отсвет неба.
        let all = rect(-3, -3.5, 6, 7)
        lv.gradient(all, from: (CGPoint(x: 0, y: yA), RGB(r: 0.03, g: 0.037, b: 0.05)),
                    to: (CGPoint(x: 0, y: yRF), RGB(r: 0.10, g: 0.125, b: 0.165)))
        let rearPart = rect(-3, -3.5, 6, 3.5 + yRR)
        lv.gradient(rearPart, from: (CGPoint(x: 0, y: yC), RGB(r: 0.025, g: 0.03, b: 0.04)),
                    to: (CGPoint(x: 0, y: yRR), RGB(r: 0.075, g: 0.09, b: 0.12)))
        lv.glow(center: CGPoint(x: -0.22, y: (yA + yRF) / 2 + 0.05), radius: 0.75, color: RGB(r: 0.26, g: 0.31, b: 0.39), alpha: 0.55)
        lv.glow(center: CGPoint(x: -0.20, y: (yC + yRR) / 2), radius: 0.55, color: RGB(r: 0.20, g: 0.24, b: 0.30), alpha: 0.4)
        return lv
    }
}

/// Стеклянная панель крыши: рамка, тёмное стекло с холодным градиентом и мягким отсветом.
func roofGlass(_ lv: Livery, _ r0: CGRect, light: Double, chromeFrame: Bool) {
    let corner = min(0.09, r0.height * 0.2)
    if chromeFrame {
        lv.fill(CGPath(roundedRect: r0.insetBy(dx: -0.034, dy: -0.034), cornerWidth: corner + 0.03, cornerHeight: corner + 0.03, transform: nil),
                Livery.Ink(color: RGB(r: 0.92, g: 0.93, b: 0.95), metal: 1, rough: 0.08))
    }
    lv.fill(CGPath(roundedRect: r0.insetBy(dx: -0.018, dy: -0.018), cornerWidth: corner + 0.015, cornerHeight: corner + 0.015, transform: nil),
            Livery.Ink(color: RGB(r: 0.015, g: 0.015, b: 0.02), metal: 0.3, rough: 0.3))
    let path = CGPath(roundedRect: r0, cornerWidth: corner, cornerHeight: corner, transform: nil)
    lv.fill(path, Livery.Ink(metal: 0.3, rough: 0.04))
    let k = light
    lv.gradient(path, from: (CGPoint(x: 0, y: r0.maxY), RGB(r: 0.08 + 0.08 * k, g: 0.10 + 0.10 * k, b: 0.14 + 0.12 * k)),
                to: (CGPoint(x: 0, y: r0.minY), RGB(r: 0.03 + 0.03 * k, g: 0.04 + 0.04 * k, b: 0.055 + 0.05 * k)))
    lv.diffuse.saveGState(); lv.diffuse.addPath(path); lv.diffuse.clip()
    lv.glow(center: CGPoint(x: r0.minX + r0.width * 0.32, y: r0.midY + r0.height * 0.15), radius: max(r0.width, r0.height) * 0.55,
            color: RGB(r: 0.24 + 0.1 * k, g: 0.29 + 0.1 * k, b: 0.37 + 0.1 * k), alpha: 0.5)
    lv.diffuse.restoreGState()
}
