//
//  SketchNode.swift
//  RadarMap
//
//  Перекрёсток на схеме — это ПЛОЩАДЬ между кромками сходящихся дорог, а не
//  круг в точке их встречи.
//
//  Диск самой широкой дороги стоял здесь с самого начала и на прямом стыке
//  двух кусков работает. На настоящем перекрёстке — нет, и это замерено, а не
//  предположено: разбирая ту же беду в панели, круглые торцы вместо срезанных
//  дали 31 дырку против 30, в пределах шума. Круг закрывает только то, что
//  укладывается в его радиус; когда четыре дороги разной ширины сходятся под
//  разными углами, площадь между их краями не принадлежит ни одной осевой, и
//  на схеме остаётся тёмный клин — улица выглядит разорванной ровно там, где
//  водитель принимает решение.
//

import SwiftUI

struct SketchNode {
    let point: CGPoint
    var width: CGFloat
    var color: Color
    var ends: Int = 0
    /// Точки кромок всех сходящихся дорог. Из них и складывается асфальт.
    var edges: [CGPoint] = []
    /// Что сходится в узле. Нужно фаскам: у каждого подхода своя ширина и своё
    /// направление, и расширять их одинаково нельзя.
    var arms: [Arm] = []

    struct Arm {
        /// Соседняя вершина — она задаёт, куда дорога уходит из узла.
        let towards: CGPoint
        /// Ширина проезжей части В МЕТРАХ сцены, а не в пунктах экрана.
        let width: CGFloat
    }

    /// Насколько далеко от узла тянется фаска, метров. Восемь — стоп-линия
    /// плюс запас: короче она не читается, длиннее превращает улицу в воронку.
    static let flareMeters: CGFloat = 8
    /// Расширение на сторону, метров. Полтора — половина полосы.
    static let flareWiden: CGFloat = 1.5

    /// Трапеции подходов: от обычной ширины в восьми метрах от узла к
    /// расширенной у самого узла.
    ///
    /// Расширение ограничено четвертью ширины И шириной самого узла. Без
    /// первого ограничения дворовый проезд у проспекта раздувается вдвое и
    /// выглядит съездом с развязки; без второго фаска выпирает за асфальт
    /// перекрёстка, то есть подводит улицу не к нему, а мимо.
    func flares() -> [[CGPoint]] {
        guard arms.count >= 3, let widest = arms.map(\.width).max() else { return [] }
        var out: [[CGPoint]] = []
        for arm in arms {
            let widen = min(Self.flareWiden, arm.width / 4,
                            max(0, (widest - arm.width) / 2))
            if widen <= 0.2 { continue }
            let dx = arm.towards.x - point.x
            let dy = arm.towards.y - point.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { continue }
            let step = min(Self.flareMeters, length)
            let far = CGPoint(x: point.x + dx / length * step,
                              y: point.y + dy / length * step)
            let outer = Self.edgePoints(at: point, towards: arm.towards,
                                        width: arm.width + widen * 2)
            let inner = Self.edgePoints(at: far, towards: arm.towards,
                                        width: arm.width)
            guard outer.count == 2, inner.count == 2 else { continue }
            out.append([outer[0], inner[0], inner[1], outer[1]])
        }
        return out
    }

    /// Две кромки дороги в узле: центр ± половина ширины ПОПЕРЁК её
    /// направления. Направление берём по соседней вершине — она и задаёт, куда
    /// дорога уходит из узла.
    static func edgePoints(at node: CGPoint, towards inner: CGPoint,
                           width: CGFloat) -> [CGPoint] {
        let dx = inner.x - node.x
        let dy = inner.y - node.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return [] }
        let across = CGPoint(x: -dy / length, y: dx / length)
        let half = width / 2
        return [CGPoint(x: node.x + across.x * half, y: node.y + across.y * half),
                CGPoint(x: node.x - across.x * half, y: node.y - across.y * half)]
    }

    /// Выпуклая оболочка по Эндрю. nil — точек меньше трёх или все на одной
    /// прямой: тогда фигуры нет и заливать нечего.
    static func hull(_ points: [CGPoint]) -> [CGPoint]? {
        guard points.count >= 3 else { return nil }
        let sorted = points.sorted {
            $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x
        }

        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        func half(_ source: [CGPoint]) -> [CGPoint] {
            var out: [CGPoint] = []
            for point in source {
                while out.count > 1,
                      cross(out[out.count - 2], out[out.count - 1], point) <= 0 {
                    out.removeLast()
                }
                out.append(point)
            }
            out.removeLast()
            return out
        }

        let shell = half(sorted) + half(sorted.reversed())
        return shell.count >= 3 ? shell : nil
    }
}
