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

import CoreLocation
import SwiftUI

#if canImport(MapLibre)
/// Карта на движке: охват по скорости и дистанции до камеры, поля вида от
/// панелей (MapFrameState), наклон уходит в ноль, когда камера в охвате.
struct EngineBaseLayer: View {
    var onSelectCamera: (Camera) -> Void = { _ in }
    var onLongPress: (CLLocationCoordinate2D) -> Void = { _ in }
    @Environment(AppEnvironment.self) private var env
    let state: MapFrameState
    /// Общий вид главного экрана: ориентация, 3D, масштаб кнопками — одни на
    /// карту Apple и движок, чтобы кнопки на карте значили одно и то же.
    let map: MapState
    @State private var recenterToken = 0
    private var browsing: Bool { map.orientation == .free }

    var body: some View {
        let me = env.location.displayCoordinate ?? env.location.currentCoordinate
        if let me {
            let insets = state.insets
            let distance = env.location.nearestCamera != nil
                ? env.location.distanceToNearest : nil
            let maneuverDistance = env.route.nextStep.map { _ in env.route.nextStepDistance }
            // Размер берётся у КОНТЕЙНЕРА, а не у UIScreen.main.
            //
            // UIScreen.main объявлен устаревшим и вдобавок отвечает неверно
            // ровно там, где это приложение живёт: при подключённом CarPlay
            // «главный экран» может оказаться не телефоном, и курсор машины
            // уехал бы мимо. Геометрия контейнера верна всегда.
            // Без связи — файлы скачанного региона, если машина в нём; со
            // связью — всегда онлайн (свежий выпуск). Отдельной константой:
            // внутри огромного вызова ниже тернарник с опционалом заставлял
            // компилятор выводить типы минутами.
            let offlineFiles: OfflineFiles? = env.network.isOnline
                ? nil : env.offlineMaps.offlineFiles(at: me)
            GeometryReader { geo in
                let camera = camera(me: me, height: geo.size.height, insets: insets,
                                    maneuverDistance: maneuverDistance)
                let inRange = distance.map { $0 <= camera.visibleAhead * AppConfig.engineCameraInRangeShare } ?? false
                ZStack {
                    EngineMapView(
                        coordinate: me,
                        courseDegrees: env.location.displayCourse,
                        spanMeters: camera.spanMeters,
                        anchorY: insets.meY,
                        pitchDegrees: camera.pitchDegrees,
                        daylight: env.settings.mapAppearance.isDaylight(at: me, now: Date()),
                        houses: env.settings.mapHouses,
                        cameras: [],
                        cameraRevision: env.cameras.revision,
                        limitRevision: env.speedLimits.indexRevision * 2 + (env.settings.speedLimitsEnabled ? 1 : 0),
                        cameraProvider: { env.cameras.cameras(in: $0, limit: AppConfig.engineCameraViewportLimit) },
                        // Лимит — только у скорости, не под каждой камерой
                        // (владелец, 12.10); заодно нет сотни запросов лимитов
                        // на главном потоке при выезде за край области.
                        limitProvider: nil,
                        alertCameraID: inRange ? env.location.nearestCamera?.id : nil,
                        route: env.route.routeCoordinates,
                        routeObject: env.route.polyline,
                        routeProgress: env.route.progressAlong,
                        maneuverAlong: env.route.nextStep?.kind?.isDrawable == true ? env.route.nextStep?.distanceAlong : nil,
                        recenterToken: recenterToken,
                        modernStyle: env.settings.mapModernStyle,
                        performance: env.thermal.mode,
                        lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                        northUp: map.orientation == .following,
                        zoomCommand: map.zoomCommand,
                        zoomDelta: map.lastZoomDelta,
                        offline: offlineFiles,
                        places: env.settings.mapPlaces,
                        driving: env.location.isTripActive,
                        // Хранимый флаг: меняется на въезде и выезде из зоны
                        // камеры, а не на каждом фиксе.
                        covered: env.location.isApproachingCamera,
                        trafficEdges: env.traffic.isShown ? env.traffic.snapshot?.edges ?? [] : [],
                        trafficRevision: env.traffic.revision * 2 + (env.traffic.isShown ? 1 : 0),
                        labelLanguage: env.settings.appLanguage.mapCode,
                        cursorStyle: env.settings.cursorStyle,
                        overviewCommand: map.overviewCommand,
                        destination: env.route.destinationCoordinate,
                        pressedPoint: map.pressedPoint?.coordinate,
                        hotspots: env.settings.tripodHints ? map.visibleHotspots.map(\.coordinate) : [],
                        centerCommand: map.centerCommand,
                        centerTarget: map.centerTarget,
                        onHeading: { map.noteMapDirection($0) },
                        onBrowse: { map.releaseToFree() },
                        onSelectCamera: onSelectCamera,
                        onLongPress: onLongPress,
                        onRegion: { map.updateVisible(for: $0) })
                    if browsing {
                        VStack {
                            Spacer()
                            Button {
                                map.cycleOrientation(coordinate: env.location.currentCoordinate,
                                                     course: env.location.currentCourse,
                                                     inTrip: env.location.isTripActive)
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
                // Высоту сообщает сама карта: без неё поля панелей не
                // посчитать, и «я» стоял бы под нижней панелью.
                .onAppear { state.setViewHeight(geo.size.height) }
                .onChange(of: geo.size.height) { _, height in state.setViewHeight(height) }
                // Кнопка «моё местоположение» (или «К машине») вывела карту из
                // свободы — движок снова цепляется за машину.
                .onChange(of: map.orientation) { old, new in
                    if old == .free, new != .free { recenterToken += 1 }
                }
            }
        } else {
            SketchPalette.ground
        }
    }

    /// Камера карты. В поездке — DriveCamera (общая с машиной): масштаб, при
    /// котором видны полосы и нужные секунды пути впереди, наклон по
    /// скорости, у развилки — вид развилки, и она в кадре; плавно во времени.
    /// Вне поездки — обзор города, как раньше. «+ / −» сдвигают масштаб на
    /// ступень за нажатие. 3D — кнопкой «3D» (по умолчанию включено); на
    /// горячем телефоне — плоско: наклон тянет к горизонту втрое больше тайлов.
    private func camera(me: CLLocationCoordinate2D, height: CGFloat, insets: RoadSketch.Insets,
                        maneuverDistance: Double?) -> (spanMeters: Double, pitchDegrees: Double,
                                                       visibleAhead: Double) {
        let pitchAllowed = map.prefers3D && env.thermal.mode == .full
        let viewHeight = max(1, Double(height))
        guard env.location.isTripActive else {
            map.cameraSmoother.reset()
            let span = AppConfig.engineOverviewSpan * pow(2, -map.zoomBias)
            let pitch = pitchAllowed ? AppConfig.engineMapPitchDegrees : 0
            let zoom = log2(DriveCamera.span(zoom: 0, viewHeight: viewHeight, latitude: me.latitude) / span)
            return (span, pitch, DriveCamera.visibleAhead(zoom: zoom, pitchDegrees: pitch, viewHeight: viewHeight,
                                                          carY: insets.meY, latitude: me.latitude))
        }
        let target = DriveCamera.target(speedKmh: env.location.speedKmh, maneuverDistance: maneuverDistance,
                                        pitchAllowed: pitchAllowed, viewHeight: viewHeight,
                                        latitude: me.latitude, carY: { _ in insets.meY })
        let frame = map.cameraSmoother.step(toward: target, at: Date())
        let zoom = frame.zoom + map.zoomBias
        return (DriveCamera.span(zoom: zoom, viewHeight: viewHeight, latitude: me.latitude),
                frame.pitchDegrees,
                DriveCamera.visibleAhead(zoom: zoom, pitchDegrees: frame.pitchDegrees, viewHeight: viewHeight,
                                         carY: insets.meY, latitude: me.latitude))
    }
}
#endif
