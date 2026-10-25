//
//  EngineManeuverCallout.swift
//  RadarMap
//
//  Выноска манёвра на карте (29.G): синий пузырь с хвостиком у точки
//  поворота — расстояние и ряд полос с подсвеченными нужными. Что, когда и
//  где — ManeuverCallout (чистая логика); здесь — картинка и её место.
//
//  Вид поверх карты, как значок «я» и знак лимита (правило аудита 11.10:
//  ничего на тике в источники стиля). Картинка рисуется заново только на
//  смене содержимого, подписи (шаг 5–10 м) или стороны; на кадре — только
//  экранная точка якоря и `layer.position`.
//
//  Полосы — как в карточке манёвра: нужные — белые плашки с синей стрелкой,
//  остальные — бледные стрелки. Белая кайма отделяет пузырь от синей линии
//  маршрута под ним и от тёмного асфальта поездки.
//

#if canImport(MapLibre)
import CoreLocation
import MapLibre
import UIKit

@MainActor
final class EngineManeuverCallout {

    /// Что карта знает о выноске на этом применении модели.
    struct Input: Equatable {
        var content: ManeuverCallout.Content?
        /// Где манёвр на линии (координата) — считается раз на манёвр.
        var anchor: CLLocationCoordinate2D?
        var distance: Double
        var speedKmh: Double
        var daylight: Bool
        /// Свободная часть экрана и то, что закрывать нельзя (панели, кнопки).
        var frame: ManeuverCallout.Frame?
        /// Камеры пути и зона замера рядом с манёвром — экранные точки
        /// пересчитываются на кадре из этих координат.
        var avoid: [CLLocationCoordinate2D]
        /// Подъезд к повороту (стоп-линия, стрелки полос) — поле уже.
        var approach: [CLLocationCoordinate2D] = []

        static func == (l: Input, r: Input) -> Bool {
            l.content == r.content && l.distance == r.distance && l.speedKmh == r.speedKmh
                && l.daylight == r.daylight && l.frame == r.frame
                && l.anchor?.latitude == r.anchor?.latitude && l.anchor?.longitude == r.anchor?.longitude
                && Self.same(l.avoid, r.avoid) && Self.same(l.approach, r.approach)
        }

        private static func same(_ a: [CLLocationCoordinate2D], _ b: [CLLocationCoordinate2D]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
        }
    }

    private var input: Input?
    private var gate = ManeuverCallout.Gate()
    private var shown = ManeuverCallout.Shown(lanes: false, meters: nil)
    private var placement: ManeuverCallout.Placement?
    private var bubble: UIImageView?
    /// Что нарисовано сейчас: содержимое, подпись, сторона, сдвиг, тема.
    private var drawnKey: String?
    private var bodySize: CGSize = .zero
    private var sizeKey: String?

    /// Новое применение модели (раз на фикс): содержимое и гейт.
    func update(_ input: Input?) {
        self.input = input
        guard let input else {
            shown = gate.update(content: nil, distance: .infinity, speedKmh: 0)
            return
        }
        shown = gate.update(content: input.content, distance: input.distance, speedKmh: input.speedKmh)
    }

    /// Кадр: поставить выноску у точки манёвра. `cursor` — экранная точка
    /// значка «я».
    func layout(cursor: CGPoint?, visible: Bool, in view: MLNMapView) {
        guard visible, let input, let content = input.content, let anchor = input.anchor,
              let frame = input.frame, !shown.isEmpty else {
            hide()
            return
        }
        let point = view.convert(anchor, toPointTo: view)
        let size = measure(content: content)
        var avoid = frame.blocked
        if let cursor { avoid.append(ManeuverCallout.box(cursor, radius: AppConfig.maneuverCalloutCursorRadius)) }
        for coordinate in input.avoid {
            avoid.append(ManeuverCallout.box(view.convert(coordinate, toPointTo: view),
                                             radius: AppConfig.maneuverCalloutCameraRadius))
        }
        for coordinate in input.approach {
            avoid.append(ManeuverCallout.box(view.convert(coordinate, toPointTo: view),
                                             radius: AppConfig.maneuverCalloutApproachRadius))
        }
        guard let place = ManeuverCallout.place(anchor: point, size: size, clear: frame.clear,
                                                avoid: avoid, previous: placement,
                                                turn: content.kind?.side) else {
            hide()
            return
        }
        placement = place
        let bubble = self.bubble ?? make(in: view)
        let key = "\(content.along)|\(shown.lanes)|\(shown.meters ?? -1)|\(place.side)|\(place.shift)|\(input.daylight)"
        if key != drawnKey {
            drawnKey = key
            bubble.image = Self.render(content: content, shown: shown, size: size, placement: place,
                                       daylight: input.daylight)
            bubble.bounds = CGRect(origin: .zero, size: bubble.image?.size ?? .zero)
            bubble.accessibilityLabel = Self.spoken(content: content, shown: shown)
        }
        // Картинка — тело плюс хвостик: её середина сдвинута к хвостику.
        let half = AppConfig.maneuverCalloutTailPoints / 2
        let centre: CGPoint
        switch place.side {
        case .above: centre = CGPoint(x: place.frame.midX, y: place.frame.midY + half)
        case .below: centre = CGPoint(x: place.frame.midX, y: place.frame.midY - half)
        case .left:  centre = CGPoint(x: place.frame.midX + half, y: place.frame.midY)
        case .right: centre = CGPoint(x: place.frame.midX - half, y: place.frame.midY)
        case .belowLeft:
            centre = CGPoint(x: place.frame.midX + AppConfig.maneuverCalloutDiagonalGapPoints / 2,
                             y: place.frame.midY - half)
        case .belowRight:
            centre = CGPoint(x: place.frame.midX - AppConfig.maneuverCalloutDiagonalGapPoints / 2,
                             y: place.frame.midY - half)
        }
        if bubble.isHidden || abs(bubble.layer.position.x - centre.x) >= 0.25
            || abs(bubble.layer.position.y - centre.y) >= 0.25 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bubble.layer.position = centre
            bubble.isHidden = false
            CATransaction.commit()
        }
    }

    private func hide() {
        placement = nil
        bubble?.isHidden = true
    }

    private func make(in view: MLNMapView) -> UIImageView {
        let bubble = UIImageView()
        bubble.isUserInteractionEnabled = false
        bubble.isAccessibilityElement = true
        bubble.layer.zPosition = AppConfig.maneuverCalloutZPosition
        view.addSubview(bubble)
        self.bubble = bubble
        return bubble
    }

    // MARK: - Картинка

    private static let padH: CGFloat = 10
    private static let height: CGFloat = 40
    private static let laneWidth: CGFloat = 26
    private static let laneHeight: CGFloat = 30
    private static let laneGap: CGFloat = 2
    private static let gap: CGFloat = 8
    /// Строка расстояния над рядом полос, pt.
    private static let textRow: CGFloat = 22

    private static var font: UIFont {
        let base = UIFont.systemFont(ofSize: 17, weight: .heavy)
        return UIFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 17)
    }

    private static func text(_ shown: ManeuverCallout.Shown) -> String? {
        shown.meters.map { Formatting.distance(Double($0)) }
    }

    /// Размер тела (без хвостика). Меняется с подписью — кэш по ключу.
    private func measure(content: ManeuverCallout.Content) -> CGSize {
        let key = "\(content.along)|\(shown.lanes)|\(shown.meters ?? -1)"
        if key == sizeKey { return bodySize }
        sizeKey = key
        bodySize = Self.layoutWidths(content: content, shown: shown).size
        return bodySize
    }

    private struct Widths {
        var icon: CGFloat = 0
        var text: CGFloat = 0
        var lanes: CGFloat = 0
        var size: CGSize
    }

    /// Раскладка тела. Расстояние и ряд полос вместе — двумя строками
    /// (цифра над рядом): в одну строку пять полос с «140 м» занимали ~215 pt
    /// и не вставали сбоку от подъезда даже на большом телефоне.
    private static func layoutWidths(content: ManeuverCallout.Content, shown: ManeuverCallout.Shown) -> Widths {
        var w = Widths(size: .zero)
        let lanes = shown.lanes ? content.lanes : []
        if let text = text(shown) {
            w.text = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        if lanes.isEmpty {
            w.icon = 22
            let inner = w.icon + (w.text > 0 ? gap + w.text : 0)
            w.size = CGSize(width: inner + padH * 2, height: height)
            return w
        }
        w.lanes = CGFloat(lanes.count) * laneWidth + CGFloat(lanes.count - 1) * laneGap
        let rows = w.text > 0
        w.size = CGSize(width: max(w.lanes, w.text) + padH * 2,
                        height: rows ? height + textRow : height)
        return w
    }

    private static func render(content: ManeuverCallout.Content, shown: ManeuverCallout.Shown, size: CGSize,
                               placement: ManeuverCallout.Placement, daylight: Bool) -> UIImage {
        let tail = AppConfig.maneuverCalloutTailPoints
        let corner = AppConfig.maneuverCalloutCornerPoints
        let fill = Theme.accentFillUIColor.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: daylight ? .light : .dark))
        let gap = AppConfig.maneuverCalloutDiagonalGapPoints
        let canvas: CGSize
        let origin: CGPoint
        switch placement.side {
        case .above:
            canvas = CGSize(width: size.width, height: size.height + tail); origin = .zero
        case .below:
            canvas = CGSize(width: size.width, height: size.height + tail); origin = CGPoint(x: 0, y: tail)
        case .left:
            canvas = CGSize(width: size.width + tail, height: size.height); origin = .zero
        case .right:
            canvas = CGSize(width: size.width + tail, height: size.height); origin = CGPoint(x: tail, y: 0)
        case .belowLeft:
            canvas = CGSize(width: size.width + gap, height: size.height + tail); origin = CGPoint(x: 0, y: tail)
        case .belowRight:
            canvas = CGSize(width: size.width + gap, height: size.height + tail); origin = CGPoint(x: gap, y: tail)
        }
        let body = CGRect(origin: origin, size: size).insetBy(dx: 1, dy: 1)
        // Хвостик — у точки манёвра: сдвиг тела влево значит хвостик правее.
        let tipX = placement.tip.x - placement.frame.minX
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            let path = UIBezierPath(roundedRect: body, cornerRadius: corner)
            let tailPath = UIBezierPath()
            let half: CGFloat = 7
            let baseX = min(max(tipX, body.minX + corner + half), body.maxX - corner - half)
            switch placement.side {
            case .above:
                tailPath.move(to: CGPoint(x: baseX - half, y: body.maxY - 1))
                tailPath.addLine(to: CGPoint(x: tipX, y: canvas.height - 0.5))
                tailPath.addLine(to: CGPoint(x: baseX + half, y: body.maxY - 1))
            case .below:
                tailPath.move(to: CGPoint(x: baseX - half, y: body.minY + 1))
                tailPath.addLine(to: CGPoint(x: tipX, y: 0.5))
                tailPath.addLine(to: CGPoint(x: baseX + half, y: body.minY + 1))
            case .left:
                tailPath.move(to: CGPoint(x: body.maxX - 1, y: body.midY - half))
                tailPath.addLine(to: CGPoint(x: canvas.width - 0.5, y: body.midY))
                tailPath.addLine(to: CGPoint(x: body.maxX - 1, y: body.midY + half))
            case .right:
                tailPath.move(to: CGPoint(x: body.minX + 1, y: body.midY - half))
                tailPath.addLine(to: CGPoint(x: 0.5, y: body.midY))
                tailPath.addLine(to: CGPoint(x: body.minX + 1, y: body.midY + half))
            case .belowLeft:
                tailPath.move(to: CGPoint(x: body.maxX - corner - half * 2, y: body.minY + 1))
                tailPath.addLine(to: CGPoint(x: canvas.width - 0.5, y: 0.5))
                tailPath.addLine(to: CGPoint(x: body.maxX - corner * 0.4, y: body.minY + 1))
            case .belowRight:
                tailPath.move(to: CGPoint(x: body.minX + corner * 0.4, y: body.minY + 1))
                tailPath.addLine(to: CGPoint(x: 0.5, y: 0.5))
                tailPath.addLine(to: CGPoint(x: body.minX + corner + half * 2, y: body.minY + 1))
            }
            tailPath.close()
            path.append(tailPath)
            // Белая кайма — отдельно от синей линии маршрута и тёмного асфальта.
            UIColor.white.setStroke()
            path.lineWidth = 2.5
            path.lineJoinStyle = .round
            path.stroke()
            fill.setFill()
            path.fill()

            let widths = layoutWidths(content: content, shown: shown)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            if widths.lanes == 0 {
                // Одна строка: стрелка манёвра и расстояние.
                var x = origin.x + padH
                let midY = body.midY
                let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .heavy)
                if let icon = UIImage(systemName: content.icon, withConfiguration: config)?
                    .withTintColor(.white, renderingMode: .alwaysOriginal) {
                    icon.draw(in: CGRect(x: x + (widths.icon - icon.size.width) / 2, y: midY - icon.size.height / 2,
                                         width: icon.size.width, height: icon.size.height))
                }
                x += widths.icon + gap
                if let text = text(shown) {
                    let size = (text as NSString).size(withAttributes: attributes)
                    (text as NSString).draw(at: CGPoint(x: x, y: midY - size.height / 2), withAttributes: attributes)
                }
                return
            }
            // Ряд полос (и над ним расстояние): по центру тела.
            var lanesMidY = body.midY
            if let text = text(shown) {
                let size = (text as NSString).size(withAttributes: attributes)
                let top = origin.y + 6
                (text as NSString).draw(at: CGPoint(x: origin.x + (widths.size.width - size.width) / 2, y: top),
                                        withAttributes: attributes)
                lanesMidY = origin.y + textRow + height / 2 - 2
            }
            var x = origin.x + (widths.size.width - widths.lanes) / 2
            for lane in content.lanes {
                let cell = CGRect(x: x, y: lanesMidY - laneHeight / 2, width: laneWidth, height: laneHeight)
                let arrow = lane.primaryArrow(for: content.kind)
                let config = UIImage.SymbolConfiguration(pointSize: 15, weight: lane.isValid ? .heavy : .semibold)
                if lane.isValid {
                    UIColor.white.setFill()
                    UIBezierPath(roundedRect: cell, cornerRadius: 7).fill()
                }
                let tint = lane.isValid ? fill : UIColor.white.withAlphaComponent(AppConfig.laneFocusOtherOpacity)
                if let image = UIImage(systemName: arrow.symbolName, withConfiguration: config)?
                    .withTintColor(tint, renderingMode: .alwaysOriginal) {
                    image.draw(in: CGRect(x: cell.midX - image.size.width / 2, y: cell.midY - image.size.height / 2,
                                          width: image.size.width, height: image.size.height))
                }
                x += laneWidth + laneGap
            }
        }
    }

    private static func spoken(content: ManeuverCallout.Content, shown: ManeuverCallout.Shown) -> String {
        var parts: [String] = []
        if let text = text(shown) { parts.append(text) }
        if shown.lanes, let phrase = LaneAdvice.phrase(content.lanes) { parts.append(phrase) }
        return parts.joined(separator: ", ")
    }
}
#endif
