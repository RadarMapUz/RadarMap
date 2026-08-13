//
//  CameraMarkerView.swift
//  RadarMap
//
//  Маркер камеры на карте машины и его аннотация.
//
//  Вынесено из CarPlayMapView: там это была половина файла рисования поверх
//  половины файла управления картой, и оба перевалили за предел читаемости.
//  Здесь — только внешний вид точки: картинка по типу камеры, клин
//  направления там, где оно доказано, подсветка цели и кэш готовых растров.
//
//  Размер маркера следует тиру — та же шкала, что на телефоне (CameraTier):
//  background — точка, near — диск с каймой, target — крупный глиф с пульсом.
//  Раньше КАЖДАЯ камера рисовалась 44-пунктовым знаком, то есть размером
//  «выделенной» телефонной, — из машины это выглядело сыпью одинаково громких
//  иконок, против которой шкала тиров и существует.
//
//  Знак ограничения скорости на маркере намеренно НЕ рисуется на CarPlay
//  (limit приходит nil): лимит текущей дороги показан в доке крупно и рядом
//  со скоростью, а сорок маленьких знаков по экрану делали карту нечитаемой.
//  Код рисования знака оставлен — он нужен, если решение когда-нибудь
//  пересмотрят для широких экранов.
//

import MapKit
import SwiftUI
import UIKit

final class CameraAnnotation: NSObject, MKAnnotation {
    let camera: Camera
    /// Лимит дороги у камеры (OSM): есть — маркер рисуется знаком «60».
    let limit: Int?
    /// Рисовать ли клин направления: false в поездке — карта повёрнута по
    /// курсу, а клин в кэшированной картинке нарисован для севера вверху.
    let showsDirection: Bool
    /// Важность прямо сейчас — та же шкала, что на телефоне (CameraTier).
    /// Дальние камеры на экране машины гасятся: смотрят на него боковым
    /// зрением и долю секунды, и всё, что не про ближайший километр, — помеха.
    var tier: CameraTier = .near
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: camera.lat, longitude: camera.lon)
    }

    init(camera: Camera, limit: Int? = nil, tier: CameraTier = .near,
         showsDirection: Bool = true) {
        self.camera = camera
        self.limit = limit
        self.tier = tier
        self.showsDirection = showsDirection
    }
}

/// Маркер камеры: знак ограничения там, где лимит известен, иначе цветной круг
/// с глифом типа. Картинки кэшируются по паре «тип + лимит».
final class CameraMarkerView: MKAnnotationView {
    nonisolated static let reuseID = "camera"
    private static var cache: [String: UIImage] = [:]
    private var halo: CAShapeLayer?

    override var annotation: (any MKAnnotation)? {
        didSet {
            guard let annotation = annotation as? CameraAnnotation else { return }
            centerOffset = .zero
            collisionMode = .circle
            displayPriority = .defaultHigh
            applyTier(annotation.tier)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setTarget(false)
        applyTier(.near)
    }

    /// Важность маркера: дальние гасим, но не убираем — пропавшая камера хуже
    /// лишней. Плотность, а не удаление. Тир меняет и картинку: точка, диск
    /// или полный знак — прозрачности одной для этого мало.
    func applyTier(_ tier: CameraTier) {
        alpha = tier == .background ? AppConfig.mapBackgroundCameraOpacity : 1
        guard let annotation = annotation as? CameraAnnotation else { return }
        image = Self.marker(for: annotation.camera.kind, limit: annotation.limit,
                            direction: annotation.showsDirection
                                ? annotation.camera.markerDirection : nil,
                            tier: tier)
        // Слипшиеся маркеры собираются в счётчик вместо того, чтобы
        // прятать друг друга. Камера оповещения из кластеров исключена:
        // её нужно видеть отдельно и с пульсом.
        clusteringIdentifier = tier == .target ? nil : "camera"
    }

    /// Цель оповещения: крупнее, поверх соседей и с пульсирующим кольцом —
    /// на карте сразу видно, о какой именно точке говорит панель.
    func setTarget(_ isTarget: Bool) {
        // Картинка следует цели немедленно: applyTarget приходит чаще, чем
        // пересчёт тиров в reloadCameras, и точка, ставшая целью между
        // перерисовками, обязана вырасти до полного знака сразу, а не когда
        // карта соберётся перезагрузить маркеры. Halo ниже меряется по bounds —
        // картинка ставится до него.
        if let annotation = annotation as? CameraAnnotation {
            image = Self.marker(for: annotation.camera.kind, limit: annotation.limit,
                                direction: annotation.showsDirection
                                    ? annotation.camera.markerDirection : nil,
                                tier: isTarget ? .target : annotation.tier)
        }
        transform = isTarget ? CGAffineTransform(scaleX: 1.3, y: 1.3) : .identity
        displayPriority = isTarget ? .required : .defaultHigh
        zPriority = isTarget ? .max : .defaultUnselected

        guard isTarget else {
            halo?.removeFromSuperlayer()
            halo = nil
            return
        }
        guard halo == nil else { return }
        let tint = (annotation as? CameraAnnotation)?.camera.kind.tint ?? Theme.danger
        let ring = CAShapeLayer()
        let side = max(bounds.width, bounds.height) + 14
        ring.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                            width: side, height: side)
        ring.path = UIBezierPath(ovalIn: CGRect(origin: .zero,
                                                size: CGSize(width: side, height: side))).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor(tint).cgColor
        ring.lineWidth = 3

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.7
        scale.toValue = 1.35
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let pulse = CAAnimationGroup()
        pulse.animations = [scale, fade]
        pulse.duration = 1.5
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(pulse, forKey: "pulse")

        layer.addSublayer(ring)
        halo = ring
    }

    /// Направление квантуем шагом 15°: глазом разницы не видно, а кэш вместо
    /// 360 вариантов на каждый тип держит 24.
    ///
    /// Клин направления — только от near и выше: на двенадцатипунктовой точке
    /// он не читается, а кэш без него не множится на 24 варианта.
    private static func marker(for kind: CameraType, limit: Int?, direction: Int?,
                               tier: CameraTier) -> UIImage {
        let step = tier == .background ? nil
            : direction.map { (Int((Double($0) / 15).rounded()) * 15) % 360 }
        let key = "\(kind.sourceString)|\(limit ?? -1)|\(step ?? -1)|\(tier)"
        if let cached = cache[key] { return cached }
        let rendered: UIImage = switch tier {
        case .background: dotMarker(kind: kind)
        case .near:       discMarker(kind: kind, direction: step)
        case .target:     limit.map { limitMarker(kind: kind, limit: $0, direction: step) }
                              ?? glyphMarker(kind: kind, direction: step)
        }
        cache[key] = rendered
        return rendered
    }

    /// Фоновая камера — точка: тот же язык, что телефонная `dot` (заливка
    /// цветом типа, белая кайма), чуть крупнее — на экран машины смотрят
    /// с семидесяти сантиметров.
    private static func dotMarker(kind: CameraType) -> UIImage {
        let size = CGSize(width: 14, height: 14)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(x: 1.5, y: 1.5, width: 11, height: 11)
            UIColor(kind.tint).setFill()
            UIBezierPath(ovalIn: rect).fill()
            UIColor.white.withAlphaComponent(0.75).setStroke()
            let ring = UIBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    /// Ближняя камера — диск с каймой, без глифа: тип читается цветом, а
    /// полный знак остаётся цели. Клин уменьшен вместе с диском.
    private static func discMarker(kind: CameraType, direction: Int?) -> UIImage {
        let size = CGSize(width: 30, height: 30)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(x: 5, y: 5, width: 20, height: 20)
            drawCone(direction: direction, kind: kind,
                     center: CGPoint(x: rect.midX, y: rect.midY), radius: 14)
            UIColor.black.withAlphaComponent(0.55).setFill()
            UIBezierPath(ovalIn: rect).fill()
            UIColor(kind.tint).setFill()
            UIBezierPath(ovalIn: rect.insetBy(dx: 1.8, dy: 1.8)).fill()
            UIColor.white.withAlphaComponent(0.92).setStroke()
            let ring = UIBezierPath(ovalIn: rect.insetBy(dx: 2.4, dy: 2.4))
            ring.lineWidth = 1.4
            ring.stroke()
        }
    }

    /// Клин «камера смотрит туда» — та же деталь, что на телефоне. Рисуется
    /// только там, где направление доказано (см. Camera.markerDirection):
    /// половина базы доказать его не может, и клин у такой камеры был бы ложью.
    private static func drawCone(direction: Int?, kind: CameraType,
                                 center: CGPoint, radius: CGFloat) {
        guard let direction else { return }
        let spread = AppConfig.mapDirectionConeDegrees * .pi / 180
        // Ноль градусов — на север, то есть вверх по экрану карты.
        let heading = Double(direction) * .pi / 180 - .pi / 2
        let path = UIBezierPath()
        path.move(to: center)
        path.addArc(withCenter: center, radius: radius,
                    startAngle: CGFloat(heading - spread / 2),
                    endAngle: CGFloat(heading + spread / 2), clockwise: true)
        path.close()
        UIColor(kind.tint).withAlphaComponent(0.45).setFill()
        path.fill()
    }

    /// Знак «ограничение скорости» с цветной точкой типа внизу — тот же язык,
    /// что на карте телефона.
    private static func limitMarker(kind: CameraType, limit: Int, direction: Int?) -> UIImage {
        let size = CGSize(width: 46, height: 52)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let sign = CGRect(x: 7, y: 6, width: 32, height: 32)
            drawCone(direction: direction, kind: kind,
                     center: CGPoint(x: sign.midX, y: sign.midY), radius: 22)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: sign).fill()
            UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1).setStroke()
            let rim = UIBezierPath(ovalIn: sign.insetBy(dx: 2.4, dy: 2.4))
            rim.lineWidth = 4.8
            rim.stroke()

            let text = "\(limit)"
            let font = UIFont.systemFont(ofSize: limit >= 100 ? 13 : 15, weight: .heavy)
            let attributes: [NSAttributedString.Key: Any] = [.font: font,
                                                             .foregroundColor: UIColor.black]
            let bounds = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: sign.midX - bounds.width / 2,
                                  y: sign.midY - bounds.height / 2),
                      withAttributes: attributes)

            let dot = CGRect(x: size.width / 2 - 6, y: 33, width: 12, height: 12)
            UIColor(kind.tint).setFill()
            UIBezierPath(ovalIn: dot).fill()
            UIColor.white.setStroke()
            let dotRing = UIBezierPath(ovalIn: dot.insetBy(dx: 0.8, dy: 0.8))
            dotRing.lineWidth = 1.6
            dotRing.stroke()
        }
    }

    /// Лимит неизвестен — цветной круг с глифом типа: тёмная кайма держит
    /// маркер читаемым и на светлых участках карты.
    private static func glyphMarker(kind: CameraType, direction: Int?) -> UIImage {
        let size = CGSize(width: 44, height: 44)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(x: 6, y: 6, width: 32, height: 32)
            drawCone(direction: direction, kind: kind,
                     center: CGPoint(x: rect.midX, y: rect.midY), radius: 21)
            UIColor.black.withAlphaComponent(0.55).setFill()
            UIBezierPath(ovalIn: rect).fill()
            UIColor(kind.tint).setFill()
            UIBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5)).fill()
            UIColor.white.withAlphaComponent(0.92).setStroke()
            let ring = UIBezierPath(ovalIn: rect.insetBy(dx: 3.2, dy: 3.2))
            ring.lineWidth = 1.6
            ring.stroke()

            let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            if let glyph = UIImage(systemName: kind.symbolName, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                glyph.draw(in: CGRect(x: (size.width - glyph.size.width) / 2,
                                      y: (size.height - glyph.size.height) / 2,
                                      width: glyph.size.width, height: glyph.size.height))
            }
        }
    }
}
