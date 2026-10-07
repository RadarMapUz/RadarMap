//
//  MapBaseLayers.swift
//  RadarMap
//
//  Наша подложка главного экрана отдельной вью — и это не декомпозиция ради
//  декомпозиции.
//
//  Она читает то, что пишется КАЖДЫМ GPS-тиком: дистанцию до камеры, скорость,
//  координату, курс. Пока они лежали кусками `body` в MapScreen, включённая
//  «Своя схема» или «Движок» пересобирали весь экран вместе с картой,
//  панелями и презентациями раз в секунду.
//
//  Защита от этого на экране была — изоляторы `OverspeedVignetteGate`,
//  `LocationFollowDriver` и другие, и рядом с каждым написано,
//  почему он существует. Но прикрывали они только подложку Apple: тот, кто
//  включал НАШУ карту, получал ровно ту болезнь, от которой их заводили.
//
//  Теперь чтение тика заперто внутри этих двух вью: `body` MapScreen читает у
//  них только «какая подложка» и «есть ли сцена».
//

import SwiftUI

#if canImport(MapLibre)
/// Карта на движке. Правила точки зрения — ТЕ ЖЕ, что у схемы: охват по
/// скорости и дистанции до камеры, поля вида от панелей, наклон уходит в ноль,
/// когда камера в охвате. Один закон на два рендера, иначе переключатель
/// сравнивал бы не рендеры, а две разные логики.
struct EngineBaseLayer: View {
    var onSelectCamera: (Camera) -> Void = { _ in }
    @Environment(AppEnvironment.self) private var env
    let state: SketchState
    @State private var browsing = false
    @State private var recenterToken = 0

    var body: some View {
        let me = env.location.displayCoordinate ?? env.location.currentCoordinate
        if let me {
            let insets = state.insets
            let distance = env.location.nearestCamera != nil
                ? env.location.distanceToNearest : nil
            let maneuverDistance = env.route.nextStep.map { _ in env.route.nextStepDistance }
            let span = EngineMapPresentation.span(speedKmh: env.location.speedKmh,
                                                  maneuverDistance: maneuverDistance,
                                                  active: env.location.isTripActive)
            let inRange = distance.map {
                RoadSketch.isInRange(distance: $0, span: span, insets: insets)
            } ?? false
            // Размер берётся у КОНТЕЙНЕРА, а не у UIScreen.main.
            //
            // UIScreen.main объявлен устаревшим и вдобавок отвечает неверно
            // ровно там, где это приложение живёт: при подключённом CarPlay
            // «главный экран» может оказаться не телефоном, и курсор машины
            // уехал бы мимо. Геометрия контейнера верна всегда.
            GeometryReader { geo in
                ZStack {
                    EngineMapView(
                        coordinate: me,
                        courseDegrees: env.location.displayCourse,
                        // Ступенями: дрожание скорости и дистанции до манёвра на
                        // стоянке запускало новую анимацию камеры каждый фикс.
                        spanMeters: (span / AppConfig.engineSpanStep).rounded() * AppConfig.engineSpanStep,
                        anchorY: insets.meY,
                        pitchDegrees: !env.location.isTripActive ? 0 : (AppConfig.engineMapPitchDegrees
                            * min(1, max(0, (maneuverDistance ?? AppConfig.engineManeuverApproachMeters)
                                         / AppConfig.engineManeuverApproachMeters))
                            / AppConfig.enginePitchStep).rounded() * AppConfig.enginePitchStep,
                        daylight: env.settings.mapAppearance.isDaylight(at: me, now: Date()),
                        houses: env.settings.mapHouses,
                        cameras: [],
                        cameraRevision: env.cameras.revision,
                        limitRevision: env.speedLimits.indexRevision * 2 + (env.settings.speedLimitsEnabled ? 1 : 0),
                        cameraProvider: { env.cameras.cameras(in: $0, limit: AppConfig.engineCameraViewportLimit) },
                        limitProvider: { env.settings.speedLimitsEnabled ? env.speedLimits.limit(near: $0.coordinate) : nil },
                        alertCameraID: inRange ? env.location.nearestCamera?.id : nil,
                        route: env.route.routeCoordinates,
                        routeObject: env.route.polyline,
                        routeProgress: env.route.progressAlong,
                        maneuverAlong: env.route.nextStep?.kind?.isDrawable == true ? env.route.nextStep?.distanceAlong : nil,
                        recenterToken: recenterToken,
                        modernStyle: env.settings.mapModernStyle,
                        performance: env.thermal.mode,
                        lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                        onBrowse: { browsing = true },
                        onSelectCamera: onSelectCamera)
                    if browsing {
                        VStack {
                            Spacer()
                            Button {
                                browsing = false
                                recenterToken += 1
                            } label: {
                                Label("К машине", systemImage: "location.fill")
                                    .font(.rounded(14, .semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(.regularMaterial, in: Capsule())
                            }
                            .tapTarget()
                            .padding(.bottom, geo.size.height * (1 - insets.meY) + 32)
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            SketchPalette.ground
        }
    }
}
#endif
