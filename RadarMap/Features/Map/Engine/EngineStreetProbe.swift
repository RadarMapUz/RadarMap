//
//  EngineStreetProbe.swift
//  RadarMap
//
//  Имя улицы под значком «я» для плашки внизу (29.F, правила — StreetPill).
//
//  Раз в AppConfig.streetPillQueryInterval и только после сдвига на
//  streetPillQueryStepMeters карта спрашивает у движка ленты наших дорог в
//  маленьком квадрате у значка: у них в тайле есть `name`. Стоим с именем —
//  не спрашиваем; без имени — раз в интервал. Наружу уходит только смена имени.
//
//  Только картинка: ни голос, ни оповещения отсюда не читают.
//

#if canImport(MapLibre)
import CoreLocation
import MapLibre
import UIKit

@MainActor
final class EngineStreetProbe {

    /// Ленты наших дорог с именем из тайла (make_style: radar-roads…).
    static let layers: Set<String> = ["radar-roads", "radar-roads-stub", "radar-bridge", "radar-tunnel"]

    private var tracker = StreetPill.Tracker()
    private var lastQuery: CFTimeInterval = 0
    private var lastPoint: CLLocationCoordinate2D?
    /// Что последним ушло наружу (.none — ещё ничего).
    private var reported: String??

    func styleLoaded() {
        lastQuery = 0
        lastPoint = nil
    }

    func update(_ model: EngineMapView, at coordinate: CLLocationCoordinate2D?, in view: MLNMapView) {
        guard let report = model.onStreetName else { return }
        guard model.driving, model.showsPosition, let coordinate else {
            tracker.reset()
            lastPoint = nil
            send(nil, report)
            return
        }
        let now = CACurrentMediaTime()
        guard now - lastQuery >= AppConfig.streetPillQueryInterval else { return }
        if let lastPoint, GeoMath.fastDistance(lastPoint.latitude, lastPoint.longitude,
                                               coordinate.latitude, coordinate.longitude)
            < AppConfig.streetPillQueryStepMeters { return }
        lastQuery = now
        lastPoint = coordinate
        let point = view.convert(coordinate, toPointTo: view)
        let half = AppConfig.streetPillProbePoints / 2
        let rect = CGRect(x: point.x - half, y: point.y - half, width: 2 * half, height: 2 * half)
        var candidates: [StreetPill.Candidate] = []
        for feature in view.visibleFeatures(in: rect, styleLayerIdentifiers: Self.layers) {
            guard let name = feature.attribute(forKey: "name") as? String, !name.isEmpty else { continue }
            for line in Self.lines(of: feature) {
                guard let hit = StreetPill.nearest(line, to: coordinate) else { continue }
                candidates.append(StreetPill.Candidate(name: name, bearing: hit.bearing, distance: hit.distance))
            }
        }
        let raw = tracker.update(candidates, course: model.courseDegrees)
        // Имени нет (тайлы ещё не пришли, середина перекрёстка) — переспросить
        // через интервал и стоя: иначе первая пустая проба на стоянке
        // оставляла плашку пустой до первого сдвига машины.
        if raw == nil { lastPoint = nil }
        send(raw.map { StreetPill.label($0, language: model.labelLanguage, mapForm: model.carStyle != nil) }, report)
    }

    private func send(_ name: String?, _ report: (String?) -> Void) {
        if case .some(let last) = reported, last == name { return }
        reported = .some(name)
        report(name)
    }

    private static func lines(of feature: MLNFeature) -> [[CLLocationCoordinate2D]] {
        if let line = feature as? MLNPolylineFeature { return [coordinates(line)] }
        if let multi = feature as? MLNMultiPolylineFeature { return multi.polylines.map(coordinates) }
        return []
    }

    private static func coordinates(_ line: MLNPolyline) -> [CLLocationCoordinate2D] {
        let count = Int(line.pointCount)
        guard count > 0 else { return [] }
        var out = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        line.getCoordinates(&out, range: NSRange(location: 0, length: count))
        return out
    }
}
#endif
