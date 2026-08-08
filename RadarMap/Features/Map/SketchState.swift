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
    /// Когда пришёл прошлый тик: анимация точки зрения длится ровно до
    /// следующего ожидаемого фикса, а не фиксированную секунду.
    @ObservationIgnored private var lastTickAt: Date?
    /// Мелкие улицы видны (мы сами на такой). Два тика подряд на смену:
    /// на границе двора с проспектом решение не должно мигать.
    @ObservationIgnored private var minorsVisible = false
    @ObservationIgnored private var minorFlipTicks = 0

    /// Тик GPS: дёргается из DashboardView по locationTick. `now` — параметр
    /// (не Date() внутри): ритм анимации детерминирован в тестах.
    func refresh(_ env: AppEnvironment, now: Date = Date()) {
        // Схема на приборке — единственное, что считается на каждом тике ради
        // картинки. Она обязана быть самым дешёвым экраном, а не самым дорогим,
        // и проверять это надо приборами, а не на глаз.
        let token = Perf.begin(Perf.Name.sketchRefresh)
        defer { token.end() }
        // Координата и курс ДЛЯ КАРТИНКИ: прижаты к оси дороги, когда мы на
        // ней (RoadSnapper). Стрелка идёт по полотну, а не по газону рядом,
        // и схему не покачивает от бокового шума GPS.
        guard let me = env.location.displayCoordinate
            ?? env.location.currentCoordinate else { return }
        unwoundCourse = RoadSketch.unwound(unwoundCourse,
                                           towards: env.location.displayCourse >= 0
                                               ? env.location.displayCourse
                                               : env.location.currentCourse)
        // Курса не было ни разу (только запустились): повернуть схему наугад
        // значило бы соврать направлением.
        guard let course = unwoundCourse else { return }
        hasCourse = true

        // Тайлы окрестности: дёшево, когда всё на месте; скачивает недостающее
        // только пока приборка на экране.
        env.roads.ensureCoverage(around: me)

        let alert = env.location.nearestCamera
        let distance = env.location.distanceToNearest
        let span = RoadSketch.span(forDistance: alert != nil ? distance : nil)
        let inRange: Bool = if let distance, alert != nil {
            RoadSketch.isInRange(distance: distance, span: span)
        } else {
            false
        }

        // Мелкие улицы: видны, только когда мы сами на такой. Решение с
        // гистерезисом в два тика — иначе на границе двора с проспектом
        // растр пересобирался бы туда-сюда.
        let wantsMinors = RoadSketch.prefersMinorRoads(network: network(env), at: me)
        if wantsMinors != minorsVisible {
            minorFlipTicks += 1
            if minorFlipTicks >= 2 {
                minorsVisible = wantsMinors
                minorFlipTicks = 0
            }
        } else {
            minorFlipTicks = 0
        }

        let freshKey = RoadSketch.RebuildKey(
            alertCameraID: inRange ? alert?.id : nil,
            alertInRange: inRange,
            spanBucket: RoadSketch.bucket(forSpan: span),
            routeToken: env.route.polyline.map(ObjectIdentifier.init),
            networkGeneration: env.speedLimits.indexRevision,
            roadsGeneration: env.roads.revision,
            storeRevision: env.cameras.revision,
            budget: env.thermal.mode.sketchNetworkBudget,
            minorRoads: minorsVisible)
        let offset = offsetMeters(of: me)

        // Плавность — это ритм: анимация длится до следующего ОЖИДАЕМОГО
        // фикса (лучшее предсказание интервала — предыдущий), а не жёсткую
        // секунду. С константой схема секунду ехала и две стояла — фиксы на
        // крейсере приходят раз в 15–25 метров.
        let duration = TickPacing.animationDuration(
            sincePreviousTick: lastTickAt.map { now.timeIntervalSince($0) })
        lastTickAt = now

        if RoadSketch.needsRebuild(scene: scene, key: freshKey, previousKey: key,
                                   meOffsetMeters: offset) {
            // Переезд опоры: растр и смещение меняются в одном кадре без
            // анимации и взаимно компенсируются — картинка стоит на месте.
            scene = build(env: env, me: me, span: span,
                          alert: alert, inRange: inRange)
            meOffset = .zero
            withAnimation(.linear(duration: duration)) {
                courseDegrees = course
                spanMeters = span
            }
        } else {
            // Гейт неподвижности: на светофоре тики идут, а картинка стоит —
            // не пишем ничего, и композитор не получает ни кадра работы.
            let offsetDelta = hypot(offset.x - meOffset.width,
                                    offset.y - meOffset.height)
            if RoadSketch.viewpointMoved(offsetDeltaMeters: offsetDelta,
                                         courseDeltaDegrees: abs(course - courseDegrees),
                                         spanChanged: span != spanMeters) {
                withAnimation(.linear(duration: duration)) {
                    meOffset = CGSize(width: offset.x, height: offset.y)
                    courseDegrees = course
                    spanMeters = span
                }
            }
        }
        key = freshKey
    }

    /// Один источник сети на тик и на сборку: свои тайлы, где есть, иначе
    /// индекс лимитов.
    private func network(_ env: AppEnvironment) -> FallbackRoadNetwork {
        FallbackRoadNetwork(primary: env.roads.network,
                            fallback: env.speedLimits.sketchNetwork)
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
                                // Свои тайлы (классы, мосты, дворы), где они
                                // уже есть; иначе — сеть из индекса лимитов.
                                network: network(env),
                                networkBudget: env.thermal.mode.sketchNetworkBudget,
                                showMinorRoads: minorsVisible,
                                route: env.route.routeCoordinates,
                                track: env.trip.recentTrack(),
                                anchor: me, spanMeters: span)
    }
}
