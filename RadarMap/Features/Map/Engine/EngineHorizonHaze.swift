//
//  EngineHorizonHaze.swift
//  RadarMap
//
//  Дымка у верхнего края наклонной карты (29.F, правила — HorizonHaze).
//  Один градиентный слой над картой и под стрелкой «я» и интерфейсом:
//  ни слоя стиля, ни прохода движка. Перестраивается только на шаге
//  наклона ≥ AppConfig.hazePitchStep или смене темы — кадр анимации камеры
//  его зовёт, но почти всегда уходит по пропуску.
//

#if canImport(MapLibre)
import MapLibre
import UIKit

@MainActor
final class EngineHorizonHaze {

    private final class HazeView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }
        var gradient: CAGradientLayer { layer as! CAGradientLayer }
    }

    private var hazeView: HazeView?
    private var shown: (pitch: Double, daylight: Bool, size: CGSize, hidden: Bool)?
    private var paintedDaylight: Bool?

    /// `hidden` — погасить совсем («Вождение 3D» на горячем телефоне, 43).
    func update(pitchDegrees: Double, daylight: Bool, hidden: Bool = false, in view: MLNMapView) {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if let shown, abs(shown.pitch - pitchDegrees) < AppConfig.hazePitchStep,
           shown.daylight == daylight, shown.size == size, shown.hidden == hidden { return }
        shown = (pitchDegrees, daylight, size, hidden)
        var look = HorizonHaze.look(pitchDegrees: pitchDegrees)
        if hidden { look.opacity = 0 }
        guard look.opacity > 0.01 || hazeView != nil else { return }
        let haze = hazeView ?? make(in: view)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if paintedDaylight != daylight {
            paintedDaylight = daylight
            let stops = HorizonHaze.stops(daylight: daylight)
            haze.gradient.colors = stops.map { Theme.rgb($0.rgb).withAlphaComponent($0.alpha).cgColor }
            haze.gradient.locations = stops.map { NSNumber(value: $0.at) }
        }
        haze.isHidden = look.opacity <= 0.01
        haze.layer.opacity = Float(look.opacity)
        haze.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height * look.heightShare)
        CATransaction.commit()
    }

    private func make(in view: MLNMapView) -> HazeView {
        let haze = HazeView()
        haze.isUserInteractionEnabled = false
        haze.isAccessibilityElement = false
        haze.gradient.startPoint = CGPoint(x: 0.5, y: 0)
        haze.gradient.endPoint = CGPoint(x: 0.5, y: 1)
        // Прямо над холстом движка: стрелка «я», кольцо компаса и подпись
        // данных лежат выше.
        if let canvas = view.subviews.first {
            view.insertSubview(haze, aboveSubview: canvas)
        } else {
            view.addSubview(haze)
        }
        hazeView = haze
        return haze
    }
}
#endif
