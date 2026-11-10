//
//  CompassRing.swift
//  RadarMap
//
//  Кольцо компаса вокруг машины в поездке (29.B, как у Amap): круг на
//  земле, увиденный под наклоном карты, — эллипс, сплющенный по вертикали
//  на cos(наклона); буквы сторон света стоят на нём там, куда на экране
//  смотрит эта сторона при текущем повороте карты.
//
//  Поворот карты (MapLibre `direction`) — куда смотрит верх экрана, градусы
//  по часовой от севера. Сторона света с азимутом b на экране — под углом
//  b − direction по часовой от верха.
//
//  Чистая геометрия — покрыто CompassRingTests.
//

import CoreGraphics
import Foundation

nonisolated enum CompassRing {

    struct Mark: Equatable, Sendable {
        let letter: String
        let bearing: Double
        var isNorth: Bool { bearing == 0 }
    }

    /// Север — синим акцентом приложения (красный на карте — только камера).
    static let northRGB: UInt32 = WidgetPalette.accent.dark

    /// Международные отметки сторон света (не слова интерфейса).
    static let marks = [Mark(letter: "N", bearing: 0), Mark(letter: "E", bearing: 90),
                        Mark(letter: "S", bearing: 180), Mark(letter: "W", bearing: 270)]

    /// Облик кольца: буквы сторон света или одна синяя метка севера (машина,
    /// CarMapStyle), плотность светового пятна под машиной.
    struct Look: Equatable, Sendable {
        var letters: Bool
        var poolAlpha: Double

        static let phone = Look(letters: true, poolAlpha: Double(AppConfig.compassPoolAlpha))
    }

    struct Geometry: Equatable, Sendable {
        let radiusX: CGFloat
        let radiusY: CGFloat
        /// Точки букв относительно центра кольца, в порядке `marks`.
        let letters: [CGPoint]
    }

    static func geometry(radius: CGFloat, mapDirection: Double, pitchDegrees: Double) -> Geometry {
        let pitch = min(max(0, pitchDegrees), 89) * .pi / 180
        let squash = CGFloat(cos(pitch))
        let letters = marks.map { mark -> CGPoint in
            let angle = (mark.bearing - mapDirection) * .pi / 180
            return CGPoint(x: radius * CGFloat(sin(angle)), y: -radius * squash * CGFloat(cos(angle)))
        }
        return Geometry(radiusX: radius, radiusY: radius * squash, letters: letters)
    }
}
