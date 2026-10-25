//
//  Car3DModel.swift
//  RadarMap
//
//  Машина «в 3D» для значка «я» (29.B, как у Amap): одна простая объёмная
//  модель (кузов, кабина со стёклами, колёса, фары), из которой рисуются
//  кадры с нескольких ракурсов — по повороту машины относительно экрана и по
//  наклону карты. Значок не вращается картинкой целиком, как плоские: под
//  наклоном машина, повёрнутая боком, должна показать бок, а не сплющенную
//  крышу. Между кадрами (шаг `yawStep`) остаток поворота добирается
//  поворотом картинки — не больше половины шага.
//
//  Правила значка те же, что у остальных (CursorStyle): нос вверх в кадре
//  без поворота, свет слева сверху (в экране, не в модели — поворот машины
//  не переворачивает свет), белый кант по силуэту, тень без сдвига, зеркальный
//  силуэт кадра без поворота, и ни одного красного: красный на карте — камера.
//  Задние фонари поэтому дымчато-графитовые, а не красные.
//
//  Проекция ортогональная: камера смотрит на машину сверху-сзади экрана под
//  наклоном карты. Грани, повёрнутые от камеры, отбрасываются, остальные
//  рисуются от дальних к ближним.
//
//  Чистая геометрия — покрыто Car3DModelTests.
//

import CoreGraphics
import Foundation

nonisolated enum Car3DModel {

    /// Деталь — свой цвет.
    enum Part: Int, CaseIterable, Sendable {
        case body, hood, roof, glass, wheel, headlight, taillight

        /// Базовый цвет детали (RGB), до освещения. Кузов — синий «я»
        /// приложения (MapPalette.meBody): белый кант на белой машине пропал бы.
        var rgb: (r: Double, g: Double, b: Double) {
            switch self {
            case .body:      return (0.16, 0.52, 0.96)
            case .hood:      return (0.20, 0.57, 0.98)
            case .roof:      return (0.30, 0.64, 1.00)
            case .glass:     return (0.15, 0.22, 0.33)
            case .wheel:     return (0.09, 0.10, 0.12)
            case .headlight: return (0.96, 0.97, 0.92)
            case .taillight: return (0.22, 0.24, 0.28)
            }
        }
    }

    struct Point3: Equatable, Sendable {
        var x, y, z: Double
    }

    struct Face: Sendable {
        let points: [Point3]
        let part: Part
    }

    /// Грань на экране: точки в пунктах относительно центра машины на земле
    /// (y вниз), яркость 0…1 и глубина (больше — ближе к камере).
    struct Projected: Sendable {
        let points: [CGPoint]
        let part: Part
        let light: Double
        let depth: Double
    }

    // MARK: - Модель (метры: x вправо, y вперёд, z вверх; центр — на земле)

    static let length = 4.4
    static let width = 1.84

    /// Многоугольник плана со скосами углов, против часовой стрелки.
    private static func plan(halfWidth w: Double, front: Double, back: Double,
                             frontChamfer cf: Double, backChamfer cb: Double) -> [(Double, Double)] {
        [(w, back + cb), (w, front - cf), (w - cf, front), (-w + cf, front), (-w, front - cf),
         (-w, back + cb), (-w + cb, back), (w - cb, back)]
    }

    /// Призма между двумя планами (низ и верх с одинаковым числом вершин):
    /// боковые грани и крышка. Дна нет — камера всегда сверху.
    private static func prism(bottom: [(Double, Double)], zBottom: Double,
                              top: [(Double, Double)], zTop: Double,
                              side: Part, cap: Part) -> [Face] {
        var out: [Face] = []
        let n = bottom.count
        for i in 0..<n {
            let j = (i + 1) % n
            out.append(Face(points: [Point3(x: bottom[i].0, y: bottom[i].1, z: zBottom),
                                     Point3(x: bottom[j].0, y: bottom[j].1, z: zBottom),
                                     Point3(x: top[j].0, y: top[j].1, z: zTop),
                                     Point3(x: top[i].0, y: top[i].1, z: zTop)], part: side))
        }
        out.append(Face(points: top.map { Point3(x: $0.0, y: $0.1, z: zTop) }, part: cap))
        return out
    }

    static let faces: [Face] = {
        let half = length / 2, w = width / 2
        var out: [Face] = []
        // Кузов: борта и капот-багажник; верх чуть уже низа — покатые борта.
        let lower = plan(halfWidth: w, front: half, back: -half, frontChamfer: 0.32, backChamfer: 0.2)
        let upper = plan(halfWidth: w - 0.06, front: half - 0.12, back: -half + 0.08,
                         frontChamfer: 0.34, backChamfer: 0.22)
        out += prism(bottom: lower, zBottom: 0.24, top: upper, zTop: 0.80, side: .body, cap: .hood)
        // Колёса — только наружные боковины, чуть наружу из-под кузова: видны
        // сбоку и под наклоном; остальные грани колеса всё равно под кузовом.
        for side in [-1.0, 1.0] {
            let x = (w + 0.04) * side
            for axle in [1.38, -1.32] {
                let a = axle - 0.34, b = axle + 0.34
                // Обход против часовой, если смотреть снаружи (с той стороны).
                let ys = side > 0 ? [a, b] : [b, a]
                out.append(Face(points: [Point3(x: x, y: ys[0], z: 0), Point3(x: x, y: ys[1], z: 0),
                                         Point3(x: x, y: ys[1], z: 0.62), Point3(x: x, y: ys[0], z: 0.62)],
                                part: .wheel))
            }
        }
        // Фары — на передней грани, фонари — полосой на задней (графит).
        let front = half - 0.12 + 0.012, back = -half + 0.08 - 0.012
        for side in [-1.0, 1.0] {
            let a = 0.36 * side, b = 0.66 * side
            let (left, right) = (min(a, b), max(a, b))
            // Спереди +x — слева от зрителя: обход справа налево по низу.
            out.append(Face(points: [Point3(x: right, y: front, z: 0.56), Point3(x: left, y: front, z: 0.56),
                                     Point3(x: left, y: front, z: 0.70), Point3(x: right, y: front, z: 0.70)],
                            part: .headlight))
        }
        out.append(Face(points: [Point3(x: -0.7, y: back, z: 0.58), Point3(x: 0.7, y: back, z: 0.58),
                                 Point3(x: 0.7, y: back, z: 0.70), Point3(x: -0.7, y: back, z: 0.70)],
                        part: .taillight))
        // Кабина: стёкла по бокам, крыша сверху — трапеция назад.
        let cabinBottom = [(w - 0.1, -1.30), (w - 0.1, 0.92), (-w + 0.1, 0.92), (-w + 0.1, -1.30)]
        let cabinTop = [(w - 0.24, -0.98), (w - 0.24, 0.30), (-w + 0.24, 0.30), (-w + 0.24, -0.98)]
        out += prism(bottom: cabinBottom, zBottom: 0.80, top: cabinTop, zTop: 1.40, side: .glass, cap: .roof)
        return out
    }()

    /// Порядок рисования по деталям: кузов, колёса поверх его бортов (они
    /// снаружи), фары на его гранях, кабина сверху. Сортировка граней по
    /// одной глубине здесь врёт: капот — один большой многоугольник под
    /// всей машиной, и дальний край заднего колеса или лобовое стекло
    /// оказывались «дальше» него и пропадали под капотом.
    static func layer(_ part: Part) -> Int {
        switch part {
        case .body, .hood:           return 0
        case .wheel:                 return 1
        case .headlight, .taillight: return 2
        case .glass, .roof:          return 3
        }
    }

    // MARK: - Проекция

    /// Свет — в координатах экрана после поворота машины: слева, сверху и
    /// чуть из-за спины зрителя.
    private static let lightDirection: Point3 = {
        let v = Point3(x: -0.55, y: -0.3, z: 0.78)
        let n = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return Point3(x: v.x / n, y: v.y / n, z: v.z / n)
    }()

    /// Грани кадра в порядке рисования: по деталям (`layer`), внутри — от
    /// дальних к ближним. `yaw` — поворот машины по часовой
    /// от верха экрана, `pitch` — наклон карты (0 — сверху), градусы;
    /// `scale` — пунктов на метр.
    static func project(yaw: Double, pitch: Double, scale: Double) -> [Projected] {
        let psi = yaw * .pi / 180, phi = min(max(0, pitch), 85) * .pi / 180
        let (cs, sn) = (cos(psi), sin(psi))
        let (cp, sp) = (cos(phi), sin(phi))
        func turn(_ p: Point3) -> Point3 {
            Point3(x: p.x * cs + p.y * sn, y: -p.x * sn + p.y * cs, z: p.z)
        }
        let view = Point3(x: 0, y: -sp, z: cp)
        var out: [Projected] = []
        for face in faces {
            let pts = face.points.map(turn)
            guard pts.count >= 3, let normal = Self.normal(pts) else { continue }
            let facing = normal.x * view.x + normal.y * view.y + normal.z * view.z
            guard facing > 1e-6 else { continue }
            let screen = pts.map { CGPoint(x: $0.x * scale, y: -($0.y * cp + $0.z * sp) * scale) }
            let depth = pts.reduce(0) { $0 + (-$1.y * sp + $1.z * cp) } / Double(pts.count)
            let diffuse = max(0, normal.x * lightDirection.x + normal.y * lightDirection.y
                              + normal.z * lightDirection.z)
            out.append(Projected(points: screen, part: face.part, light: 0.55 + 0.45 * diffuse, depth: depth))
        }
        return out.sorted {
            let (a, b) = (layer($0.part), layer($1.part))
            return a != b ? a < b : $0.depth < $1.depth
        }
    }

    /// Нормаль многоугольника наружу (вершины против часовой, если смотреть снаружи).
    private static func normal(_ p: [Point3]) -> Point3? {
        // Метод Ньюэлла — устойчив к почти вырожденным граням.
        var n = Point3(x: 0, y: 0, z: 0)
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            n.x += (a.y - b.y) * (a.z + b.z)
            n.y += (a.z - b.z) * (a.x + b.x)
            n.z += (a.x - b.x) * (a.y + b.y)
        }
        let length = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
        guard length > 1e-9 else { return nil }
        return Point3(x: n.x / length, y: n.y / length, z: n.z / length)
    }

    // MARK: - Кадры

    /// Шаг кадров по повороту, градусы: 24 кадра на круг.
    static let yawStep = 15.0
    /// Наклоны, под которые кадры нарисованы (0 — сверху … потолок карты).
    static let pitches: [Double] = [0, 20, 35, 48, 58]

    struct Frame: Hashable, Sendable {
        /// Номер кадра по повороту, 0 ..< 360/yawStep.
        let yaw: Int
        /// Номер наклона в `pitches`.
        let pitch: Int
    }

    /// Кадр для поворота машины относительно экрана и наклона карты, и
    /// остаток поворота (градусы, |остаток| ≤ yawStep/2), который добирает
    /// поворот картинки.
    static func frame(relativeYaw: Double, pitch: Double) -> (frame: Frame, residual: Double) {
        let count = Int((360 / yawStep).rounded())
        var yaw = relativeYaw.truncatingRemainder(dividingBy: 360)
        if yaw < 0 { yaw += 360 }
        let index = Int((yaw / yawStep).rounded()) % count
        var residual = yaw - Double(index) * yawStep
        if residual > 180 { residual -= 360 }
        let nearest = pitches.indices.min { abs(pitches[$0] - pitch) < abs(pitches[$1] - pitch) } ?? 0
        return (Frame(yaw: index, pitch: nearest), residual)
    }
}
