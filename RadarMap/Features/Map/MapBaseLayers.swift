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
    /// Экран выбора варианта: маршрут есть, вариантов больше одного, не едем.
    private var choosing: Bool { env.route.variants.count > 1 && !env.location.isTripActive }

    /// Поля кадра «весь маршрут» по измеренным панелям (MapFrameState): доли
    /// высоты обратно в точки. Нижняя доля 0 — «ещё не мерили».
    private func overviewPadding(size: CGSize, insets: MapViewport.Insets) -> UIEdgeInsets {
        let height = Double(size.height)
        let p = RoutePreview.padding(width: Double(size.width), height: height,
                                     panelTop: insets.top * height,
                                     panelBottom: insets.bottom > 0 ? height * (1 - insets.bottom) : 0)
        return UIEdgeInsets(top: p.top, left: p.left, bottom: p.bottom, right: p.right)
    }

    /// Где выноске манёвра можно быть (29.G): между панелями, левее колонки
    /// кнопок; круг скорости в левом нижнем углу закрыт.
    private func calloutFrame(size: CGSize, insets: MapViewport.Insets) -> ManeuverCallout.Frame {
        let width = Double(size.width), height = Double(size.height)
        let clear = ManeuverCallout.clearRect(width: width, height: height, topShare: insets.safeTop,
                                              bottomShare: insets.safeBottom, left: 0,
                                              right: AppConfig.engineKeepSidePoints,
                                              margin: AppConfig.maneuverCalloutMarginPoints)
        let bottom = height * (1 - insets.safeBottom)
        let speed = CGRect(x: 0, y: bottom - AppConfig.maneuverCalloutSpeedBlockHeight,
                           width: AppConfig.maneuverCalloutSpeedBlockWidth,
                           height: AppConfig.maneuverCalloutSpeedBlockHeight)
        return ManeuverCallout.Frame(clear: clear, blocked: [speed])
    }

    var body: some View {
        // Без геопозиции («Никогда», ещё нет фикса) карта — не пустая подложка,
        // а город: камеры, поиск и «Итоги» работают и так (12в A10: до 20.10
        // экран был чёрным под двумя баннерами). Значка «я» тогда нет.
        let known = env.location.displayCoordinate ?? env.location.currentCoordinate
        let me = known ?? AppConfig.mapFallbackCenter
        do {
            let insets = state.insets
            let distance = env.location.displayNearestCamera != nil
                ? env.location.displayDistanceToNearest : nil
            let maneuverDistance = env.route.nextStep.map { _ in env.route.nextStepDistance }
            let cameraLine = env.cameraOnLine
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
            // Сервер карты лёг при живой связи — тоже на область (S22).
            let offlineFiles: OfflineFiles? = env.network.isMapOnline
                ? nil : env.offlineMaps.offlineFiles(at: me)
            GeometryReader { geo in
                // Что показывать сейчас (MapDetailPolicy, 29.H): вне поездки —
                // всё, как было; в поездке — как в машине, чуть плотнее.
                // Вид на остановке (29.D): «стоим» с гистерезисом, конец пробки —
                // один раз на тик, для кадра и для решения.
                let stop = StopViewInput.read(&map.stopView, env: env, maneuverDistance: maneuverDistance,
                                              active: env.location.isTripActive)
                let detail = detail(standing: stop.state.standing)
                let camera = camera(me: me, size: geo.size, insets: insets,
                                    maneuverDistance: maneuverDistance, stop: stop, keepPoints: detail.keepPoints)
                let inRange = distance.map { $0 <= camera.visibleAhead * AppConfig.engineCameraInRangeShare } ?? false
                ZStack {
                    EngineMapView(
                        coordinate: me,
                        courseDegrees: env.location.displayCourse,
                        spanMeters: camera.spanMeters,
                        anchorY: insets.meY,
                        pitchDegrees: camera.pitchDegrees,
                        // Тот же день/ночь, что у интерфейса (пересчёт раз в
                        // 5 мин и на смене настройки), а не расчёт солнца по
                        // живой координате на каждом фиксе (аудит энергии 19.10).
                        daylight: env.interfaceIsDaylight,
                        houses: env.settings.mapHouses,
                        cameras: [],
                        cameraRevision: env.cameras.revision,
                        limitRevision: env.speedLimits.indexRevision * 2 + (env.settings.speedLimitsEnabled ? 1 : 0),
                        cameraProvider: { env.cameras.cameras(in: $0, limit: $1) },
                        // Лимит — только у скорости, не под каждой камерой
                        // (владелец, 12.10); заодно нет сотни запросов лимитов
                        // на главном потоке при выезде за край области.
                        limitProvider: nil,
                        alertCameraID: inRange ? env.location.displayNearestCamera?.id : nil,
                        // Вариант B: цвет типа — только у камер на нашем пути;
                        // они же — на линии маршрута (27.B, CameraOnLine).
                        pathCameraIDs: cameraLine.pathIDs,
                        cameraPoints: cameraLine.points,
                        cameraZone: env.cameraZone(line: cameraLine),
                        familiarCameraIDs: env.location.familiarCameraIDs,
                        route: env.route.routeCoordinates,
                        routeObject: env.route.polyline,
                        routeProgress: env.route.progressAlong,
                        maneuverAlong: env.route.nextStep?.kind?.isDrawable == true ? env.route.nextStep?.distanceAlong : nil,
                        laneFocus: env.route.laneFocusStep,
                        maneuverKind: env.route.nextStep?.kind,
                        // Выноска манёвра (29.G) — в ведении: поездка и маршрут.
                        maneuverCallout: env.location.isTripActive ? ManeuverCallout.content(step: env.route.nextStep) : nil,
                        calloutFrame: calloutFrame(size: geo.size, insets: insets),
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
                        // камеры, а не на каждом фиксе. Накрыта карта только
                        // полноэкранным окном: в навигации предупреждение —
                        // карточка снизу, и карта с манёвром видна (19.10).
                        covered: env.location.isApproachingCamera
                            && !MapMode.current(isTripActive: env.location.isTripActive,
                                                hasRoute: env.route.isActive).showsManeuver,
                        cruise: env.location.isCruising,
                        detail: detail.decision,
                        detailMarks: detail.marks,
                        destinationApproach: detail.approach,
                        trafficEdges: env.traffic.isShown ? env.traffic.snapshot?.edges ?? [] : [],
                        trafficRevision: env.traffic.revision * 2 + (env.traffic.isShown ? 1 : 0),
                        trafficSnapshot: env.traffic.isShown ? env.traffic.snapshot : nil,
                        labelLanguage: env.settings.appLanguage.mapCode,
                        cursorStyle: env.settings.cursorStyle,
                        // Компас вокруг машины и знак смены лимита (29.B) — в поездке.
                        compass: env.location.isTripActive,
                        limitAhead: env.location.isTripActive ? env.speedLimits.limitAheadCue : nil,
                        overviewCommand: map.overviewCommand,
                        // Кадр «весь маршрут» — между НАСТОЯЩИМИ панелями (27.D).
                        overviewPadding: overviewPadding(size: geo.size, insets: insets),
                        variants: choosing ? env.route.variants.map {
                            RouteVariantLine(id: $0.id, polyline: $0.polyline, eta: $0.etaText)
                        } : [],
                        selectedVariantID: choosing ? env.route.selectedID : nil,
                        onSelectVariant: { id in
                            env.route.selectVariant(id)
                            UISelectionFeedbackGenerator().selectionChanged()
                        },
                        destination: detail.destination,
                        pressedPoint: map.pressedPoint?.coordinate,
                        roadEvents: env.mobile.roadEvents,
                        cngStations: env.cng.isActive ? env.cng.mapStations : [],
                        parkedCar: env.location.parkedCarOnMap?.coordinate,
                        hotspots: env.settings.tripodHints ? map.visibleHotspots.map(\.coordinate) : [],
                        centerCommand: map.centerCommand,
                        centerTarget: map.centerTarget,
                        onHeading: { map.noteMapDirection($0) },
                        onBrowse: { map.releaseToFree() },
                        onSelectCamera: onSelectCamera,
                        onLongPress: onLongPress,
                        onRegion: { map.updateVisible(for: $0) },
                        showsPosition: known != nil,
                        markerMotion: env.location.markerMotion,
                        // Плашка улицы (29.F): пишет только на смене имени.
                        onStreetName: { map.streetName = $0 })
                }
                .frame(width: geo.size.width, height: geo.size.height)
                // Подпись данных — над нижней панелью: «i» остаётся, текст
                // тает через пять секунд. Мишень «i» 44 pt, круг 20 — поля
                // считаны от круга: 12 pt от края, 8 pt над панелью; в
                // навигации — над кругом скорости (28.F).
                .overlay(alignment: .bottomLeading) {
                    MapAttribution()
                        .padding(.bottom, max(0, geo.size.height * insets.safeBottom - 4)
                                 + MapAttributionPlacement.lift(
                                    speedPlacement: MapMode.current(isTripActive: env.location.isTripActive,
                                                                    hasRoute: env.route.isActive).speedPlacement,
                                    isAddingCamera: map.isAddingCamera))
                }
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
        }
    }

    /// Камера карты. В поездке — DriveCamera (общая с машиной): масштаб, при
    /// котором видны полосы и нужные секунды пути впереди, наклон по
    /// скорости, у развилки — вид развилки, и она в кадре; плавно во времени.
    /// Вне поездки — обзор города, как раньше. «+ / −» сдвигают масштаб на
    /// ступень за нажатие. 3D — кнопкой «3D» (по умолчанию включено); на
    /// горячем телефоне — плоско: наклон тянет к горизонту втрое больше тайлов.
    /// Решение «что показывать» для телефона (MapDetailPolicy, 29.H). «Стоим»
    /// — из кадра остановки (StopView); накрыта карта — тем же правилом, что
    /// `covered` у движка.
    private func detail(standing: Bool) -> MapDetailInput.Output {
        let trip = env.location.isTripActive
        let covered = env.location.isApproachingCamera
            && !MapMode.current(isTripActive: trip, hasRoute: env.route.isActive).showsManeuver
        return MapDetailInput.read(&map.detailArriving, env: env, surface: .phone, tripActive: trip,
                                   standing: standing, night: !env.interfaceIsDaylight, covered: covered)
    }

    private func camera(me: CLLocationCoordinate2D, size: CGSize, insets: MapViewport.Insets,
                        maneuverDistance: Double?, stop: StopViewInput.Input,
                        keepPoints: [CLLocationCoordinate2D] = []) -> (spanMeters: Double, pitchDegrees: Double,
                                                                         visibleAhead: Double) {
        let pitchAllowed = map.prefers3D && env.thermal.mode == .full
        let viewHeight = max(1, Double(size.height))
        guard env.location.isTripActive else {
            map.cameraSmoother.reset()
            let span = AppConfig.engineOverviewSpan * pow(2, -map.zoomBias)
            let pitch = pitchAllowed ? AppConfig.engineOverviewPitchDegrees : 0
            let zoom = log2(DriveCamera.span(zoom: 0, viewHeight: viewHeight, latitude: me.latitude) / span)
            return (span, pitch, DriveCamera.visibleAhead(zoom: zoom, pitchDegrees: pitch, viewHeight: viewHeight,
                                                          carY: insets.meY, latitude: me.latitude))
        }
        // Ближайшая камера в 500 м — в кадре всегда и в любую сторону: «368 м
        // до радара» над картой, на которой радара не видно, — «куда пропал
        // радар?» (владелец, 12.10); стоя курса нет, и камера бывает сбоку.
        // Поворот — тот, что у карты: север, курс или последний (движок).
        let bearing: Double = map.orientation == .following ? 0
            : (env.location.displayCourse >= 0 ? env.location.displayCourse : map.displayedDirection)
        // Своя камера («без голоса») — не цель (снимок 63, 21.10).
        let keep = env.location.displayNearestCamera.flatMap {
            DriveCamera.keep(camera: $0.id, at: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                             familiar: env.location.familiarCameraIDs, from: me, bearing: bearing)
        }
        let clear = DriveCamera.Clear(top: insets.safeTop, bottom: insets.safeBottom,
                                      width: Double(size.width), side: AppConfig.engineKeepSidePoints)
        // У цели кадр держит и её, и ближайшие парковки (29.H) — вместе с камерой.
        let arrivalKeep = keepPoints.map { DriveCamera.Keep.offset(from: me, to: $0, bearing: bearing) }
        let target = DriveCamera.target(speedKmh: env.location.speedKmh, maneuverDistance: maneuverDistance,
                                        pitchAllowed: pitchAllowed, keep: keep,
                                        stop: stop.state, jamEnd: stop.jamEnd, alsoKeep: arrivalKeep,
                                        viewHeight: viewHeight, latitude: me.latitude,
                                        clear: clear, carY: { _ in insets.meY })
        let frame = map.cameraSmoother.step(toward: target, at: Date())
        let zoom = frame.zoom + map.zoomBias
        return (DriveCamera.span(zoom: zoom, viewHeight: viewHeight, latitude: me.latitude),
                frame.pitchDegrees,
                DriveCamera.visibleAhead(zoom: zoom, pitchDegrees: frame.pitchDegrees, viewHeight: viewHeight,
                                         carY: insets.meY, latitude: me.latitude))
    }
}
#endif
