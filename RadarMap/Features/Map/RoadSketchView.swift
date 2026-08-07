//
//  RoadSketchView.swift
//  RadarMap
//
//  Отрисовка схемы «где камера» для приборки: чертим сами, без карты и без
//  сети.
//
//  Устройство повторяет архитектуру RoadSketch: сцена «север вверху»
//  растеризуется ОДИН раз (Canvas + drawingGroup → текстура), а движение
//  между GPS-тиками изображают три transform'а — сдвиг (я еду), поворот (мой
//  курс — вверх) и зум (охват по дистанции до камеры). Их анимирует
//  SketchState, компоновщик считает на GPU: ни перерисовки, ни работы CPU
//  на кадр. Именно поэтому приборка остаётся самым дешёвым экраном
//  приложения — и при этом движется плавно, а не прыжками раз в секунду.
//
//  Порядок transform'ов значим: offset (я — в центр растра) → rotation
//  (вокруг меня) → scale (вокруг меня) → position (я — в точку «я» вида).
//  Математика продублирована в RoadSketch.screenPoint и проверена тестами.
//

import CoreLocation
import SwiftUI

struct RoadSketchView: View {
    let scene: RoadSketch.Scene
    let state: SketchState
    /// Цвет тревоги — тот же, что у дистанции рядом: схема и цифра не должны
    /// расходиться в оценке близости.
    var tint: Color = Theme.accent

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let pivot = CGPoint(x: size.width / 2,
                                y: size.height * RoadSketch.meY)
            // Пунктов на метр растра: по высоте вид покрывает spanBucket метров.
            let k = size.height / scene.spanBucket
            // Сторона квадрата растра: круг видимости вокруг «я» при любом
            // повороте (до дальнего угла вида), с запасом на сжатие
            // scaleEffect (≤ 1/bucketRatio) и на дрейф до пересборки растра.
            let viewRadius = hypot(size.width / 2, size.height * RoadSketch.meY)
            let side = 2 * (viewRadius * RoadSketch.bucketRatio
                            + RoadSketch.driftMeters(forSpan: scene.spanAtBuild) * k)

            ZStack {
                world(side: side, k: k)
                    .position(pivot)
                vignette
                MeArrow()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.6), radius: 3)
                    .frame(width: 26, height: 30)
                    .position(pivot)
                scaleBar(height: size.height)
            }
            .clipped()
        }
        .accessibilityHidden(true)   // цифру и сторону рядом VoiceOver уже читает
    }

    /// Мир: растр сцены и кольцо тревожной камеры, под общими transform'ами —
    /// кольцо живёт в мировых координатах и движется вместе с дорогами само.
    private func world(side: CGFloat, k: CGFloat) -> some View {
        ZStack {
            SketchRaster(scene: scene, k: k)
                .equatable()
                .frame(width: side, height: side)
            if let camera = scene.alertCamera {
                let at = CGPoint(x: side / 2 + camera.x * k,
                                 y: side / 2 - camera.y * k)
                Circle()
                    .fill(tint.opacity(0.20))
                    .frame(width: 44, height: 44)
                    .position(at)
                Circle()
                    .stroke(tint, lineWidth: 3)
                    .frame(width: 24, height: 24)
                    .position(at)
            }
        }
        .frame(width: side, height: side)
        .offset(x: -state.meOffset.width * k, y: state.meOffset.height * k)
        .rotationEffect(.degrees(-state.courseDegrees))
        .scaleEffect(scene.spanBucket / state.spanMeters)
    }

    /// Виньетка: дороги растворяются у краёв, а не обрываются. Фон приборки
    /// чёрный, поэтому чёрные градиенты поверх — это то же затухание, что
    /// маска, только без офскрин-прохода.
    private var vignette: some View {
        Color.clear
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black, .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 26)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 26)
            }
            .overlay(alignment: .leading) {
                LinearGradient(colors: [.black, .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 22)
            }
            .overlay(alignment: .trailing) {
                LinearGradient(colors: [.clear, .black],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 22)
            }
            .allowsHitTesting(false)
    }

    /// Линейка масштаба: схема без масштаба заставляла бы угадывать, далеко
    /// ли перекрёсток. Ширина следует за охватом и анимируется вместе с ним.
    private func scaleBar(height: CGFloat) -> some View {
        let meters = RoadSketch.scaleBarMeters(forSpan: state.spanMeters)
        let width = CGFloat(meters) * height / CGFloat(state.spanMeters)
        return HStack(spacing: 6) {
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: width, height: 2)
            Text(Formatting.distance(meters))
                .font(.rounded(11, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .bottomLeading)
        .padding(.leading, 30)
        .padding(.bottom, 8)
        .allowsHitTesting(false)
    }
}

/// Стрелка «я»: всегда строго вверх — схема повёрнута по ходу движения,
/// поэтому «вверх» и есть «куда я еду». Отдельным слоем, а не в растре:
/// мир вращается, стрелка — никогда.
private struct MeArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        var path = Path()
        path.move(to: CGPoint(x: cx, y: cy - 15))
        path.addLine(to: CGPoint(x: cx - 11, y: cy + 11))
        path.addLine(to: CGPoint(x: cx, y: cy + 5))
        path.addLine(to: CGPoint(x: cx + 11, y: cy + 11))
        path.closeSubpath()
        return path
    }
}

/// Растр сцены. Equatable — SwiftUI не трогает Canvas, пока сцена та же:
/// перерисовка случается на пересборке сцены, а не на каждом тике.
private struct SketchRaster: View, Equatable {
    let scene: RoadSketch.Scene
    let k: CGFloat

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.k == rhs.k && lhs.scene == rhs.scene
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            func at(_ point: CGPoint) -> CGPoint {
                CGPoint(x: center.x + point.x * k, y: center.y - point.y * k)
            }
            func path(_ points: [CGPoint]) -> Path {
                var path = Path()
                guard let first = points.first else { return path }
                path.move(to: at(first))
                for point in points.dropFirst() { path.addLine(to: at(point)) }
                return path
            }

            // Окрестная сеть — самый нижний слой. Рисуем строго по возрастанию
            // уровня: сначала всё, что по земле, потом эстакады. Только так
            // камера НА мосту отличима от камеры на дороге ПОД ним — а это
            // разные камеры и разное решение водителя.
            //
            // Внутри уровня — проходами, а не по линии: сперва ВСЕ подложки
            // мостов, потом ВСЕ кромки, потом ВСЕ заливки. Иначе кромка одной
            // дороги ложилась бы поверх заливки соседней, и каждый перекрёсток
            // рассекался бы швами.
            let byLevel = Dictionary(grouping: scene.network.filter { $0.points.count >= 2 },
                                     by: \.level)
            for level in byLevel.keys.sorted() {
                let lines = byLevel[level]!
                // Мост отбивается тёмной «подложкой» шире самой линии: она
                // разрывает то, что проходит под ним, и пересечение читается
                // как развязка, а не как перекрёсток.
                if level > 0 {
                    for line in lines {
                        context.stroke(path(line.points), with: .color(.black),
                                       style: .init(lineWidth: width(for: line) + 8,
                                                    lineCap: .butt, lineJoin: .round))
                    }
                }
                // Кромка: полотно читается как дорога с краями, а не как линия.
                // Только там, где класс известен по-настоящему; тоннелям
                // кромка не рисуется — они и так пунктиром «под землёй».
                for line in lines where line.isDetailed && level >= 0 {
                    context.stroke(path(line.points),
                                   with: .color(.white.opacity(0.08)),
                                   style: .init(lineWidth: width(for: line) + 4,
                                                lineCap: .round, lineJoin: .round))
                }
                for line in lines {
                    context.stroke(path(line.points),
                                   with: .color(fill(for: line)),
                                   style: .init(lineWidth: width(for: line),
                                                lineCap: .round, lineJoin: .round,
                                                dash: level < 0 ? [10, 8] : []))
                }
                // Стрелки односторонних — редкие шевроны по ходу точек
                // (сервер уже развернул oneway=-1 по движению).
                for line in lines where line.isOneWay && line.isDetailed && level >= 0 {
                    chevrons(context: &context, along: line.points.map(at))
                }
            }

            // Трек — самый бледный слой: он объясняет, откуда я приехал, и не
            // должен спорить с тем, что впереди.
            if scene.track.count >= 2 {
                context.stroke(path(scene.track),
                               with: .color(.white.opacity(0.18)),
                               style: .init(lineWidth: 5, lineCap: .round,
                                            lineJoin: .round))
            }

            // Дорога тревожной камеры. Пунктиром — если она предположена по
            // оси, а не измерена снапом: обещать точность, которой нет, нельзя.
            if scene.road.count >= 2 {
                context.stroke(path(scene.road),
                               with: .color(.white.opacity(scene.roadIsMeasured ? 0.30 : 0.16)),
                               style: .init(lineWidth: 22, lineCap: .round,
                                            lineJoin: .round,
                                            dash: scene.roadIsMeasured ? [] : [14, 10]))
                context.stroke(path(scene.road),
                               with: .color(.white.opacity(0.10)),
                               style: .init(lineWidth: 1.5, lineCap: .round,
                                            dash: [10, 12]))   // осевая разметка
            }

            // Маршрут — единственная цветная линия: это «куда я еду».
            if scene.route.count >= 2 {
                context.stroke(path(scene.route),
                               with: .color(Theme.success.opacity(0.9)),
                               style: .init(lineWidth: 9, lineCap: .round,
                                            lineJoin: .round))
            }

            // ВСЕ камеры охвата — точками на своих местах: на ферганском
            // чорраха их четыре, и одна точка прятала три остальные. Тревожную
            // выделяет кольцо (оверлей вью) — сама точка у всех одинаковая.
            for dot in scene.cameras {
                let point = at(dot.point)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6,
                                                    width: 12, height: 12)),
                             with: .color(Theme.danger.opacity(0.85)))
                context.stroke(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6,
                                                      width: 12, height: 12)),
                               with: .color(.black.opacity(0.6)), lineWidth: 1.5)
            }
        }
        .drawingGroup()   // одна текстура: transform'ы крутят её без перерисовки
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

    /// Тон полотна: крупные дороги ярче и чуть теплее, дворы холоднее и
    /// тусклее — глубина вместо паутины одинаковых линий. Тоннель приглушён:
    /// он «под землёй». Незнающий класса источник — прежний ровный тон.
    private func fill(for line: RoadSketch.Line) -> Color {
        guard line.isDetailed else { return .white.opacity(line.level < 0 ? 0.10 : 0.20) }
        if line.level < 0 { return .white.opacity(0.10) }
        switch line.kind {
        case .motorway, .trunk:
            return Color(red: 1.0, green: 0.97, blue: 0.90).opacity(0.34)
        case .primary:
            return Color(red: 1.0, green: 0.98, blue: 0.93).opacity(0.30)
        case .secondary:        return .white.opacity(0.26)
        case .tertiary:         return .white.opacity(0.21)
        case .residential:      return .white.opacity(0.15)
        case .service:          return .white.opacity(0.11)
        case .pedestrian, .unknown: return .white.opacity(0.13)
        }
    }

    /// Шевроны направления на односторонней: каждые ~90 пт, остриём по ходу
    /// точек. Редкие и бледные: это подсказка, а не разметка.
    private func chevrons(context: inout GraphicsContext, along points: [CGPoint]) {
        guard points.count >= 2 else { return }
        let step: CGFloat = 90
        var nextAt: CGFloat = step / 2
        var travelled: CGFloat = 0
        for index in 1..<points.count {
            let from = points[index - 1], to = points[index]
            let dx = to.x - from.x, dy = to.y - from.y
            let length = hypot(dx, dy)
            guard length > 0.5 else { continue }
            while nextAt <= travelled + length {
                let f = (nextAt - travelled) / length
                let tip = CGPoint(x: from.x + dx * f, y: from.y + dy * f)
                let ux = dx / length, uy = dy / length      // по ходу
                let px = -uy, py = ux                        // поперёк
                var chevron = Path()
                chevron.move(to: CGPoint(x: tip.x - ux * 5 - px * 4,
                                         y: tip.y - uy * 5 - py * 4))
                chevron.addLine(to: tip)
                chevron.addLine(to: CGPoint(x: tip.x - ux * 5 + px * 4,
                                            y: tip.y - uy * 5 + py * 4))
                context.stroke(chevron, with: .color(.white.opacity(0.35)),
                               style: .init(lineWidth: 1.8, lineCap: .round,
                                            lineJoin: .round))
                nextAt += step
            }
            travelled += length
        }
    }
}
