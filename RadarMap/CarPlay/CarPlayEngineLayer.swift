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
        // Камера поездки (DriveCamera) — общая с телефоном: масштаб, а не
        // охват, поэтому полоса одного размера на любом экране машины, а
        // большой экран показывает больше дороги. Стоя — сверху и крупно
        // (полосы, стрелки полос), на скорости — наклон и столько обзора,
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
        let keep = env.location.nearestCamera.map {
            DriveCamera.Keep.offset(from: me, to: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                                    bearing: env.location.displayCourse >= 0 ? env.location.displayCourse : nil)
        }
        let width = Double(size.width + safe.leading + safe.trailing)
        // Верх окна машины — бар с кнопками, низ — док HUD, справа — кнопки карты.
        let clear = compact ? DriveCamera.Clear(width: width)
            : DriveCamera.Clear(top: Double(safe.top) / max(1, height),
                                bottom: Double(safe.bottom + 12) / max(1, height),
                                width: width,
                                side: Double(max(safe.leading, safe.trailing)) + AppConfig.engineKeepSidePoints)
        let target = DriveCamera.target(
            speedKmh: env.location.speedKmh, maneuverDistance: maneuverDistance,
            pitchAllowed: env.thermal.mode == .full, keep: keep,
            viewHeight: height, latitude: me.latitude, clear: clear,
            carY: { compact ? AppConfig.carPlayDashboardMeY : Self.meY(size: size, safe: safe, share: $0) })
        let frame = model.cameraSmoother.step(toward: target, at: Date())
        let offlineFiles: OfflineFiles? = env.network.isOnline
            ? nil : env.offlineMaps.offlineFiles(at: me)
        return EngineMapView(
            coordinate: me,
            courseDegrees: env.location.displayCourse,
            // «+/−» сдвигают масштаб на ступень за нажатие поверх динамики.
            spanMeters: DriveCamera.span(zoom: frame.zoom + model.zoomBias, viewHeight: height,
                                         latitude: me.latitude),
            anchorY: compact ? AppConfig.carPlayDashboardMeY
                : Self.meY(size: size, safe: safe, share: frame.carShare),
            pitchDegrees: frame.pitchDegrees,
            daylight: model.isDaylight,
            houses: env.settings.mapHouses,
            cameras: [],
            cameraRevision: env.cameras.revision,
            limitRevision: env.speedLimits.indexRevision * 2 + (env.settings.speedLimitsEnabled ? 1 : 0),
            cameraProvider: { env.cameras.cameras(in: $0, limit: AppConfig.engineCameraViewportLimit) },
            // Лимит под значком камеры не рисуется: он один — у скорости
            // («в одном месте со скоростью хватит» — владелец, 12.10).
            limitProvider: nil,
            alertCameraID: env.location.isApproachingCamera ? env.location.nearestCamera?.id : nil,
            // Вариант B: цвет типа — только у камер на нашем пути.
            pathCameraIDs: CameraMarkerLook.pathIDs(
                route: env.route.camerasOnRoute.map { (id: $0.id, along: $0.distanceAlong) },
                progress: env.route.isActive ? env.route.progressAlong : nil,
                passedTolerance: AppConfig.routePassedToleranceMeters,
                nearest: env.location.nearestCamera?.id),
            familiarCameraIDs: env.location.familiarCameraIDs,
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
            trafficEdges: env.traffic.isShown ? env.traffic.snapshot?.edges ?? [] : [],
            trafficRevision: env.traffic.revision * 2 + (env.traffic.isShown ? 1 : 0),
            labelLanguage: env.settings.appLanguage.mapCode,
            cursorStyle: env.settings.cursorStyle,
            // Выбор маршрута: линия целиком, слева — место под карточку
            // вариантов, справа — под кнопки карты.
            overviewCommand: model.overviewCommand,
            overviewPadding: UIEdgeInsets(top: safe.top + 30, left: size.width * 0.45,
                                          bottom: safe.bottom + 30,
                                          right: model.mapButtonInsets.trailing + 30),
            panTotal: model.panTotal,
            onBrowse: { if model.isFollowing { model.isFollowing = false } })
    }

    /// Новая карта (вернулись из музыки, из схемы) стартует со слежения —
    /// модель обязана сказать то же: иначе после давней панорамы «+/−» шли
    /// в «свободную карту», которой нет, а «к себе» показывал «не следим».
    private func adopt() {
        if !model.isFollowing { model.isFollowing = true }
    }

    /// Подпись данных: пять секунд при показе карты, затем тает
    /// (MapAttribution). Нажать кнопку атрибуции в машине нельзя — поэтому
    /// текстом.
    private var attribution: some View {
        MapAttribution()
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
