//
//  EngineCarDecor.swift
//  RadarMap
//
//  Что рисуется у значка «я» в поездке (29.B, как у Amap): тонкое кольцо
//  компаса N/E/S/W на земле вокруг машины и знак смены лимита впереди
//  («200 м · 40») слева от неё.
//
//  Оба — виды поверх карты, как сама стрелка (правило аудита 11.10: ничего
//  на тике в источники стиля). Кольцо — эллипс в плоскости карты: сплющено
//  по наклону и повёрнуто на север (CompassRing, чистая геометрия); буквы
//  стоят прямо. Знак перерисовывается картинкой только на смене цифр.
//
//  Буквы N/E/S/W — международные отметки сторон света, как у эталона
//  владельца (Amap), а не слова интерфейса; поэтому без перевода. В машине
//  (40J, CarMapStyle) букв нет: 10 pt на её экране не читались, но вертелись
//  в центре внимания, — север там синяя метка на кольце.
//

#if canImport(MapLibre)
import CoreLocation
import MapLibre
import SwiftUI
import UIKit

@MainActor
final class EngineCarDecor {

    private var ring: CompassRingView?
    private var badge: UIImageView?
    private var badgeTracker = LimitAhead.Badge()
    /// Что на знаке сейчас: лимит и метры.
    private var badgeShown: (limit: Int, meters: Int)?
    private static var badgeCache: [String: UIImage] = [:]

    /// Расставить у машины. `point` — экранная точка значка «я».
    func layout(at point: CGPoint, coordinate: CLLocationCoordinate2D, mapDirection: Double,
                pitchDegrees: Double, compass: Bool, look: CompassRing.Look = .phone,
                limit: LimitAhead.Notice?, visible: Bool, in view: MLNMapView) {
        layoutRing(at: point, mapDirection: mapDirection, pitchDegrees: pitchDegrees,
                   shown: compass && visible, look: look, in: view)
        layoutBadge(at: point, coordinate: coordinate, limit: visible ? limit : nil, in: view)
    }

    // MARK: - Компас

    private func layoutRing(at point: CGPoint, mapDirection: Double, pitchDegrees: Double,
                            shown: Bool, look: CompassRing.Look, in view: MLNMapView) {
        // Видимость — только на смене: сеттер isHidden у UIView не бесплатен
        // (обход маскирующих видов), а зовётся это на каждом кадре камеры.
        guard shown else {
            if ring?.isHidden == false { ring?.isHidden = true }
            return
        }
        // Облик кольца у карты не меняется (телефон или машина) — смена
        // облика означает новое кольцо, а не перестройку на кадре.
        if let ring, ring.look != look {
            ring.removeFromSuperview()
            self.ring = nil
        }
        let ring = self.ring ?? makeRing(look: look, in: view)
        if ring.isHidden { ring.isHidden = false }
        ring.update(center: point, mapDirection: mapDirection, pitchDegrees: pitchDegrees)
    }

    private func makeRing(look: CompassRing.Look, in view: MLNMapView) -> CompassRingView {
        let ring = CompassRingView(look: look)
        // Под значком «я» (engineCursorZPosition), над картой.
        ring.layer.zPosition = AppConfig.engineCursorZPosition - 20
        view.addSubview(ring)
        self.ring = ring
        return ring
    }

    // MARK: - Знак лимита

    private func layoutBadge(at point: CGPoint, coordinate: CLLocationCoordinate2D,
                             limit: LimitAhead.Notice?, in view: MLNMapView) {
        let distance = limit.map {
            GeoMath.fastDistance(coordinate.latitude, coordinate.longitude, $0.at.latitude, $0.at.longitude)
        } ?? .infinity
        guard let limit, let meters = badgeTracker.meters(for: limit, distance: distance) else {
            _ = badgeTracker.meters(for: nil, distance: 0)
            badge?.isHidden = true
            badgeShown = nil
            return
        }
        let badge = self.badge ?? makeBadge(in: view)
        if badgeShown?.limit != limit.limit || badgeShown?.meters != meters {
            badgeShown = (limit.limit, meters)
            badge.image = Self.badgeImage(limit: limit.limit, meters: meters)
            badge.bounds = CGRect(origin: .zero, size: badge.image?.size ?? .zero)
            badge.accessibilityLabel = String(format: String(localized: "Ограничение %1$lld через %2$@"),
                                              limit.limit, Formatting.distance(Double(meters)))
        }
        badge.isHidden = false
        let half = badge.bounds.width / 2
        let x = max(half + 8, point.x - AppConfig.limitBadgeGapPoints - half)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badge.layer.position = CGPoint(x: x, y: point.y)
        CATransaction.commit()
    }

    private func makeBadge(in view: MLNMapView) -> UIImageView {
        let badge = UIImageView()
        badge.isUserInteractionEnabled = false
        badge.isAccessibilityElement = true
        badge.layer.zPosition = AppConfig.engineCursorZPosition - 10
        view.addSubview(badge)
        self.badge = badge
        return badge
    }

    private static func badgeImage(limit: Int, meters: Int) -> UIImage? {
        let key = "\(limit)-\(meters)-\(Formatting.distance(Double(meters)))"
        if let hit = badgeCache[key] { return hit }
        let renderer = ImageRenderer(content: LimitAheadBadge(limit: limit, distance: Formatting.distance(Double(meters)))
            .padding(6))
        renderer.scale = 3
        let image = renderer.uiImage
        if badgeCache.count > 64 { badgeCache.removeAll() }
        badgeCache[key] = image
        return image
    }
}

/// Знак смены лимита у машины: белая капсула с расстоянием и круглый знак.
/// Белая в обеих темах — это дорожный знак, а не панель интерфейса.
struct LimitAheadBadge: View {
    let limit: Int
    let distance: String

    var body: some View {
        HStack(spacing: 5) {
            Text(distance)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.11, green: 0.12, blue: 0.14))
                .padding(.leading, 9)
            SpeedLimitSign(limit: limit, diameter: 26)
                .padding(.trailing, 2)
        }
        .frame(height: 30)
        .background {
            Capsule().fill(.white).shadow(color: .black.opacity(0.28), radius: 3, y: 1)
        }
        .environment(\.colorScheme, .light)
    }
}

/// Кольцо компаса: эллипс и четыре буквы. Перерисовывается только на
/// заметной смене наклона, поворота или точки.
final class CompassRingView: UIView {

    private let ellipse = CAShapeLayer()
    private let outline = CAShapeLayer()
    /// Мягкое световое пятно на асфальте под машиной (29.F, как у Amap):
    /// радиальный градиент цвета линии маршрута внутри кольца — значок
    /// стоит на дороге, а не висит над ней. Статичный слой, перестраивается
    /// только со сменой наклона.
    private let pool = CAGradientLayer()
    private var labels: [UILabel] = []
    /// Метка севера на кольце вместо букв (машина, 40J).
    private let northMark = CAShapeLayer()
    private var shown: (center: CGPoint, direction: Double, pitch: Double)?
    let look: CompassRing.Look

    init(look: CompassRing.Look) {
        self.look = look
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        // Тёмная подложка кольца под светлой линией: кольцо видно и на светлой
        // земле, и на тёмном асфальте поездки.
        outline.fillColor = UIColor.clear.cgColor
        outline.strokeColor = UIColor(white: 0.1, alpha: 0.35).cgColor
        outline.lineWidth = 3
        ellipse.fillColor = UIColor.clear.cgColor
        ellipse.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        ellipse.lineWidth = 1.3
        pool.type = .radial
        pool.startPoint = CGPoint(x: 0.5, y: 0.5)
        pool.endPoint = CGPoint(x: 1, y: 1)
        let tint = Theme.rgb(RouteColors.body.night)
        let poolAlpha = CGFloat(look.poolAlpha)
        pool.colors = [tint.withAlphaComponent(poolAlpha).cgColor,
                       tint.withAlphaComponent(poolAlpha * 0.45).cgColor,
                       tint.withAlphaComponent(0).cgColor]
        pool.locations = [0, 0.55, 1]
        layer.addSublayer(pool)
        layer.addSublayer(outline)
        layer.addSublayer(ellipse)
        if !look.letters {
            let side = AppConfig.compassNorthMarkPoints
            northMark.path = UIBezierPath(ovalIn: CGRect(x: -side / 2, y: -side / 2, width: side, height: side)).cgPath
            northMark.fillColor = Theme.rgb(CompassRing.northRGB).cgColor
            northMark.strokeColor = UIColor(white: 0.1, alpha: 0.5).cgColor
            northMark.lineWidth = 1
            layer.addSublayer(northMark)
        }
        for mark in CompassRing.marks where look.letters {
            let label = UILabel()
            label.text = mark.letter
            label.font = .systemFont(ofSize: AppConfig.compassLetterSize, weight: .heavy)
            // Север — синим акцентом приложения (красный на этой карте — камера).
            label.textColor = mark.isNorth ? Theme.rgb(CompassRing.northRGB) : .white
            label.shadowColor = UIColor(white: 0, alpha: 0.75)
            label.shadowOffset = CGSize(width: 0, height: 0.5)
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowRadius = 1.5
            label.layer.shadowOpacity = 0.8
            label.layer.shadowOffset = .zero
            label.sizeToFit()
            // Буква неизменна, меняется только место: растр с тенью собирается
            // один раз, а не на каждом кадре, пока карта крутится (тень слоя
            // без shadowPath — внеэкранный проход композитора).
            label.layer.shouldRasterize = true
            addSubview(label)
            labels.append(label)
        }
        // Размер вида постоянный — ставится один раз, не на каждом кадре.
        let side = AppConfig.compassRadiusPoints * 2 + 24
        bounds = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let scale = window?.traitCollection.displayScale ?? traitCollection.displayScale
        for label in labels { label.layer.rasterizationScale = max(1, scale) }
    }

    required init?(coder: NSCoder) { nil }

    func update(center: CGPoint, mapDirection: Double, pitchDegrees: Double) {
        if let shown, abs(shown.center.x - center.x) < 0.25, abs(shown.center.y - center.y) < 0.25,
           abs(shown.direction - mapDirection) < 0.3, abs(shown.pitch - pitchDegrees) < 0.5 { return }
        let pitchChanged = shown.map { abs($0.pitch - pitchDegrees) >= 0.5 } ?? true
        shown = (center, mapDirection, pitchDegrees)
        let geometry = CompassRing.geometry(radius: AppConfig.compassRadiusPoints, mapDirection: mapDirection,
                                            pitchDegrees: pitchDegrees)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = center
        if pitchChanged {
            let rect = CGRect(x: -geometry.radiusX, y: -geometry.radiusY,
                              width: geometry.radiusX * 2, height: geometry.radiusY * 2)
            ellipse.path = UIBezierPath(ovalIn: rect).cgPath
            outline.path = ellipse.path
            pool.frame = rect
        }
        // Буквы — позицией слоя, а не `center` вида: UIKit на `center`
        // пересчитывает поля и отступы (треть цены кольца на кадре, аудит
        // 26.10), а у этих букв их нет. Для вида без своей раскладки это одно
        // и то же место.
        for index in labels.indices where index < geometry.letters.count {
            labels[index].layer.position = geometry.letters[index]
        }
        if !look.letters, let north = geometry.letters.first {
            northMark.position = north
        }
        CATransaction.commit()
    }
}
#endif
