//
//  RoadSketchView.swift
//  RadarMap
//
//  Схема «где камера» для приборки: чертим сами, без карты и без сети.
//
//  Всё, что здесь нарисовано, — измеренные данные: проезжая часть камеры из
//  базы (есть у 3455 камер из 3467), построенный маршрут и собственный трек.
//  Сетки окрестных улиц нет и не будет: дорожного графа на телефоне мы не
//  держим, а рисовать улицы, которых не знаем, — враньё ради красоты.
//
//  Стоимость: один `Canvas` с десятком отрезков против MapKit с тайлами по
//  сети. Приборка — режим «телефон лежит в держателе», и она обязана быть
//  самым дешёвым экраном приложения, а не самым дорогим.
//

import CoreLocation
import SwiftUI

struct RoadSketchView: View {
    let layout: RoadSketch.Layout
    /// Цвет тревоги — тот же, что у дистанции рядом: схема и цифра не должны
    /// расходиться в оценке близости.
    var tint: Color = Theme.accent

    var body: some View {
        Canvas { context, size in
            func path(_ points: [CGPoint]) -> Path {
                var path = Path()
                guard let first = points.first else { return path }
                path.move(to: scaled(first, size))
                for point in points.dropFirst() { path.addLine(to: scaled(point, size)) }
                return path
            }

            // Окрестная сеть — самый нижний слой. Рисуем строго по возрастанию
            // уровня: сначала всё, что по земле, потом эстакады. Только так
            // камера НА мосту отличима от камеры на дороге ПОД ним — а это
            // разные камеры и разное решение водителя.
            for line in layout.network where line.points.count >= 2 {
                let width = self.width(for: line)
                // Мост отбивается тёмной «подложкой» шире самой линии: она
                // разрывает то, что проходит под ним, и пересечение читается
                // как развязка, а не как перекрёсток.
                if line.level > 0 {
                    context.stroke(path(line.points),
                                   with: .color(.black),
                                   style: .init(lineWidth: width + 8,
                                                lineCap: .butt, lineJoin: .round))
                }
                context.stroke(path(line.points),
                               with: .color(.white.opacity(line.level < 0 ? 0.10 : 0.20)),
                               style: .init(lineWidth: width, lineCap: .round, lineJoin: .round,
                                            dash: line.level < 0 ? [10, 8] : []))
            }

            // Трек — самый бледный слой: он объясняет, откуда я приехал, и не
            // должен спорить с тем, что впереди.
            if layout.track.count >= 2 {
                context.stroke(path(layout.track),
                               with: .color(.white.opacity(0.18)),
                               style: .init(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }

            // Дорога камеры. Пунктиром — если она предположена по оси, а не
            // измерена снапом: обещать точность, которой нет, нельзя.
            if layout.road.count >= 2 {
                context.stroke(path(layout.road),
                               with: .color(.white.opacity(layout.roadIsMeasured ? 0.30 : 0.16)),
                               style: .init(lineWidth: 22, lineCap: .round, lineJoin: .round,
                                            dash: layout.roadIsMeasured ? [] : [14, 10]))
                context.stroke(path(layout.road),
                               with: .color(.white.opacity(0.10)),
                               style: .init(lineWidth: 1.5, lineCap: .round,
                                            dash: [10, 12]))   // осевая разметка
            }

            // Маршрут — единственная цветная линия: это «куда я еду».
            if layout.route.count >= 2 {
                context.stroke(path(layout.route),
                               with: .color(Theme.success.opacity(0.9)),
                               style: .init(lineWidth: 9, lineCap: .round, lineJoin: .round))
            }

            // Камера.
            if let camera = layout.camera {
                let point = scaled(camera, size)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 17, y: point.y - 17,
                                                    width: 34, height: 34)),
                             with: .color(tint.opacity(0.22)))
                context.fill(Path(ellipseIn: CGRect(x: point.x - 8, y: point.y - 8,
                                                    width: 16, height: 16)),
                             with: .color(tint))
            }

            // Я — треугольник строго вверх: схема повёрнута по ходу движения,
            // поэтому «вверх» и есть «куда я еду».
            let me = scaled(layout.me, size)
            var arrow = Path()
            arrow.move(to: CGPoint(x: me.x, y: me.y - 15))
            arrow.addLine(to: CGPoint(x: me.x - 11, y: me.y + 11))
            arrow.addLine(to: CGPoint(x: me.x, y: me.y + 5))
            arrow.addLine(to: CGPoint(x: me.x + 11, y: me.y + 11))
            arrow.closeSubpath()
            context.fill(arrow, with: .color(.white))
        }
        .drawingGroup()   // один слой в композиторе вместо десятка примитивов
        .accessibilityHidden(true)   // цифру и сторону рядом VoiceOver уже читает
    }

    private func scaled(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    /// Ширина линии по классу дороги: магистраль толстая, двор тонкий — схема
    /// читается как местность, а не как паутина одинаковых линий.
    ///
    /// Источник, который класса НЕ ЗНАЕТ (индекс лимитов), получает одну
    /// среднюю ширину на всё. Рисовать разную толщину по догадке значило бы
    /// выдавать предположение за измеренное — здесь это так же недопустимо,
    /// как в оповещениях.
    private func width(for line: RoadSketch.Line) -> CGFloat {
        guard line.isDetailed else { return 9 }
        switch line.kind {
        case .motorway, .trunk: return 15
        case .primary:          return 12
        case .secondary:        return 10
        case .tertiary:         return 8
        case .residential:      return 6
        case .service:          return 4
        case .pedestrian, .unknown: return 3
        }
    }
}
