//
//  CarPlayUserMarker.swift
//  RadarMap
//
//  Своя метка машины вместо системной синей точки.
//
//  Приложение целиком нарисовано в тёмном радар-детекторном языке, и штатная
//  точка MapKit посреди него выглядела чужой: другой синий, другой блеск,
//  другая форма. Здесь — стрелка «мы едем туда», в акцентном цвете темы и с
//  подсветкой, чтобы она читалась на тёмной карте боковым зрением.
//
//  Стрелка ВСЕГДА смотрит вверх, и это не упрощение: карта машины в поездке
//  повёрнута по курсу (followWithHeading), то есть верх экрана и есть
//  направление движения. Крутить саму метку значило бы вращать её дважды.
//

import MapKit
import SwiftUI
import UIKit

final class CarPlayUserMarker: MKAnnotationView {
    nonisolated static let reuseID = "user"

    override var annotation: (any MKAnnotation)? {
        didSet {
            image = Self.arrow
            centerOffset = .zero
            // Метка машины не участвует в столкновениях и не уступает никому:
            // потерять из виду себя на карте нельзя.
            collisionMode = .none
            displayPriority = .required
            zPriority = .max
        }
    }

    /// Растр рисуется один раз на запуск: он не зависит ни от чего.
    private static let arrow: UIImage = {
        let size = CGSize(width: 40, height: 40)
        return UIGraphicsImageRenderer(size: size).image { context in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let accent = UIColor(Theme.accent)

            // Мягкое свечение — читается на тёмной карте, но не забивает
            // ближние маркеры камер.
            context.cgContext.setShadow(offset: .zero, blur: 10,
                                        color: accent.withAlphaComponent(0.9).cgColor)

            // Тёмная обводка: на светлых участках карты (мост, площадь)
            // акцентная стрелка без неё сливается.
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: center.x, y: center.y - 14))
            arrow.addLine(to: CGPoint(x: center.x + 10, y: center.y + 12))
            arrow.addLine(to: CGPoint(x: center.x, y: center.y + 6))
            arrow.addLine(to: CGPoint(x: center.x - 10, y: center.y + 12))
            arrow.close()

            UIColor.black.withAlphaComponent(0.55).setStroke()
            arrow.lineWidth = 4
            arrow.lineJoinStyle = .round
            arrow.stroke()

            context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            accent.setFill()
            arrow.fill()
        }
    }()
}
