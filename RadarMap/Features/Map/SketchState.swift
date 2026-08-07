//
//  SketchState.swift
//  RadarMap
//
//  Экранная модель схемы приборки: держит сцену «север вверху» и точку
//  зрения, решает, когда пересобирать растр, и анимирует движение между
//  GPS-тиками. Сами решения — чистые функции RoadSketch (тестируются),
//  здесь только их привязка к сервисам и к анимации.
//
//  Анимация нарочно императивная (withAnimation при записи значений), а не
//  декларативная (.animation во вью): при пересборке растра опора «переезжает»
//  в текущую точку, и смещение с растром обязаны смениться В ОДНОМ кадре БЕЗ
//  анимации — они взаимно компенсируются, и картинка не дёргается. Анимировать
//  этот переход значило бы секунду везти новый растр на место старого.
//

import CoreLocation
import MapKit
import Observation
import SwiftUI

@MainActor
@Observable
final class SketchState {
    /// Растр: пересобирается на смене данных или уходе от опоры (needsRebuild).
    private(set) var scene: RoadSketch.Scene?
    /// Я относительно опоры сцены, метры (восток, север). Анимируется каждый
    /// тик — движение между тиками изображает transform, а не перерисовка.
    private(set) var meOffset = CGSize.zero
    /// Размотанный курс (может выходить за 0…360 — так поворот 359°→1°
    /// анимируется на +2°, а не на −358°).
    private(set) var courseDegrees = 0.0
    /// Точный охват вида; растр докручивается scaleEffect'ом до него.
    private(set) var spanMeters = RoadSketch.minSpanMeters
    /// Курс был хоть раз: без него схему не поворачиваем и не показываем.
    private(set) var hasCourse = false

    @ObservationIgnored private var unwoundCourse: Double?
    @ObservationIgnored private var key: RoadSketch.RebuildKey?

    /// Тик GPS: дёргается из DashboardView по locationTick.
    func refresh(_ env: AppEnvironment) {
        guard let me = env.location.currentCoordinate else { return }
        unwoundCourse = RoadSketch.unwound(unwoundCourse,
                                           towards: env.location.currentCourse)
        // Курса не было ни разу (только запустились): повернуть схему наугад
        // значило бы соврать направлением.
        guard let course = unwoundCourse else { return }
        hasCourse = true

        let alert = env.location.nearestCamera
        let distance = env.location.distanceToNearest
        let span = RoadSketch.span(forDistance: alert != nil ? distance : nil)
        let inRange: Bool = if let distance, alert != nil {
            RoadSketch.isInRange(distance: distance, span: span)
        } else {
            false
        }

        let freshKey = RoadSketch.RebuildKey(
            alertCameraID: inRange ? alert?.id : nil,
            alertInRange: inRange,
            spanBucket: RoadSketch.bucket(forSpan: span),
            routeToken: env.route.polyline.map(ObjectIdentifier.init),
            networkGeneration: env.speedLimits.indexRevision,
            storeRevision: env.cameras.revision,
            budget: env.thermal.mode.sketchNetworkBudget)
        let offset = offsetMeters(of: me)

        if RoadSketch.needsRebuild(scene: scene, key: freshKey, previousKey: key,
                                   meOffsetMeters: offset) {
            // Переезд опоры: растр и смещение меняются в одном кадре без
            // анимации и взаимно компенсируются — картинка стоит на месте.
            scene = build(env: env, me: me, span: span,
                          alert: alert, inRange: inRange)
            meOffset = .zero
            withAnimation(.linear(duration: 1)) {
                courseDegrees = course
                spanMeters = span
            }
        } else {
            withAnimation(.linear(duration: 1)) {
                meOffset = CGSize(width: offset.x, height: offset.y)
                courseDegrees = course
                spanMeters = span
            }
        }
        key = freshKey
    }

    private func offsetMeters(of me: CLLocationCoordinate2D) -> CGPoint {
        guard let scene else { return .zero }
        let anchor = scene.anchor
        return CGPoint(
            x: (me.longitude - anchor.longitude)
                * 111_320.0 * cos(anchor.latitude * .pi / 180),
            y: (me.latitude - anchor.latitude) * 111_320.0)
    }

    private func build(env: AppEnvironment, me: CLLocationCoordinate2D,
                       span: Double, alert: Camera?, inRange: Bool) -> RoadSketch.Scene {
        let radius = RoadSketch.sceneRadius(forSpan: span)
        // Камеры охвата — как на карте: с учётом фильтра вида. Тревожную
        // scene() гарантирует сама, даже если фильтр её спрятал.
        let region = MKCoordinateRegion(center: me, latitudinalMeters: radius * 2,
                                        longitudinalMeters: radius * 2)
        let dots = env.cameras.cameras(in: region, limit: 80)
            .filter { env.settings.filter.matches($0) }
        return RoadSketch.scene(alertCamera: alert, alertInRange: inRange,
                                cameras: dots,
                                network: env.speedLimits.sketchNetwork,
                                networkBudget: env.thermal.mode.sketchNetworkBudget,
                                route: env.route.routeCoordinates,
                                track: env.trip.recentTrack(),
                                anchor: me, spanMeters: span)
    }
}
