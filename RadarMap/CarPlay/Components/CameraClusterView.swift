//
//  CameraClusterView.swift
//  RadarMap
//
//  Счётчик слипшихся камер на карте машины.
//
//  Правило проекта: камера НИКОГДА не пропадает молча — если её не видно
//  отдельным маркером, она обязана быть частью посчитанной группы. На
//  телефоне это делает `CameraMapContent`, а карта машины до сих пор просто
//  теряла всё, что не влезло в бюджет или наложилось на соседа: экран был
//  забит крупными знаками, и при этом часть камер на нём отсутствовала.
//
//  Здесь взята штатная кластеризация MapKit (`clusteringIdentifier`) — она
//  дешевле собственной сетки и, главное, пересчитывается самим фреймворком
//  при каждом изменении зума, без единого нашего тика.
//

import MapKit
import SwiftUI   // Theme и kind.tint — цвета SwiftUI
import UIKit

final class CameraClusterView: MKAnnotationView {
    nonisolated static let reuseID = MKMapViewDefaultClusterAnnotationViewReuseIdentifier

    override var annotation: (any MKAnnotation)? {
        didSet {
            guard let cluster = annotation as? MKClusterAnnotation else { return }
            image = Self.badge(count: cluster.memberAnnotations.count,
                               tint: Self.tint(for: cluster))
            centerOffset = .zero
            collisionMode = .circle
            // Ниже одиночных камер: отдельная камера всегда важнее группы.
            displayPriority = .defaultLow
        }
    }

    /// Цвет группы — по самой «громкой» камере внутри: если в пачке есть
    /// передвижной радар, водитель должен видеть это по цвету, а не открывать
    /// группу (открыть её за рулём всё равно нельзя).
    private static func tint(for cluster: MKClusterAnnotation) -> UIColor {
        let kinds = cluster.memberAnnotations
            .compactMap { ($0 as? CameraAnnotation)?.camera.kind }
        let loudest = kinds.first { $0 == .mobileRadar || $0 == .tripod } ?? kinds.first
        return UIColor(loudest?.tint ?? Theme.danger)
    }

    private static var cache: [String: UIImage] = [:]

    /// Значок группы с числом.
    ///
    /// Форма намеренно ДРУГАЯ, чем у одиночной камеры: та — круг, эта —
    /// скруглённый квадрат. Раньше отличие держалось на цвете и цифре внутри,
    /// и на карте пятнадцать почти одинаковых кружков конкурировали друг с
    /// другом; силуэт различается боковым зрением, а оттенок — нет.
    ///
    /// Размер растёт ступенями, а не плавно: за рулём важно «мало / много»,
    /// а не точная площадь.
    private static func badge(count: Int, tint: UIColor) -> UIImage {
        // Шкала уменьшена вместе с одиночными маркерами (тир-рендер в
        // CameraMarkerView): группа не должна быть громче полного знака цели.
        let side: CGFloat = count >= 20 ? 38 : (count >= 8 ? 34 : 30)
        let text = count > 99 ? "99+" : "\(count)"
        let key = "\(text)|\(side)|\(tint.hashValue)"
        if let cached = cache[key] { return cached }

        let size = CGSize(width: side, height: side)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let radius = side * 0.30
            UIColor.black.withAlphaComponent(0.55).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
            tint.setFill()
            UIBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3),
                         cornerRadius: radius - 2).fill()
            UIColor.white.withAlphaComponent(0.92).setStroke()
            let ring = UIBezierPath(roundedRect: rect.insetBy(dx: 3.8, dy: 3.8),
                                    cornerRadius: radius - 2.8)
            ring.lineWidth = 1.6
            ring.stroke()

            let font = UIFont.systemFont(ofSize: text.count > 2 ? 12 : 14, weight: .heavy)
            let attributes: [NSAttributedString.Key: Any] = [.font: font,
                                                             .foregroundColor: UIColor.white]
            let bounds = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: rect.midX - bounds.width / 2,
                                  y: rect.midY - bounds.height / 2),
                      withAttributes: attributes)
        }
        cache[key] = rendered
        return rendered
    }
}
