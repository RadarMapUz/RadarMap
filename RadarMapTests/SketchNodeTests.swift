//
//  SketchNodeTests.swift
//  RadarMapTests
//

import CoreGraphics
import SwiftUI
import Testing

@testable import RadarMap

@Suite("Перекрёсток — площадь между кромками, а не круг")
struct SketchNodeTests {

    @Test("Кромки лежат поперёк направления дороги")
    func edgesAcross() {
        let edges = SketchNode.edgePoints(at: .zero,
                                          towards: CGPoint(x: 10, y: 0),
                                          width: 8)
        #expect(edges.count == 2)
        // Дорога уходит вправо — кромки обязаны разойтись по вертикали.
        #expect(abs(edges[0].y - 4) < 0.001)
        #expect(abs(edges[1].y + 4) < 0.001)
        #expect(abs(edges[0].x) < 0.001)
    }

    @Test("Вырожденное направление кромок не даёт")
    func degenerate() {
        #expect(SketchNode.edgePoints(at: .zero, towards: .zero, width: 8).isEmpty)
    }

    @Test("Оболочка накрывает сам узел")
    func hullCoversTheNode() throws {
        // Три дороги под разными углами — тот самый случай, где диск оставлял
        // клинья: площадь между кромками не принадлежит ни одной осевой.
        var points: [CGPoint] = []
        for towards in [CGPoint(x: 10, y: 0), CGPoint(x: -10, y: 2),
                        CGPoint(x: 0, y: -10)] {
            points += SketchNode.edgePoints(at: .zero, towards: towards, width: 8)
        }
        let hull = try #require(SketchNode.hull(points))
        #expect(hull.count >= 3)
        let minX = hull.map(\.x).min() ?? 0
        let maxX = hull.map(\.x).max() ?? 0
        let minY = hull.map(\.y).min() ?? 0
        let maxY = hull.map(\.y).max() ?? 0
        #expect(minX < 0 && maxX > 0 && minY < 0 && maxY > 0)
    }

    @Test("Оболочка — площадь между кромками, а не круг по самой широкой дороге")
    func hullBeatsTheDisc() throws {
        // Ради этого замена и делалась. Прежняя редакция теста требовала
        // «оболочка ШИРЕ круга» — и это невыполнимо по построению, а не по
        // недоделке: edgePoints кладёт кромку ровно на полуширину от узла,
        // значит дальше самой широкой дороги оболочка не уходит НИКОГДА, а
        // flares() расширяет только узкие подходы (widen ограничен
        // (widest - width) / 2, у самой широкой он ноль). Тест падал на этом
        // с момента появления.
        //
        // Настоящая претензия к кругу обратная и именно она проверяется:
        // круг ЛИШНЕЕ красит. Диск радиуса самой широкой дороги накрывает
        // диагональ, где асфальта нет, — на схеме это залитый угол вместо
        // перекрёстка. Оболочка тесней круга и при этом кромку самой широкой
        // дороги не срезает.
        var points: [CGPoint] = []
        points += SketchNode.edgePoints(at: .zero, towards: CGPoint(x: 10, y: 0),
                                        width: 20)
        points += SketchNode.edgePoints(at: .zero, towards: CGPoint(x: 0, y: 10),
                                        width: 20)
        points += SketchNode.edgePoints(at: .zero, towards: CGPoint(x: 7, y: 7),
                                        width: 6)
        let hull = try #require(SketchNode.hull(points))
        let far = hull.map { ($0.x * $0.x + $0.y * $0.y).squareRoot() }.max() ?? 0

        // Кромку самой широкой дороги (20 / 2) оболочка достаёт ровно.
        #expect(abs(far - 10) < 0.001, "кромка самой широкой дороги срезана")

        // И при этом заметно тесней круга того же охвата.
        var area = 0.0
        for index in hull.indices {
            let a = hull[index]
            let b = hull[(index + 1) % hull.count]
            area += Double(a.x * b.y - b.x * a.y)
        }
        area = abs(area) / 2
        let disc = Double.pi * Double(far) * Double(far)
        #expect(area < disc * 0.8,
                "оболочка заливает почти весь круг — клин на диагонали не убран")
    }

    @Test("Двух точек мало для фигуры")
    func tooFew() {
        #expect(SketchNode.hull([.zero, CGPoint(x: 1, y: 1)]) == nil)
    }

    private func node(widths: [CGFloat]) -> SketchNode {
        var node = SketchNode(point: .zero, width: widths.max() ?? 0,
                              color: .clear)
        let towards = [CGPoint(x: 10, y: 0), CGPoint(x: -10, y: 0),
                       CGPoint(x: 0, y: 10), CGPoint(x: 0, y: -10)]
        for (index, width) in widths.enumerated() {
            node.ends += 1
            node.arms.append(SketchNode.Arm(towards: towards[index], width: width))
        }
        return node
    }

    @Test("Фаска не шире четверти ширины подхода")
    func flareStaysModest() {
        // Иначе дворовый проезд у проспекта раздувается вдвое и выглядит
        // съездом с развязки.
        let narrow: CGFloat = 4
        let made = node(widths: [20, 20, narrow]).flares()
        let last = made.last!
        let width = hypot(last[0].x - last[3].x, last[0].y - last[3].y)
        #expect(width <= narrow + narrow / 2 + 0.001)
    }

    @Test("Фаска не шире самого узла")
    func flareFitsTheJunction() {
        let made = node(widths: [8, 8, 8]).flares()
        // Все подходы одной ширины — расширять некуда, узел не шире их самих.
        #expect(made.isEmpty, "фаска выперла за асфальт перекрёстка")
    }

    @Test("Двух подходов мало для фаски")
    func twoArmsAreNotAJunction() {
        #expect(node(widths: [20, 6]).flares().isEmpty)
    }

    @Test("Фаска сужается по ходу от узла")
    func flareNarrowsAway() throws {
        let made = node(widths: [20, 20, 6]).flares()
        let trapeze = try #require(made.last)
        let atNode = hypot(trapeze[0].x - trapeze[3].x, trapeze[0].y - trapeze[3].y)
        let away = hypot(trapeze[1].x - trapeze[2].x, trapeze[1].y - trapeze[2].y)
        #expect(atNode > away, "трапеция не сужается — это не фаска")
    }

    @Test("Точки на одной прямой фигуры не дают")
    func collinear() {
        let line = (0..<5).map { CGPoint(x: CGFloat($0), y: 0) }
        #expect(SketchNode.hull(line) == nil)
    }
}
