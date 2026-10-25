//
//  RouteProgressBar.swift
//  RadarMap
//
//  Полоса хода маршрута (29.B; с 29.G — горизонтально в нижней панели
//  поездки, как у Яндекса): тонкая шкала, слева старт, справа финиш, отметка
//  «я», отрезки цветом пробок и значки камер маршрута по их месту. Раскладка
//  в долях длины — одна для любой ориентации.
//
//  Цвет отрезка — только по данным: «свободно» зелёное, «медленно» и «стоим» —
//  свои; где данных о пробках нет — нейтральный серый, НЕ зелёный: зелёный
//  сказал бы «едется легко» там, где мы ничего не знаем (та же честность, что
//  у времени в пути: нет данных ≠ ноль задержки).
//
//  Камеры — те, что маршрут вправе назвать своими (RouteCamera.countsAsOurs):
//  доказанно встречная на полосе была бы камерой, которой на нашем пути нет.
//  Значки ближе друг к другу, чем их размер, не рисуются поверх — остаётся
//  первая по ходу (она и ближе).
//
//  Раскладка считается раз на маршрут и на новые пробки, вне главного
//  потока; на тике меняется только отметка «я», и та — шагами в пункт
//  (`step`), чтобы полоса не перерисовывалась на каждом фиксе.
//
//  Чистая логика — покрыто RouteProgressBarTests.
//

import CoreLocation
import Foundation

nonisolated enum RouteProgressBar {

    /// Цвет отрезка.
    enum Tone: Int, Equatable, Sendable {
        case unknown, free, slow, jam

        init(level: Int?) {
            switch level {
            case 1:  self = .free
            case 2:  self = .slow
            case 3:  self = .jam
            default: self = .unknown
            }
        }
    }

    /// Отрезок полосы — доли длины маршрута [from, to).
    struct Segment: Equatable, Sendable {
        var from: Double
        var to: Double
        var tone: Tone
    }

    /// Камера маршрута на полосе.
    struct CameraMark: Equatable, Sendable {
        let id: Int
        let fraction: Double
        let kind: CameraType
    }

    /// Камера на входе: место по маршруту в метрах.
    struct CameraInput: Equatable, Sendable {
        let id: Int
        let along: Double
        let kind: CameraType
    }

    struct Layout: Equatable, Sendable {
        var length: Double
        var segments: [Segment]
        var cameras: [CameraMark]

        static let empty = Layout(length: 0, segments: [], cameras: [])
    }

    /// Раскладка: куски пробок (RouteTraffic.Piece, метры той же меры, что
    /// `length`) заполняются серым «нет данных» между собой; камеры — доли с
    /// прореживанием по `minGap` (доля длины).
    static func layout(length: Double, pieces: [RouteTraffic.Piece], cameras: [CameraInput],
                       minGap: Double) -> Layout {
        guard length > 0, length.isFinite else { return .empty }
        var segments: [Segment] = []
        var cursor = 0.0
        func append(_ from: Double, _ to: Double, _ tone: Tone) {
            guard to > from else { return }
            if let last = segments.last, last.tone == tone, abs(last.to - from) < 1e-9 {
                segments[segments.count - 1].to = to
            } else {
                segments.append(Segment(from: from, to: to, tone: tone))
            }
        }
        for piece in pieces.sorted(by: { $0.from < $1.from }) {
            let from = min(1, max(cursor, piece.from / length))
            let to = min(1, max(from, piece.to / length))
            append(cursor, from, .unknown)
            append(from, to, Tone(level: piece.level))
            cursor = max(cursor, to)
        }
        append(cursor, 1, .unknown)

        let marks = cameras.sorted(by: { $0.along < $1.along }).compactMap { camera -> CameraMark? in
            let fraction = camera.along / length
            guard fraction >= 0, fraction <= 1 else { return nil }
            return CameraMark(id: camera.id, fraction: fraction, kind: camera.kind)
        }
        return Layout(length: length, segments: segments, cameras: thinned(marks, minGap: minGap))
    }

    /// Значки ближе `minGap` (доля длины) к предыдущему показанному не
    /// рисуются: остаётся первый по ходу — он ближе. Полоса знает свою высоту
    /// только на экране, поэтому прореживание — и отдельным шагом.
    static func thinned(_ marks: [CameraMark], minGap: Double) -> [CameraMark] {
        var out: [CameraMark] = []
        for mark in marks {
            if let last = out.last, mark.fraction - last.fraction < minGap { continue }
            out.append(mark)
        }
        return out
    }

    /// Раскладка по линии маршрута: `cumulative` — пройденное до каждой точки
    /// в той же мере, что прогресс маршрута и места камер
    /// (RouteService.cumulative); пробки — все три уровня, иначе «свободно»
    /// не отличить от «нет данных».
    static func build(route: [CLLocationCoordinate2D], cumulative: [Double], snapshot: TrafficSnapshot?,
                      cameras: [CameraInput], minGap: Double) -> Layout {
        guard route.count >= 2, cumulative.count == route.count, let length = cumulative.last else { return .empty }
        let pieces = snapshot.map {
            RouteTraffic.pieces(along: route, snapshot: $0, cumulative: cumulative, levels: 1...3)
        } ?? []
        return layout(length: length, pieces: pieces, cameras: cameras, minGap: minGap)
    }

    /// Доля пройденного, в [0, 1].
    static func fraction(progress: Double, length: Double) -> Double {
        guard length > 0, progress.isFinite else { return 0 }
        return min(1, max(0, progress / length))
    }

    /// Доля, округлённая до шага в `points` пунктов на полосе высотой
    /// `height`: отметка «я» двигается целыми шагами, и полоса не
    /// перерисовывается на фиксе, который сдвинул её меньше чем на шаг.
    static func step(_ fraction: Double, height: Double, points: Double) -> Double {
        guard height > 0, points > 0 else { return fraction }
        let steps = (height / points).rounded(.down)
        guard steps >= 1 else { return fraction }
        return (fraction * steps).rounded() / steps
    }
}
