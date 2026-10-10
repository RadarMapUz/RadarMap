//
//  CarPlayEngineLayer.swift
//  RadarMap
//
//  Наша карта на экране машины — тот же движок (MapLibre), что на телефоне.
//
//  До 10.10.2026 в CarPlay стояла карта Apple (MKMapView), и это была не
//  просто чужая картинка. Метку на ней вёл сам MapKit СВОИМ GPS, а скорость,
//  камеры и док читали наш LocationService: метка ехала даже тогда, когда наш
//  конвейер стоял, — на экране машина двигалась, а км/ч и камеры молчали.
//  Здесь положение и курс одни на всё: displayCoordinate/displayCourse.
//
//  Касаний в окне CarPlay нет: панораму, «+/−» и «к себе» присылает шаблон
//  (CPMapTemplateDelegate) — командами через CarPlayMapModel.
//
//  Отдельная вью — изолятор пер-тиковых чтений, как EngineBaseLayer на
//  телефоне: тик пересобирает её, а не экран с HUD.
//

#if canImport(MapLibre)
import SwiftUI

struct CarPlayEngineLayer: View {
    @Environment(AppEnvironment.self) private var env
    let model: CarPlayMapModel
    /// Плитка приборной панели: без дока внизу, «я» — по своей доле высоты.
    var compact = false

    var body: some View {
        // Без своей позиции карты нет: центр «где-то в Ташкенте» выдал бы
        // чужой район за место машины. Док при этом честно скажет «нет GPS».
        if let me = env.location.displayCoordinate ?? env.location.currentCoordinate {
            GeometryReader { geo in
                map(me: me, size: geo.size, safe: geo.safeAreaInsets)
                    .ignoresSafeArea()
                    .overlay(alignment: .bottomTrailing) { attribution }
            }
            .onAppear(perform: adopt)
        } else {
            Theme.background.ignoresSafeArea()
        }
    }

    private func map(me: CLLocationCoordinate2D, size: CGSize, safe: EdgeInsets) -> some View {
        let maneuverDistance = env.route.nextStep.map { _ in env.route.nextStepDistance }
        let span = EngineMapPresentation.span(speedKmh: env.location.speedKmh,
                                              maneuverDistance: maneuverDistance,
                                              active: env.location.isTripActive)
        // Наклон — только на холодном телефоне: картинка в машину рисуется на
        // телефоне, а 3D дороже плоской. К манёвру уходит в ноль — развилку
        // видно сверху (то же правило, что на телефоне).
        let pitch = env.thermal.mode != .full ? 0 : (AppConfig.engineMapPitchDegrees
            * min(1, max(0, (maneuverDistance ?? AppConfig.engineManeuverApproachMeters)
                         / AppConfig.engineManeuverApproachMeters))
            / AppConfig.enginePitchStep).rounded() * AppConfig.enginePitchStep
        let offlineFiles: OfflineFiles? = env.network.isOnline
            ? nil : env.offlineMaps.offlineFiles(at: me)
        return EngineMapView(
            coordinate: me,
            courseDegrees: env.location.displayCourse,
            spanMeters: (span * pow(2, -model.zoomBias) / AppConfig.engineSpanStep).rounded()
                * AppConfig.engineSpanStep,
            anchorY: compact ? AppConfig.carPlayDashboardMeY : Self.meY(size: size, safe: safe),
            pitchDegrees: pitch,
            daylight: model.isDaylight,
            houses: env.settings.mapHouses,
            cameras: [],
            cameraRevision: env.cameras.revision,
            limitRevision: env.speedLimits.indexRevision * 2 + (env.settings.speedLimitsEnabled ? 1 : 0),
            cameraProvider: { env.cameras.cameras(in: $0, limit: AppConfig.engineCameraViewportLimit) },
            limitProvider: { env.settings.speedLimitsEnabled ? env.speedLimits.limit(near: $0.coordinate) : nil },
            alertCameraID: env.location.isApproachingCamera ? env.location.nearestCamera?.id : nil,
            route: env.route.routeCoordinates,
            routeObject: env.route.polyline,
            routeProgress: env.route.progressAlong,
            maneuverAlong: env.route.nextStep?.kind?.isDrawable == true ? env.route.nextStep?.distanceAlong : nil,
            recenterToken: model.recenterRequests,
            modernStyle: env.settings.mapModernStyle,
            performance: env.thermal.mode,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            // В машине карта всегда «по ходу»: это навигатор. Без курса
            // (стоим) движок карту не крутит и держит последний поворот.
            northUp: false,
            zoomCommand: model.zoomCommand,
            zoomDelta: model.zoomDelta,
            offline: offlineFiles,
            places: false,
            // Режим «в поездке» всегда: без кафе, номеров домов и подписей
            // дорожек — экран машины читают боковым зрением.
            driving: true,
            labelLanguage: env.settings.appLanguage.mapCode,
            cursorStyle: env.settings.cursorStyle,
            panTotal: model.panTotal,
            hidesAttribution: true,
            onBrowse: { if model.isFollowing { model.isFollowing = false } })
    }

    /// Новая карта (вернулись из музыки, из схемы) стартует со слежения —
    /// модель обязана сказать то же: иначе после давней панорамы «+/−» шли
    /// в «свободную карту», которой нет, а «к себе» показывал «не следим».
    private func adopt() {
        if !model.isFollowing { model.isFollowing = true }
    }

    /// Ссылка на данные обязана быть на экране (тайлы построены по OSM), а
    /// нажать кнопку атрибуции в машине нельзя — поэтому текстом.
    private var attribution: some View {
        Text(verbatim: "© OpenStreetMap")
            .font(.rounded(10, .medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.background.opacity(0.6), in: Capsule())
            .padding(.trailing, 6)
            .padding(.bottom, 4)
            .allowsHitTesting(false)
    }

    /// Где «я» по высоте всего окна (0 — верх, 1 — низ). Свободное поле —
    /// между верхней safe area (бар CarPlay) и приборной панелью HUD; «я»
    /// стоит на AppConfig.carPlayMeShare его высоты. Окно — на всю высоту,
    /// поэтому доля считается от полной высоты с safe area.
    static func meY(size: CGSize, safe: EdgeInsets) -> Double {
        let full = size.height + safe.top + safe.bottom
        guard full > 0 else { return AppConfig.mapMeY }
        let top = safe.top + 12
        let bottom = full - safe.bottom - AppConfig.carPlayDockReserve - 12
        guard bottom > top else { return AppConfig.mapMeY }
        return Double((top + (bottom - top) * AppConfig.carPlayMeShare) / full)
    }
}
#endif
