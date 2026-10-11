//
//  MapState.swift
//  RadarMap
//
//  Логика карты: умная подгрузка аннотаций (буфер), выбор, зум, центрирование.
//

import SwiftUI
import MapKit
import Observation
import CoreLocation

@MainActor
@Observable
final class MapState {

    /// Снос — БЕЗ прыжка на актор, и это не стиль, а обход живого бага рантайма.
    ///
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor синтезирует isolated deinit
    /// каждому @MainActor-классу, даже когда своего deinit нет. Такой deinit
    /// уходит в swift_task_deinitOnExecutor, тот в синхронном кадре главного
    /// потока (текущей Task нет) заводит TaskLocal::StopLookupScope, а
    /// MarkerItem::create в рантайме iOS 26 берёт память у task-аллокатора
    /// БЕЗУСЛОВНО — при task == nullptr это статический слэб внутри
    /// libswift_Concurrency. Item::destroy потом зовёт free() по этому
    /// указателю: «pointer being freed was not allocated» → SIGABRT.
    ///
    /// Условия сходятся ровно там, где SwiftUI сносит вью с @State-моделью
    /// внутри GraphHost.runTransaction: там жива task-local привязка. В ветке
    /// main рантайма баг уже исправлен; до выхода такой iOS помогает одно —
    /// не синтезировать isolated deinit вовсе.
    nonisolated deinit {}
    var selectedCamera: Camera?          // открытый попап детали
    var highlightedID: Int?              // подсвеченный маркер на карте
    var showNearbySheet = false
    var showSearch = false
    var showSettings = false
    var showStats = false
    var isAddingCamera = false
    /// Точка долгого тапа: маркер + бар действий «Маршрут сюда / Радар / Своя камера».
    var pressedPoint: MapPoint?
    /// Команда движку «в точку»: счётчик и цель (крестик постановки камеры
    /// встаёт на точку долгого тапа).
    private(set) var centerCommand = 0
    private(set) var centerTarget: CLLocationCoordinate2D?

    func center(on coordinate: CLLocationCoordinate2D) {
        centerTarget = coordinate
        centerCommand &+= 1
    }
    var filter: CameraFilter = .all
    var position: MapCameraPosition = .userLocation(fallback: .region(AppConfig.uzbekistanRegion))
    /// Режим «по компасу устройства»: карта крутится сама за телефоном
    /// (второй тап по кнопке локации, как в Apple Maps).
    var followsDeviceHeading = false

    /// Как карта соотносится с миром.
    ///
    /// Раньше этим управляли ТРИ кнопки: системный компас (висел всегда, даже
    /// когда карта строго на север и он не значит ничего), «моё
    /// местоположение» и «по ходу движения». Все три — про одно, и Apple свела
    /// их в один контрол не от бедности.
    nonisolated enum Orientation: Equatable {
        /// Карту тянут рукой — она никуда не едет сама.
        case free
        /// Центр на себе, север вверху.
        case following
        /// Центр на себе и поворот: по курсу в поездке, по компасу телефона стоя.
        case heading
    }

    private(set) var orientation: Orientation = .following

    // MARK: - Вид: 3D и масштаб кнопками (общие для карты Apple и движка)

    /// 3D-вид из настроек (кнопка «3D»): ставит MapScreen, читают обе карты.
    var prefers3D = true

    /// Масштаб кнопками «+ / −» поверх автозума: шаг — вдвое, плюс — ближе.
    /// Автозум по скорости остаётся: кнопка сдвигает его, а не выключает.
    private(set) var zoomBias: Double = 0
    /// Счётчик нажатий и шаг последнего — движку, когда карта свободна
    /// (тогда приближает сам вид, а не охват слежения).
    private(set) var zoomCommand = 0
    private(set) var lastZoomDelta: Double = 0

    func zoomStep(_ delta: Double) {
        zoomBias = min(3, max(-3, zoomBias + delta))
        lastZoomDelta = delta
        zoomCommand += 1
        // Карта Apple в слежении по курсу берёт масштаб из followDistance
        // (следующий фикс); в остальных режимах — приближаем регион сразу.
        if orientation != .heading { zoom(delta > 0 ? 0.5 : 2) }
    }

    /// Карту утащили пальцем (движок сообщает о жесте) — она больше не едет
    /// за машиной; кнопка «моё местоположение» вернёт.
    func releaseToFree() {
        guard orientation != .free else { return }
        orientation = .free
        followsDeviceHeading = false
    }

    /// Карта повёрнута (не север вверху) — компасу. Отдельно от mapHeading и
    /// пишется только на смене: тот меняется на каждом изгибе дороги, и
    /// чтение его телом экрана пересобирало бы весь главный экран.
    private(set) var isRotated = false
    /// Поворот карты для стрелки компаса, шаг 10° — читает только компас.
    private(set) var displayedDirection: Double = 0

    func noteMapDirection(_ degrees: Double) {
        let rotated = abs(remainder(degrees, 360)) > 2
        if rotated != isRotated { isRotated = rotated }
        let stepped = (degrees / 10).rounded() * 10
        if stepped != displayedDirection { displayedDirection = stepped }
    }

    /// Тап по компасу: север вверх, слежение за машиной.
    func showNorth(coordinate: CLLocationCoordinate2D?, inTrip: Bool) {
        orientationChosenByHand = true
        apply(orientation: .following, coordinate: coordinate, course: -1, inTrip: inTrip)
    }

    /// Ориентацию выбрали пальцем, а не вывел режим.
    ///
    /// Без этого флага выбор человека терялся ДВАЖДЫ за поездку: старт ставил
    /// «по ходу движения», стоп возвращал на север — оба раза молча и поверх
    /// нажатой кнопки. Тот же случай, что был с подложкой карты, и лечится тем
    /// же правилом: выбранное человеком сильнее режима и держится до
    /// следующего выбора (plan_app_ui.md, У10).
    private(set) var orientationChosenByHand = false

    /// Что делать с ориентацией на старте и стопе поездки; `nil` — не трогать.
    ///
    /// Свобода (карту отодвинули рукой) выбором не считается намеренно: она
    /// наступает сама от протяжки, а поехавшая машина — новое положение дел, в
    /// котором брошенная карта бесполезна. Кнопку же нажимают осознанно.
    nonisolated static func orientationOnTripChange(active: Bool,
                                                    current: Orientation,
                                                    chosenByHand: Bool) -> Orientation? {
        if chosenByHand, current != .free { return nil }
        return active ? .heading : .following
    }

    /// Куда повёрнут «верх экрана» карты, градусы от севера; nil — неизвестно
    /// (карта крутится сама за компасом устройства).
    ///
    /// Нужен клину направления на маркере: контент Annotation в MapKit
    /// экранно-выровнен и с картой НЕ вращается, поэтому «поворот прямо из
    /// dir» верен только при севере вверху. В режиме «по ходу движения» ошибка
    /// равнялась курсу карты — клин врал сильнее всего ровно тогда, когда
    /// водитель на карту смотрит. Известный поворот компенсируем, неизвестный
    /// (compass-follow) — честно прячем клин: спрятать лучше, чем соврать.
    /// Квантование 5° — чтобы плавный доворот не перерисовывал маркеры зря.
    private(set) var mapHeading: Double? = 0

    func setMapHeading(_ heading: Double?) {
        let quantized = heading.map { ($0 / 5).rounded() * 5 }
        if mapHeading != quantized { mapHeading = quantized }
        // nil — карту крутит компас телефона: она повёрнута.
        noteMapDirection(quantized ?? 90)
    }

    /// Точка, от которой считается важность маркеров (CameraTier).
    ///
    /// Троттлится по `mapFocusStepMeters`: это не косметика — маркеры читают
    /// её в своём body, и запись на каждый GPS-тик перерисовывала бы всю карту
    /// раз в секунду. Ровно эта ошибка уже стоила нам лагов в Итогах.
    private(set) var focus: CLLocationCoordinate2D?

    /// Точка отсчёта — там, КУДА СМОТРИТ водитель, а не где он стоит.
    /// Пока карта следует за ним, это одно и то же; но стоит утащить её в
    /// соседний район — и приглушать те камеры за то, что они далеко от дома,
    /// было бы прямой ошибкой: человек пришёл смотреть именно на них.
    func updateFocus(_ coordinate: CLLocationCoordinate2D?, force: Bool = false) {
        guard let coordinate else { return }
        if !force, let focus,
           GeoMath.fastDistance(focus.latitude, focus.longitude,
                                coordinate.latitude, coordinate.longitude)
            < AppConfig.mapFocusStepMeters { return }
        focus = coordinate
    }

    private var repository: CameraRepository?
    @ObservationIgnored private weak var speedLimits: SpeedLimitService?
    /// Перегрев: под ним карта рисует меньше и пересчитывается реже. Оповещения
    /// о камерах это не трогает — за рулём голос важнее картинки.
    @ObservationIgnored private weak var thermal: ThermalService?
    /// Память о треногах. Не камеры: отдельный слой, отдельный тон, отдельная
    /// настройка — и рисуется только на близком зуме.
    @ObservationIgnored private weak var hotspots: HotspotService?
    /// Горячие точки в текущей области. Их десятки, а не тысячи, поэтому
    /// пространственный индекс тут был бы дороже самого перебора.
    private(set) var visibleHotspots: [TripodHotspots.Spot] = []
    private var currentRegion: MKCoordinateRegion?
    private var loadedRegion: MKCoordinateRegion?   // область, для которой посчитаны точки (с буфером)

    /// Координата центра карты (для добавления камеры «здесь»).
    var mapCenter: CLLocationCoordinate2D? { currentRegion?.center }

    var performance: PerformanceMode { thermal?.mode ?? .full }

    func configure(_ repository: CameraRepository, speedLimits: SpeedLimitService? = nil,
                   thermal: ThermalService? = nil, hotspots: HotspotService? = nil) {
        if self.repository == nil { self.repository = repository }
        if self.speedLimits == nil { self.speedLimits = speedLimits }
        if self.thermal == nil { self.thermal = thermal }
        if self.hotspots == nil { self.hotspots = hotspots }
    }

    /// Первый GPS-фикс после запуска: показываем окрестности (~2.5 км), а не всю страну —
    /// на экране только ближайшие камеры, старт мгновенный и плавный на любом железе.
    @ObservationIgnored private var didInitialSnap = false
    @ObservationIgnored private var initialSnapCoordinate: CLLocationCoordinate2D?
    @ObservationIgnored private var initialSnapAt: Date?

    func snapToUserOnce(_ coordinate: CLLocationCoordinate2D) {
        if didInitialSnap {
            // Первый фикс бывает кэшем со старого места (перелёт, долгая стоянка):
            // если в первую минуту пришла точка сильно дальше — переснимаемся.
            guard let snapped = initialSnapCoordinate, let at = initialSnapAt,
                  Date().timeIntervalSince(at) < 60,
                  GeoMath.fastDistance(snapped.latitude, snapped.longitude,
                                       coordinate.latitude, coordinate.longitude) > 10_000
            else { return }
        }
        didInitialSnap = true
        initialSnapCoordinate = coordinate
        initialSnapAt = Date()
        withMotion(.easeOut(duration: 0.6)) {
            position = .region(MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 2500,
                longitudinalMeters: 2500
            ))
        }
        refreshVisible(around: coordinate, widthMeters: 2500)
    }

    /// Подгрузить камеры вокруг точки, когда целевой регион известен лишь приблизительно
    /// (программные перемещения: onMapCameraChange после них срабатывает ненадёжно).
    /// MapKit вписывает ширину запрошенного региона, высота растягивается по аспекту
    /// портретного экрана — берём его с запасом, чтобы isDotZoom и буфер совпадали
    /// с тем, что карта покажет на самом деле.
    func refreshVisible(around coordinate: CLLocationCoordinate2D, widthMeters: Double) {
        updateVisible(for: MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: widthMeters * 2.2,
            longitudinalMeters: widthMeters
        ))
    }

    /// Принудительно перезагрузить видимые камеры (после добавления/скрытия/смены фильтра).
    /// Если карта ещё не отдала ни одного региона (onMapCameraChange не сработал —
    /// бывает после программных перемещений), считаем от заданной позиции или всей страны.
    func invalidateVisible() {
        loadedRegion = nil
        loadedSpan = 0
        if let region = currentRegion ?? position.region {
            updateVisible(for: region)
        } else {
            updateVisible(for: AppConfig.uzbekistanRegion)
        }
    }

    // MARK: - Видимая область

    /// Масштаб, для которого отфильтрованы зоны треног: при заметной смене
    /// зума фильтр по буферу надо повторить.
    @ObservationIgnored private var loadedSpan: CLLocationDegrees = 0

    /// Камеры на карте рисует движок из своего источника; здесь от области
    /// остались центр (фокус важности при осмотре) и зоны треног. Раньше на
    /// каждую остановку камеры карты здесь ещё строился слой аннотаций Apple
    /// (`CameraMapContent.layer` по всей базе вместе с лимитами), который
    /// после ухода подложки Apple никто не читал (аудит 11.10).
    func updateVisible(for region: MKCoordinateRegion) {
        currentRegion = region
        // Карту тянут рукой — важность считаем от центра экрана.
        if orientation == .free { updateFocus(region.center) }
        guard needsRecompute(for: region) else { return }
        let buffered = region.scaled(by: AppConfig.annotationBufferFactor)
        visibleHotspots = (hotspots?.spots ?? []).filter { buffered.contains($0.coordinate) }
        loadedRegion = buffered
        loadedSpan = region.span.latitudeDelta
    }

    /// Пересчитывать ли слой: выход за буфер, заметная смена масштаба или
    /// предзагрузка по `recomputeThreshold` (центр уполз далеко внутри буфера —
    /// палец тащит карту в одну сторону, готовим следующую порцию заранее).
    private func needsRecompute(for region: MKCoordinateRegion) -> Bool {
        guard let loaded = loadedRegion, loadedSpan > 0 else { return true }
        if !loaded.contains(region) { return true }
        let ratio = region.span.latitudeDelta / loadedSpan
        if ratio < 0.6 || ratio > 1.6 { return true }
        // В перегрев порог сдвига растягиваем: пересчёт слоя — самая дорогая
        // операция карты, и когда iOS уже режет процессор, делать её вдвое-
        // вчетверо реже полезнее, чем показать точку на полсекунды раньше.
        let threshold = min(1, AppConfig.recomputeThreshold * performance.recomputeFactor)
        let movedLat = abs(region.center.latitude - loaded.center.latitude)
        let movedLon = abs(region.center.longitude - loaded.center.longitude)
        return movedLat > loaded.span.latitudeDelta / 2 * threshold
            || movedLon > loaded.span.longitudeDelta / 2 * threshold
    }

    // MARK: - Действия

    func select(_ camera: Camera) {
        highlightedID = camera.id
        selectedCamera = camera
    }

    func focus(on camera: Camera) {
        highlightedID = camera.id
        withMotion(.easeInOut(duration: 0.4)) {
            position = .region(MKCoordinateRegion(
                center: camera.coordinate,
                latitudinalMeters: AppConfig.focusDistance,
                longitudinalMeters: AppConfig.focusDistance
            ))
        }
        refreshVisible(around: camera.coordinate, widthMeters: AppConfig.focusDistance)
    }

    // MARK: - Режим следования (карта «по ходу движения»)

    @ObservationIgnored private var lastFollowCoord: CLLocationCoordinate2D?
    @ObservationIgnored private var lastFollowCourse: CLLocationDirection = -1
    /// Когда пришёл прошлый тик следования: анимация камеры длится ровно до
    /// следующего ожидаемого фикса (TickPacing), а не красивую константу.
    @ObservationIgnored private var lastFollowAt: Date?
    /// Текущая высота камеры (автозум): меняем только полными ступенями,
    /// чтобы шум скорости не заставлял карту дышать.
    @ObservationIgnored private var followDistance: Double = 0

    /// Высота камеры по скорости: стоишь — ближе, летишь — шире, чтобы видеть
    /// дальше. Чистая функция, ступени по 100 м (см. followDistance).
    nonisolated static func cameraDistance(forSpeedKmh speed: Double,
                                           pitched: Bool) -> Double {
        guard pitched else { return 900 }
        let raw = min(max(600 + speed * 6, 600), 1300)
        return (raw / 100).rounded() * 100
    }

    /// Точка впереди машины, которую центрируем в 3D: на скорости смотрим
    /// дальше вперёд — решения принимаются раньше.
    nonisolated static func lookAheadMeters(forSpeedKmh speed: Double) -> Double {
        let raw = min(max(120 + speed * 1.2, 120), 280)
        return (raw / 20).rounded() * 20
    }

    /// Тап по контролу ориентации: свободна → слежение → поворот → следование.
    /// Вернуть «свободу» тапом нельзя — она наступает сама, когда карту тянут
    /// рукой; кнопка, отменяющая слежение, водителю не нужна.
    ///
    /// Из свободной карты тап — это «вернись к машине», а не выбор режима:
    /// карта встаёт в тот режим слежения, что был до жеста (в поездке — «по
    /// ходу»). Раньше «К машине» ставила север вверху и запоминала это как
    /// ручной выбор — и ни одна следующая поездка уже не поворачивала карту
    /// сама: стрелка ехала боком у края экрана (поездка 07.10.2026).
    func cycleOrientation(coordinate: CLLocationCoordinate2D?,
                          course: CLLocationDirection, inTrip: Bool) {
        if orientation == .free {
            apply(orientation: Self.recenterOrientation(lastTracking: lastTracking, inTrip: inTrip,
                                                        chosenByHand: orientationChosenByHand),
                  coordinate: coordinate, course: course, inTrip: inTrip)
            return
        }
        let next: Orientation = orientation == .following ? .heading : .following
        orientationChosenByHand = true   // дальше режим её не перебивает
        apply(orientation: next, coordinate: coordinate, course: course, inTrip: inTrip)
    }

    /// Последний режим слежения (не «свободно») — куда возвращает «К машине».
    private(set) var lastTracking: Orientation = .following

    /// Куда вернуть карту из свободного режима: выбранный рукой режим —
    /// его; иначе в поездке — «по ходу», вне поездки — прежний.
    nonisolated static func recenterOrientation(lastTracking: Orientation, inTrip: Bool,
                                                chosenByHand: Bool) -> Orientation {
        if chosenByHand, lastTracking != .free { return lastTracking }
        return inTrip ? .heading : (lastTracking == .free ? .following : lastTracking)
    }

    func apply(orientation next: Orientation, coordinate: CLLocationCoordinate2D?,
               course: CLLocationDirection, inTrip: Bool) {
        orientation = next
        if next != .free { lastTracking = next }
        switch next {
        case .free:
            followsDeviceHeading = false
        case .following:
            followsDeviceHeading = false
            setMapHeading(0)   // .userLocation ставит карту на север
            withMotion(.easeInOut(duration: 0.35)) {
                position = .userLocation(fallback: .region(AppConfig.uzbekistanRegion))
            }
        case .heading:
            if inTrip {
                // В движении крутим по КУРСУ: компас телефона в держателе врёт
                // (магнитное поле машины), да и смотрит водитель вперёд, а не
                // туда, куда лежит телефон.
                followsDeviceHeading = false
                follow(coordinate: coordinate, course: course, pitched: prefers3D, force: true)
            } else {
                followsDeviceHeading = true
                setMapHeading(nil)   // карту крутит компас телефона — угла мы не знаем
                withMotion(.easeInOut(duration: 0.35)) {
                    position = .userLocation(followsHeading: true,
                                             fallback: .region(AppConfig.uzbekistanRegion))
                }
            }
        }
        // Целевой регион известен только когда есть геопозиция — подгружаем сами.
        if let coordinate, next != .free {
            refreshVisible(around: coordinate, widthMeters: 3000)
        }
    }

    /// Карту потянули рукой — слежение снимается само.
    func releaseOrientation() {
        guard orientation != .free else { return }
        orientation = .free
        followsDeviceHeading = false
    }

    /// «Весь маршрут»: счётчик — движку (вписывает линию маршрута сам),
    /// карте Apple — регион сразу. Это обзор, а не слежение: карта
    /// отпускается, «моё местоположение» вернёт к машине.
    private(set) var overviewCommand = 0

    func showRouteOverview(rect: MKMapRect) {
        guard !rect.isNull else { return }
        releaseOrientation()
        overviewCommand += 1
        let padded = rect.insetBy(dx: -rect.width * 0.18, dy: -rect.height * 0.18)
        withMotion(.easeInOut(duration: 0.5)) {
            position = .rect(padded)
        }
        updateVisible(for: MKCoordinateRegion(padded))
    }

    /// Центрировать карту на пользователе и повернуть по курсу движения.
    /// `pitched` — 3D-вид навигатора: камера наклонена, смотрим вперёд по дороге.
    /// `force` — явный тап пользователя: без троттлинга и с быстрым откликом.
    ///
    /// Плавность здесь — РИТМ, а не константа: анимация длится до следующего
    /// ожидаемого фикса (TickPacing). С «красивыми» 0.4 с карта 0.4 с ехала и
    /// 1–2 с стояла — большая карта шагала ровно той же болезнью, что схема
    /// приборки до её лечения. Троттлинг оставлен только на истинной стоянке:
    /// пропуск тика при ритмичной анимации — это снова стоп-кадр.
    func follow(coordinate: CLLocationCoordinate2D?, course: CLLocationDirection,
                speedKmh: Double = 0, pitched: Bool = false, force: Bool = false) {
        guard let coordinate else { return }
        if let last = lastFollowCoord, !force {
            let moved = GeoMath.fastDistance(last.latitude, last.longitude,
                                             coordinate.latitude, coordinate.longitude)
            let courseDelta = (course >= 0 && lastFollowCourse >= 0)
                ? GeoMath.angleDifference(course, lastFollowCourse) : 999
            if moved < 3 && courseDelta < 3 { return }
        }
        lastFollowCoord = coordinate
        lastFollowCourse = course

        let now = Date()
        let duration = force ? 0.35
            : TickPacing.animationDuration(
                sincePreviousTick: lastFollowAt.map { now.timeIntervalSince($0) })
        lastFollowAt = now

        // Автозум: стоишь — ближе, летишь — шире. Ступень меняем только
        // целиком — шум скорости не должен заставлять карту дышать.
        let target = Self.cameraDistance(forSpeedKmh: speedKmh, pitched: pitched)
            * pow(2, -zoomBias)
        if followDistance == 0 || abs(target - followDistance) >= 100 {
            followDistance = target
        }

        // В 3D центрируем точку впереди машины — сам ты в нижней трети экрана,
        // как в навигаторе; на скорости смотрим дальше вперёд.
        let center = (pitched && course >= 0)
            ? GeoMath.destination(from: coordinate, bearing: course,
                                  distanceMeters: Self.lookAheadMeters(forSpeedKmh: speedKmh))
            : coordinate
        setMapHeading(course >= 0 ? course : 0)   // мы сами задаём поворот карты
        withMotion(force ? .easeOut(duration: duration) : .linear(duration: duration)) {
            position = .camera(MapCamera(
                centerCoordinate: center,
                distance: followDistance,
                heading: course >= 0 ? course : 0,
                pitch: pitched ? 55 : 0
            ))
        }
        // Анимации следования идут непрерывно, onMapCameraChange(.onEnd) не наступает —
        // камеры впереди подгружаем сами. Буфер делает вызов почти бесплатным.
        refreshVisible(around: center, widthMeters: 1200)
    }

    func move(to coordinate: CLLocationCoordinate2D) {
        withMotion(.easeInOut(duration: 0.4)) {
            position = .region(MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 4000,
                longitudinalMeters: 4000
            ))
        }
        refreshVisible(around: coordinate, widthMeters: 4000)
    }

    func zoom(_ factor: Double) {
        guard let region = currentRegion else { return }
        let span = MKCoordinateSpan(
            latitudeDelta: min(80, max(0.002, region.span.latitudeDelta * factor)),
            longitudeDelta: min(80, max(0.002, region.span.longitudeDelta * factor))
        )
        let zoomed = MKCoordinateRegion(center: region.center, span: span)
        withMotion(.easeInOut(duration: 0.3)) {
            position = .region(zoomed)
        }
        updateVisible(for: zoomed)
    }
}

// MARK: - Гео-утилиты

extension MKCoordinateRegion {
    /// Содержит ли регион `other` целиком.
    func contains(_ other: MKCoordinateRegion) -> Bool {
        let latMin = center.latitude  - span.latitudeDelta  / 2
        let latMax = center.latitude  + span.latitudeDelta  / 2
        let lonMin = center.longitude - span.longitudeDelta / 2
        let lonMax = center.longitude + span.longitudeDelta / 2
        let oLatMin = other.center.latitude  - other.span.latitudeDelta  / 2
        let oLatMax = other.center.latitude  + other.span.latitudeDelta  / 2
        let oLonMin = other.center.longitude - other.span.longitudeDelta / 2
        let oLonMax = other.center.longitude + other.span.longitudeDelta / 2
        return oLatMin >= latMin && oLatMax <= latMax && oLonMin >= lonMin && oLonMax <= lonMax
    }

    /// Попадает ли точка в рамку региона.
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        abs(coordinate.latitude  - center.latitude)  <= span.latitudeDelta  / 2 &&
        abs(coordinate.longitude - center.longitude) <= span.longitudeDelta / 2
    }

    func scaled(by factor: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: min(160, span.latitudeDelta * factor),
                longitudeDelta: min(160, span.longitudeDelta * factor)
            )
        )
    }
}
