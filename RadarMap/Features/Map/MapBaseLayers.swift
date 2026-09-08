//
//  MapBaseLayers.swift
//  RadarMap
//
//  Свои подложки главного экрана отдельными вью — и это не декомпозиция ради
//  декомпозиции.
//
//  Обе читают то, что пишется КАЖДЫМ GPS-тиком: дистанцию до камеры, скорость,
//  координату, курс. Пока они лежали кусками `body` в MapScreen, включённая
//  «Своя схема» или «Движок» пересобирали весь экран вместе с картой,
//  панелями и презентациями раз в секунду.
//
//  Защита от этого на экране была — изоляторы `OverspeedVignetteGate`,
//  `LocationFollowDriver`, `SketchRefreshDriver`, и рядом с каждым написано,
//  почему он существует. Но прикрывали они только подложку Apple: тот, кто
//  включал НАШУ карту, получал ровно ту болезнь, от которой их заводили.
//
//  Теперь чтение тика заперто внутри этих двух вью: `body` MapScreen читает у
//  них только «какая подложка» и «есть ли сцена».
//

import SwiftUI

/// Своя схема во весь экран.
struct SketchBaseLayer: View {
    @Environment(AppEnvironment.self) private var env
    let scene: RoadSketch.Scene
    let state: SketchState

    var body: some View {
        ZStack {
            // Подложка — ЗЕМЛЯ схемы, а не чёрное. Днём чёрная подложка
            // проступала по краям и в переходах и выглядела дырой.
            SketchPalette.ground
            RoadSketchView(scene: scene, state: state, tint: tint,
                           trim: env.thermal.mode.sketchTrim,
                           loading: env.roads.pending)
        }
        .ignoresSafeArea()
    }

    /// Тон схемы по близости камеры — те же три ступени, что на приборке.
    /// Ближе трети радиуса — опасность, ближе двух третей — внимание, иначе
    /// нейтральный акцент. Второй такой лестницы в приложении заводить нельзя:
    /// водитель читает цвет, а не число, и две разные лестницы — это два
    /// разных смысла у одного красного.
    private var tint: Color {
        guard let distance = env.location.distanceToNearest else { return Theme.accent }
        let radius = AlertEngine.effectiveRadius(speedKmh: env.location.speedKmh,
                                                 baseRadius: env.settings.alertRadius,
                                                 context: env.location.alertContext)
        if distance <= radius * 0.3 { return Theme.danger }
        if distance <= radius * 0.6 { return Theme.warning }
        return Theme.accent
    }
}

#if canImport(MapLibre)
/// Карта на движке. Правила точки зрения — ТЕ ЖЕ, что у схемы: охват по
/// скорости и дистанции до камеры, поля вида от панелей, наклон уходит в ноль,
/// когда камера в охвате. Один закон на два рендера, иначе переключатель
/// сравнивал бы не рендеры, а две разные логики.
struct EngineBaseLayer: View {
    var onSelectCamera: (Camera) -> Void = { _ in }
    @Environment(AppEnvironment.self) private var env
    let state: SketchState

    var body: some View {
        let me = env.location.displayCoordinate ?? env.location.currentCoordinate
        if let me {
            let insets = state.insets
            let cameras = env.cameras.nearest(to: me, limit: 40)
            let limits: [Int: Int] = env.settings.speedLimitsEnabled
                ? Dictionary(uniqueKeysWithValues: cameras.compactMap { camera in
                    env.speedLimits.limit(near: camera.coordinate).map { (camera.id, $0) }
                }) : [:]
            let distance = env.location.nearestCamera != nil
                ? env.location.distanceToNearest : nil
            let span = env.location.isTripActive
                ? max(450, RoadSketch.span(forDistance: distance,
                                          speedKmh: env.location.speedKmh, insets: insets))
                : 1_400
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
                        spanMeters: span,
                        anchorY: insets.meY,
                        pitchDegrees: !env.location.isTripActive || inRange ? 0 : AppConfig.engineMapPitchDegrees,
                        daylight: env.settings.mapAppearance.isDaylight(at: me, now: Date()),
                        houses: env.settings.mapHouses,
                        cameras: cameras,
                        alertCameraID: inRange ? env.location.nearestCamera?.id : nil,
                        cameraLimits: limits,
                        route: env.route.routeCoordinates,
                        onSelectCamera: onSelectCamera)

                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            SketchPalette.ground
        }
    }
}
#endif
