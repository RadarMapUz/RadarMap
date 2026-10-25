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
import CoreLocation
import SwiftUI

struct CarPlayEngineLayer: View {
    @Environment(AppEnvironment.self) private var env
    let model: CarPlayMapModel
    /// Где стоит карта: экран машины, плитка главного экрана или приборка
    /// (CarPlaySurface — чем они различаются).
    var surface: CarPlaySurface = .car

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

    /// Подпись — у камеры ДЛЯ ПОКАЗА (displayNearestCamera, удержание на
    /// пороге скорости — не мигает в пробке) и только когда это та же камера,
    /// о которой тревога: иначе цифра встала бы у боковой камеры.
    /// Стоит подпись там же, где нарисован значок: на линии маршрута, если
    /// камера на пути (27.B, CameraOnLine), иначе на её координате.
    private func cameraLabel(_ cue: CarPlayCameraCue.Cue, line: CameraOnLine.Display) -> CarPlayCameraCue.Label? {
        guard cue.distanceLabel, let camera = env.location.displayNearestCamera,
              camera.id == cue.mapAlertID,
              let distance = env.location.displayDistanceToNearest else { return nil }
        let at = line.coordinate(of: camera)
        return CarPlayCameraCue.Label(id: camera.id, latitude: at.latitude, longitude: at.longitude,
                                      text: Formatting.distance(distance))
    }

    private func map(me: CLLocationCoordinate2D, size: CGSize, safe: EdgeInsets) -> some View {
        let maneuverDistance = env.route.nextStep.map { _ in env.route.nextStepDistance }
        // Камера поездки (DriveCamera) — общая с телефоном: масштаб, а не
        // охват, поэтому полоса одного размера на любом экране машины, а
        // большой экран показывает больше дороги. Стоя — крупно и с лёгким
        // наклоном (полосы, стрелки полос; 27.L), на скорости — наклон и столько обзора,
        // сколько нужно секунд пути, у развилки — вид развилки, и она в кадре.
        // Всегда «в движении»: машина подключена — значит едем (плитка панели
        // показывала город целиком, а значки камер рисуются с z14.5 — «камер
        // нет», владелец, 12.10). На горячем телефоне — плоско: наклон тянет
        // к горизонту втрое больше тайлов, а картинка в машину рисуется на
        // телефоне.
        let height = Double(size.height + safe.top + safe.bottom)
        // Ближайшая камера в 500 м — в кадре всегда и в любую сторону, и на
        // плитке, и на карте машины: стоя карта видела 60 м, а камера стояла
        // в 128 («радары не показывает», carplay12; «куда пропал радар?»,
        // 12.10). Без курса карта держит прежний поворот, которого мы не
        // знаем, — тогда камера обязана влезть в любую сторону.
        let bearing = model.mapDirection ?? (env.location.displayCourse >= 0 ? env.location.displayCourse : nil)
        // Своя камера («без голоса») — не цель: водитель её знает, и ради неё
        // кадр уходил в район (снимок 63, 21.10).
        let keep = env.location.displayNearestCamera.flatMap {
            DriveCamera.keep(camera: $0.id, at: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                             familiar: env.location.familiarCameraIDs, from: me, bearing: bearing)
        }
        let width = Double(size.width + safe.leading + safe.trailing)
        // Верх окна машины — бар с кнопками, низ — док HUD, справа — кнопки
        // карты. Док (скорость, камера) — сто точек над низом окна, а кнопки
        // карты лежат внутри безопасной зоны: до 10.7 «в кадре» считалось
        // по 12 точкам снизу и без кнопок, и камера впереди вставала ровно под
        // капсулу «до камеры».
        // Приборка: края окна кластера закрывают стрелки приборов машины —
        // это его safe area; камера впереди держится внутри неё.
        let clear = surface == .dashboard ? DriveCamera.Clear(width: width)
            : surface == .cluster
            ? DriveCamera.Clear(top: Double(safe.top) / max(1, height),
                                bottom: Double(safe.bottom) / max(1, height),
                                width: width,
                                side: Double(max(safe.leading, safe.trailing)) + AppConfig.engineKeepSidePoints)
            : DriveCamera.Clear(top: Double(safe.top) / max(1, height),
                                bottom: Double(safe.bottom + 12 + AppConfig.carPlayDockHeight) / max(1, height),
                                width: width,
                                side: Double(max(safe.leading, safe.trailing, model.mapButtonInsets.trailing))
                                    + AppConfig.engineKeepSidePoints)
        // Вид на остановке (29.D): на светофоре в машине развилка в 200 м
        // была за краем экрана (105 м обзора стоя). Машина подключена —
        // значит едем: вид работает и без начатой поездки.
        let stop = StopViewInput.read(&model.stopView, env: env, maneuverDistance: maneuverDistance,
                                      active: true)
        // Что показывать сейчас (MapDetailPolicy, 29.H): на ходу — дорога,
        // маршрут, камеры и заправки по пути; стоя — окрестность; у цели —
        // номера домов, ореол цели, парковки; плитка и приборка — маршрут и
        // камеры. «Стоим» — тот же гистерезис, что у кадра остановки
        // (StopView): окрестность и кадр меняются одним моментом. Приборка —
        // «на ходу» всегда.
        let detail = MapDetailInput.read(&model.detailArriving, env: env, surface: MapDetailPolicy.Surface(surface),
                                         tripActive: true,
                                         standing: !surface.alwaysDeclutter && stop.state.standing,
                                         night: !model.isDaylight)
        // У цели кадр держит и её, и ближайшие парковки — вместе с камерой.
        let arrivalKeep = detail.keepPoints.map { DriveCamera.Keep.offset(from: me, to: $0, bearing: bearing) }
        // Профиль экрана машины: впереди секунды пути, а не 100 м разметки
        // (аудит 18.10, «при езде нормального вида нет»).
        let target = DriveCamera.target(
            speedKmh: env.location.speedKmh, maneuverDistance: maneuverDistance,
            pitchAllowed: surface.pitchAllowed(performance: env.thermal.mode), screen: .car, keep: keep,
            stop: stop.state, jamEnd: stop.jamEnd,
            alsoKeep: arrivalKeep,
            viewHeight: height, latitude: me.latitude, clear: clear,
            carY: { surface.fixedMeY ?? Self.meY(size: size, safe: safe, share: $0) })
        let frame = model.cameraSmoother.step(toward: target, at: Date())
        #if DEBUG
        DriveFrameLog.note(surface.healthTag, stop: stop.state, maneuver: maneuverDistance, keep: keep,
                           also: arrivalKeep.count, target: target, frame: frame, bias: model.zoomBias)
        #endif
        let cue = CarPlayCameraCue.current(env.location)
        let cameraLine = env.cameraOnLine
        let offlineFiles: OfflineFiles? = env.network.isMapOnline
            ? nil : env.offlineMaps.offlineFiles(at: me)
        return EngineMapView(
            coordinate: me,
            courseDegrees: env.location.displayCourse,
            // «+/−» сдвигают масштаб на ступень за нажатие поверх динамики.
            spanMeters: DriveCamera.span(zoom: frame.zoom + model.zoomBias, viewHeight: height,
                                         latitude: me.latitude),
            anchorY: surface.fixedMeY ?? Self.meY(size: size, safe: safe, share: frame.carShare),
            pitchDegrees: frame.pitchDegrees,
            daylight: model.isDaylight,
            houses: surface.houses(setting: env.settings.mapHouses),
            cameras: [],
            cameraRevision: env.cameras.revision,
            limitRevision: env.speedLimits.indexRevision * 2 + (env.settings.speedLimitsEnabled ? 1 : 0),
            cameraProvider: { env.cameras.cameras(in: $0, limit: $1) },
            // Лимит под значком камеры не рисуется: он один — у скорости
            // («в одном месте со скоростью хватит» — владелец, 12.10).
            limitProvider: nil,
            // Тревожный облик и подпись «400 м» — по CarPlayCameraCue: своя
            // камера остаётся значком с галочкой, без тревоги и цифры.
            alertCameraID: cue.mapAlertID,
            // Вариант B: цвет типа — только у камер на нашем пути; они же —
            // на линии маршрута, и подпись «400 м» там же (27.B).
            pathCameraIDs: cameraLine.pathIDs,
            cameraPoints: cameraLine.points,
            cameraZone: env.cameraZone(line: cameraLine),
            familiarCameraIDs: env.location.familiarCameraIDs,
            cameraLabel: cameraLabel(cue, line: cameraLine),
            route: env.route.routeCoordinates,
            routeObject: env.route.polyline,
            routeProgress: env.route.progressAlong,
            maneuverAlong: env.route.nextStep?.kind?.isDrawable == true ? env.route.nextStep?.distanceAlong : nil,
            laneFocus: env.route.laneFocusStep,
            // Стрелка манёвра на линии (29.G) — и в машине; выноски полос нет:
            // ряд полос там в карточке манёвра системы (laneRow).
            maneuverKind: env.route.nextStep?.kind,
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
            // Приборка — малая частота кадров всегда (CarPlaySurface.lowFrameRate):
            // тот же режим, что под полноэкранной тревогой.
            covered: surface.lowFrameRate,
            cruise: env.location.isCruising,
            detail: detail.decision,
            detailMarks: detail.marks,
            destinationApproach: detail.approach,
            // Плитка и приборка — только смотреть: случайный жест снимал
            // слежение, а вернуть его там нечем.
            interactive: surface.interactive,
            healthTag: surface.healthTag,
            trafficEdges: env.traffic.isShown ? env.traffic.snapshot?.edges ?? [] : [],
            trafficRevision: env.traffic.revision * 2 + (env.traffic.isShown ? 1 : 0),
            trafficSnapshot: env.traffic.isShown ? env.traffic.snapshot : nil,
            labelLanguage: env.settings.appLanguage.mapCode,
            cursorStyle: env.settings.cursorStyle,
            // Компас вокруг машины и знак смены лимита (29.B) — на карте
            // машины; плитка и приборка малы, там они закрыли бы дорогу.
            compass: surface == .car,
            limitAhead: surface == .car ? env.speedLimits.limitAheadCue : nil,
            // Выбор маршрута: линия целиком, слева — место под карточку
            // вариантов, справа — под кнопки карты.
            overviewCommand: model.overviewCommand,
            // Сверху, снизу и справа — с запасом на полподписи «24 мин»
            // варианта (27.D): подпись встаёт у края кадра и срезалась; снизу
            // ещё и док скорости.
            overviewPadding: UIEdgeInsets(top: safe.top + 40, left: size.width * 0.45,
                                          bottom: safe.bottom + 40 + AppConfig.carPlayDockHeight,
                                          right: model.mapButtonInsets.trailing + 60),
            // Выбор маршрута в машине (CPTripPreview): другие варианты —
            // бледной линией под выбранным, с временем, как на телефоне (27.D).
            // Касаний в окне машины нет — выбирает список шаблона.
            variants: model.isPreviewing && env.route.variants.count > 1 ? env.route.variants.map {
                RouteVariantLine(id: $0.id, polyline: $0.polyline, eta: $0.etaText)
            } : [],
            selectedVariantID: model.isPreviewing ? env.route.selectedID : nil,
            panTotal: model.panTotal,
            // Флаг цели (с 29.H и в машине): у цели — с ореолом и пунктиром.
            destination: detail.destination,
            // Перекрытия и ремонт (12б.5) — в машине тоже: о ремонте говорит
            // голос, и значок должен стоять там, где о нём сказали.
            roadEvents: env.mobile.roadEvents,
            onHeading: { model.mapDirection = $0 },
            onBrowse: { model.mapStartedBrowsing() },
            // Значок и камера — по оценке «где машина сейчас» (MarkerPredictor).
            markerMotion: env.location.markerMotion,
            // Плашка улицы и крупные подписи (29.F) — на карте машины;
            // плитка и приборка малы, плашка закрыла бы им дорогу.
            onStreetName: surface == .car ? { model.streetName = $0 } : nil,
            largeLabels: surface == .car)
    }

    /// Новая карта (вернулись из музыки, из схемы) стартует со слежения —
    /// модель обязана сказать то же: иначе после давней панорамы «+/−» шли
    /// в «свободную карту», которой нет, а «к себе» показывал «не следим».
    private func adopt() {
        model.adoptFollowing()
    }

    /// Подпись данных: пять секунд при показе карты, затем тает
    /// (MapAttribution). Нажать кнопку атрибуции в машине нельзя — поэтому
    /// текстом.
    private var attribution: some View {
        MapAttribution(interactive: false)
            .padding(.trailing, 6)
            .padding(.bottom, 4)
    }

    /// Где «я» по высоте всего окна (0 — верх, 1 — низ). Свободное поле —
    /// между верхней safe area (бар CarPlay) и приборной панелью HUD; «я»
    /// стоит на AppConfig.carPlayMeShare его высоты. Окно — на всю высоту,
    /// поэтому доля считается от полной высоты с safe area.
    /// Машина по высоте экрана: доля `share` свободной полосы между верхней
    /// и нижней безопасной зоной. Резерва под док снизу больше нет — док
    /// справа, у кнопок карты (12.10), середину низа он не закрывает.
    static func meY(size: CGSize, safe: EdgeInsets, share: Double = AppConfig.carPlayMeShare) -> Double {
        let full = size.height + safe.top + safe.bottom
        guard full > 0 else { return AppConfig.mapMeY }
        let top = safe.top + 12
        let bottom = full - safe.bottom - 12
        guard bottom > top else { return AppConfig.mapMeY }
        return Double((top + (bottom - top) * share) / full)
    }
}
#endif
