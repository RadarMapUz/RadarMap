import AppKit
import Foundation
import SceneKit
import simd

// Координаты машины: x — вправо, y — вперёд (нос), z — вверх, метры.
typealias V3 = SIMD3<Double>

func scn(_ p: V3) -> SCNVector3 { SCNVector3(CGFloat(p.x), CGFloat(p.z), CGFloat(-p.y)) }

func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func clamp01(_ t: Double) -> Double { min(1, max(0, t)) }
func smooth(_ t: Double) -> Double { let x = clamp01(t); return x * x * (3 - 2 * x) }

/// Монотонный кубический сплайн по опорным точкам (без выбросов между ними).
struct Curve {
    let xs: [Double], ys: [Double], ms: [Double]

    init(_ points: [(Double, Double)]) {
        let p = points.sorted { $0.0 < $1.0 }
        xs = p.map(\.0); ys = p.map(\.1)
        let n = p.count
        var d = [Double](repeating: 0, count: max(1, n - 1))
        for i in 0..<(n - 1) { d[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) }
        var m = [Double](repeating: 0, count: n)
        if n > 1 {
            m[0] = d[0]; m[n - 1] = d[n - 2]
            for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
            for i in 0..<(n - 1) where d[i] == 0 { m[i] = 0; m[i + 1] = 0 }
            for i in 0..<(n - 1) where d[i] != 0 {
                let a = m[i] / d[i], b = m[i + 1] / d[i], s = a * a + b * b
                if s > 9 { let t = 3 / s.squareRoot(); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
            }
        }
        ms = m
    }

    func callAsFunction(_ x: Double) -> Double {
        if x <= xs[0] { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        var i = 0
        while x > xs[i + 1] { i += 1 }
        let h = xs[i + 1] - xs[i], t = (x - xs[i]) / h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * ms[i]
            + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * ms[i + 1]
    }
}

/// Сечение кузова поперёк оси: скруглённый многоугольник низ — пояс — верх.
struct Section {
    var y: Double
    var wb: Double, zb: Double      // низ: полуширина, высота
    var wm: Double, zm: Double      // пояс (самое широкое место)
    var wt: Double, zt: Double      // верх у плеча
    var rb = 0.08, rm = 0.25, rt = 0.12
    var crown = 0.0                 // выпуклость верха по центру
    var bulge = 0.0                 // смещение центра по y (дуга в плане)
}

/// Кольцо сечения: правая половина снизу вверх, затем левая сверху вниз.
/// Число точек фиксировано — кольца соседних сечений сшиваются в сетку.
func ring(_ s: Section, k: Int = 10, seg: Int = 4) -> [V3] {
    let p0 = SIMD2(0.0, s.zb), c1 = SIMD2(s.wb, s.zb), c2 = SIMD2(s.wm, s.zm)
    let c3 = SIMD2(s.wt, s.zt), p4 = SIMD2(0.0, s.zt)
    let corners = [(c1, s.rb), (c2, s.rm), (c3, s.rt)]
    let chain = [p0, c1, c2, c3, p4]
    var right: [SIMD2<Double>] = []
    var cursor = p0
    for (i, (c, r)) in corners.enumerated() {
        let prev = chain[i], next = chain[i + 2]
        let a = c - prev, b = next - c
        let la = simd_length(a), lb = simd_length(b)
        let cut = min(r, 0.45 * la, 0.45 * lb)
        let start = la > 1e-9 ? c - a / la * cut : c
        let end = lb > 1e-9 ? c + b / lb * cut : c
        for j in 0..<seg { right.append(cursor + (start - cursor) * Double(j) / Double(seg)) }
        for j in 0..<k {
            let t = Double(j) / Double(k)
            right.append((1 - t) * (1 - t) * start + 2 * (1 - t) * t * c + t * t * end)
        }
        cursor = end
    }
    for j in 0..<seg { right.append(cursor + (p4 - cursor) * Double(j) / Double(seg)) }
    right.append(p4)
    var pts = right
    for q in right.dropFirst().dropLast().reversed() { pts.append(SIMD2(-q.x, q.y)) }
    let topSpan = max(s.wt, 1e-6)
    return pts.map { q in
        var z = q.y
        if s.crown != 0, s.zt > s.zm {
            let t = clamp01((z - s.zm) / (s.zt - s.zm))
            z += s.crown * max(0, 1 - (q.x / topSpan) * (q.x / topSpan)) * t * t
        }
        let w = max(s.wm, 1e-6)
        let y = s.y + s.bulge * max(0, 1 - (q.x / w) * (q.x / w))
        return V3(q.x, y, z)
    }
}

/// Распределение станций по длине: гуще к концам, где скругления.
func stations(_ a: Double, _ b: Double, _ n: Int) -> [Double] {
    (0...n).map { i in
        let t = Double(i) / Double(n)
        let e = 0.5 - 0.5 * cos(.pi * t)
        return lerp(a, b, 0.55 * e + 0.45 * t)
    }
}

/// Сетка-меш: строки × столбцы точек, грань — четырёхугольник.
struct MeshPart {
    var positions: [V3] = []
    var normals: [V3] = []
    var indices: [Int: [Int32]] = [:]   // материал → треугольники

    mutating func append(_ other: MeshPart) {
        let base = Int32(positions.count)
        positions += other.positions; normals += other.normals
        for (m, idx) in other.indices { indices[m, default: []] += idx.map { $0 + base } }
    }
}

typealias Classifier = (_ center: V3, _ normal: V3) -> Int

func gridMesh(_ grid: [[V3]], closedRows: Bool = false, closedCols: Bool = true,
              flat: Bool = false, caps: Bool = false, classify: Classifier) -> MeshPart {
    let rows = grid.count, cols = grid[0].count
    let rq = closedRows ? rows : rows - 1
    let cq = closedCols ? cols : cols - 1
    var centroid = V3.zero
    for r in grid { for p in r { centroid += p } }
    centroid /= Double(rows * cols)
    func faceNormal(_ a: V3, _ b: V3, _ c: V3, _ d: V3) -> V3 {
        let n = simd_cross(c - a, d - b)
        let l = simd_length(n)
        return l > 1e-12 ? n / l : V3(0, 0, 1)
    }
    // Ориентация: нормали наружу от центра.
    var sign = 0.0
    for i in 0..<rq { for j in 0..<cq {
        let a = grid[i][j], b = grid[(i + 1) % rows][j], c = grid[(i + 1) % rows][(j + 1) % cols], d = grid[i][(j + 1) % cols]
        sign += simd_dot(simd_cross(b - a, d - a), (a + c) / 2 - centroid)
    } }
    let flip = sign < 0
    var part = MeshPart()
    if flat {
        for i in 0..<rq { for j in 0..<cq {
            let a = grid[i][j]; var b = grid[(i + 1) % rows][j], c = grid[(i + 1) % rows][(j + 1) % cols], d = grid[i][(j + 1) % cols]
            if flip { swap(&b, &d) }
            let n = faceNormal(a, b, c, d)
            if simd_length(simd_cross(c - a, d - b)) < 1e-12 { continue }
            let m = classify((a + b + c + d) / 4, n)
            let base = Int32(part.positions.count)
            part.positions += [a, b, c, d]; part.normals += [n, n, n, n]
            part.indices[m, default: []] += [base, base + 1, base + 2, base, base + 2, base + 3]
        } }
    } else {
        var acc = [V3](repeating: .zero, count: rows * cols)
        var quads: [(Int, Int, Int, Int, Int)] = []
        for i in 0..<rq { for j in 0..<cq {
            let ia = i * cols + j; var ib = ((i + 1) % rows) * cols + j
            let ic = ((i + 1) % rows) * cols + (j + 1) % cols
            var id = i * cols + (j + 1) % cols
            if flip { swap(&ib, &id) }
            let a = grid[ia / cols][ia % cols], b = grid[ib / cols][ib % cols]
            let c = grid[ic / cols][ic % cols], d = grid[id / cols][id % cols]
            let n = simd_cross(c - a, d - b)
            for v in [ia, ib, ic, id] { acc[v] += n }
            let m = classify((a + b + c + d) / 4, faceNormal(a, b, c, d))
            quads.append((ia, ib, ic, id, m))
        } }
        part.positions = grid.flatMap { $0 }
        part.normals = acc.map { simd_length($0) > 1e-12 ? simd_normalize($0) : V3(0, 0, 1) }
        for q in quads {
            part.indices[q.4, default: []] += [Int32(q.0), Int32(q.1), Int32(q.2), Int32(q.0), Int32(q.2), Int32(q.3)]
        }
    }
    if caps && !closedRows {
        for (r, dir) in [(0, -1.0), (rows - 1, 1.0)] {
            let ringPts = grid[r]
            var c = V3.zero
            for p in ringPts { c += p }
            c /= Double(ringPts.count)
            let n = V3(0, dir, 0)
            let base = Int32(part.positions.count)
            part.positions.append(c); part.normals.append(n)
            for p in ringPts { part.positions.append(p); part.normals.append(n) }
            let m = classify(c, n)
            for j in 0..<cols {
                let a = base + 1 + Int32(j), b = base + 1 + Int32((j + 1) % cols)
                let tri = simd_dot(simd_cross(ringPts[j] - c, ringPts[(j + 1) % cols] - c), n) > 0
                    ? [base, a, b] : [base, b, a]
                part.indices[m, default: []] += tri
            }
        }
    }
    return part
}

/// Лофт по сечениям.
func loft(_ sections: [Section], k: Int = 10, seg: Int = 4, flat: Bool = false,
          classify: @escaping Classifier) -> MeshPart {
    gridMesh(sections.map { ring($0, k: k, seg: seg) }, flat: flat, caps: true, classify: classify)
}

/// Тело вращения вокруг оси, параллельной x (колёса).
func revolve(profile: [(r: Double, a: Double)], center: V3, steps: Int = 48,
             classify: @escaping Classifier) -> MeshPart {
    let grid: [[V3]] = (0..<steps).map { s in
        let th = Double(s) / Double(steps) * 2 * .pi
        return profile.map { p in center + V3(p.a, p.r * cos(th), p.r * sin(th)) }
    }
    return gridMesh(grid, closedRows: true, closedCols: true, classify: classify)
}

/// Эллипсоид-«капля» сеткой: полуоси, сжатие к концам по y.
func ellipsoid(center: V3, radii: V3, rows: Int = 24, cols: Int = 32, power: Double = 2,
               classify: @escaping Classifier) -> MeshPart {
    let grid: [[V3]] = (0...rows).map { i in
        let v = Double(i) / Double(rows) * .pi
        return (0..<cols).map { j in
            let u = Double(j) / Double(cols) * 2 * .pi
            let e = 2 / power
            func sp(_ x: Double) -> Double { copysign(pow(abs(x), e), x) }
            let sv = sp(sin(v)), cv = sp(cos(v))
            return center + V3(radii.x * sv * sp(cos(u)), -radii.y * cv, radii.z * sv * sp(sin(u)))
        }
    }
    return gridMesh(grid, closedRows: false, closedCols: true, classify: classify)
}

/// Брусок со скруглёнными рёбрами (через лофт): центр, полуразмеры.
func roundedBox(center: V3, half: V3, r: Double, classify: @escaping Classifier) -> MeshPart {
    let n = 10
    let ys = stations(-half.y, half.y, n)
    let secs = ys.map { y -> Section in
        let d = half.y - abs(y)
        let shrink = d < r ? r - (r * r - (r - d) * (r - d)).squareRoot() : 0
        let w = max(0.001, half.x - shrink), zt = max(center.z - half.z + 0.001, center.z + half.z - shrink)
        return Section(y: center.y + y, wb: w, zb: center.z - half.z + shrink * 0.2, wm: w,
                       zm: center.z, wt: w, zt: zt, rb: r, rm: 0.0001, rt: r)
    }
    var part = loft(secs, k: 6, seg: 2, classify: classify)
    for i in part.positions.indices { part.positions[i].x += center.x }
    return part
}

func translated(_ p: MeshPart, _ d: V3) -> MeshPart {
    var q = p; q.positions = p.positions.map { $0 + d }; return q
}

func mirroredX(_ p: MeshPart) -> MeshPart {
    var q = p
    q.positions = p.positions.map { V3(-$0.x, $0.y, $0.z) }
    q.normals = p.normals.map { V3(-$0.x, $0.y, $0.z) }
    for (m, idx) in p.indices {
        var out: [Int32] = []
        for t in stride(from: 0, to: idx.count, by: 3) { out += [idx[t], idx[t + 2], idx[t + 1]] }
        q.indices[m] = out
    }
    return q
}

/// Меш → узел сцены с материалами по индексам.
func node(_ part: MeshPart, materials: [Int: SCNMaterial]) -> SCNNode {
    let v = SCNGeometrySource(vertices: part.positions.map(scn))
    let n = SCNGeometrySource(normals: part.normals.map(scn))
    let uv = SCNGeometrySource(textureCoordinates: part.positions.map {
        CGPoint(x: $0.x / Livery.span + 0.5, y: 0.5 - $0.y / Livery.span)
    })
    var elements: [SCNGeometryElement] = [], mats: [SCNMaterial] = []
    for key in part.indices.keys.sorted() {
        guard let idx = part.indices[key], !idx.isEmpty, let m = materials[key] else { continue }
        elements.append(SCNGeometryElement(indices: idx, primitiveType: .triangles))
        mats.append(debugMaterials ? debugMaterial(key) : m)
    }
    let g = SCNGeometry(sources: [v, n, uv], elements: elements)
    g.materials = mats
    return SCNNode(geometry: g)
}

let debugMaterials = ProcessInfo.processInfo.environment["CURSOR_DEBUG"] != nil

func debugMaterial(_ key: Int) -> SCNMaterial {
    let palette: [NSColor] = [.systemBlue, .cyan, .systemPurple, .systemOrange, .white, .darkGray, .yellow,
                              .magenta, .black, .gray, .systemGreen, .systemTeal, .brown, .lightGray, .systemIndigo, .systemPink]
    let m = SCNMaterial()
    m.lightingModel = .lambert
    m.diffuse.contents = palette[key % palette.count]
    m.isDoubleSided = true
    return m
}
