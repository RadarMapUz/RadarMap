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
    var visibleCameras: [Camera] = []
    var clusters: [CameraCluster] = []
    /// Лимит дороги у видимых камер (id → км/ч): посчитан вместе со слоем вне
    /// main — маркеры берут его отсюда, а не из спатиал-индекса на каждый кадр.
    var visibleLimits: [Int: Int] = [:]
    var selectedCamera: Camera?          // открытый попап детали
    var highlightedID: Int?              // подсвеченный маркер на карте
    var showNearbySheet = false
    var showSearch = false
    var showSettings = false
    var showStats = false
    var isAddingCamera = false
    /// Точка долгого тапа: маркер + бар действий «Маршрут сюда / Радар / Своя камера».
    var pressedPoint: MapPoint?
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
    enum Orientation: Equatable {
        /// Карту тянут рукой — она никуда не едет сама.
        case free
        /// Центр на себе, север вверху.
        case following
        /// Центр на себе и поворот: по курсу в поездке, по компасу телефона стоя.
        case heading
    }

    private(set) var orientation: Orientation = .following

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
    private var currentRegion: MKCoordinateRegion?
    private var loadedRegion: MKCoordinateRegion?   // область, для которой посчитаны точки (с буфером)

    /// Координата центра карты (для добавления камеры «здесь»).
    var mapCenter: CLLocationCoordinate2D? { currentRegion?.center }

    var performance: PerformanceMode { thermal?.mode ?? .full }

    func configure(_ repository: CameraRepository, speedLimits: SpeedLimitService? = nil,
                   thermal: ThermalService? = nil) {
        if self.repository == nil { self.repository = repository }
        if self.speedLimits == nil { self.speedLimits = speedLimits }
        if self.thermal == nil { self.thermal = thermal }
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
        withAnimation(.easeOut(duration: 0.6)) {
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

    // MARK: - Подгрузка аннотаций

    /// Вызывается при остановке движения карты. Буфер + проверка покрытия дают «умный» плавный зум:
    /// мелкие сдвиги/приближения внутри уже загруженной области не вызывают пересчёт.
    /// На широких зумах вместо отдельных точек — кластеры с количеством.
    /// Средний зум: камеры рисуются точками, полный пин — у ближайшей/выбранной.
    private(set) var isDotZoom = false

    @ObservationIgnored private var layerGeneration = 0
    /// Масштаб, для которого построен текущий слой: решение «точки или кластеры»
    /// зависит от области, поэтому при заметной смене зума слой надо пересобрать.
    @ObservationIgnored private var loadedSpan: CLLocationDegrees = 0

    func updateVisible(for region: MKCoordinateRegion) {
        currentRegion = region
        let dotZoom = region.span.latitudeDelta > AppConfig.dotModeSpanDegrees
        if dotZoom != isDotZoom { isDotZoom = dotZoom }
        // Карту тянут рукой — важность считаем от центра экрана.
        if orientation == .free { updateFocus(region.center) }
        // База декодируется асинхронно: пока камер нет, регион не кэшируем —
        // иначе пустой результат «прилипнет» и карта останется без точек.
        guard let repository, !repository.cameras.isEmpty else { return }
        guard needsRecompute(for: region) else { return }

        let buffered = region.scaled(by: AppConfig.annotationBufferFactor)
        layerGeneration &+= 1
        let generation = layerGeneration
        let cameras = repository.cameras
        let filter = self.filter
        let span = region.span.latitudeDelta
        let limitIndex = speedLimits?.limitIndex
        // Бюджет маркеров зависит от того, не режет ли iOS процессор из-за
        // перегрева. Камера при этом не пропадает: всё, что не поместилось в
        // бюджет, CameraMapContent отдаёт кластерами с числом.
        let budget = performance.annotationBudget
        Task {
            let layer = await CameraMapContent.layer(
                cameras: cameras, region: buffered, filter: filter,
                budget: budget, limitIndex: limitIndex)
            // Пока считали, карту могли увезти дальше — этот ответ уже не про то,
            // что на экране. Область «загруженной» при этом НЕ помечаем: иначе
            // после быстрой прокрутки туда-сюда кэш говорил бы «тут всё есть»,
            // а слой для неё так и не применился — камеры просто не появлялись.
            guard generation == layerGeneration else { return }
            loadedRegion = buffered
            loadedSpan = span
            apply(layer)
        }
    }

    /// Пересчитывать ли слой: выход за буфер, заметная смена масштаба или
    /// предзагрузка по `recomputeThreshold` (центр уполз далеко внутри буфера —
    /// палец тащит карту в одну сторону, готовим следующую порцию заранее).
    private func needsRecompute(for region: MKCoordinateRegion) -> Bool {
        guard let loaded = loadedRegion, loadedSpan > 0 else { return true }
        if !loaded.contains(region) { return true }
        // Зум внутрь: набор строился для широкой области и мог быть
        // кластеризован — без пересчёта кластеры так и остались бы на месте
        // отдельных камер.
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

    /// Применить готовый слой. Анимируем только небольшие наборы: на сотнях
    /// аннотаций анимированная перестройка представлений сама по себе — рывок.
    private func apply(_ layer: CameraMapContent.Layer) {
        visibleLimits = layer.limits
        let animates = layer.cameras.count + layer.clusters.count <= 80
        if animates {
            withAnimation(.easeInOut(duration: 0.25)) {
                visibleCameras = layer.cameras
                clusters = layer.clusters
            }
        } else {
            visibleCameras = layer.cameras
            clusters = layer.clusters
        }
    }

    func zoomInto(_ cluster: CameraCluster) {
        let span = currentRegion?.span ?? MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 12)
        let region = MKCoordinateRegion(
            center: cluster.coordinate,
            span: MKCoordinateSpan(
                latitudeDelta: max(0.05, span.latitudeDelta / 4),
                longitudeDelta: max(0.05, span.longitudeDelta / 4)
            )
        )
        withAnimation(.easeInOut(duration: 0.4)) {
            position = .region(region)
        }
        updateVisible(for: region)
    }

    // MARK: - Действия

    func select(_ camera: Camera) {
        highlightedID = camera.id
        selectedCamera = camera
    }

    func focus(on camera: Camera) {
        highlightedID = camera.id
        withAnimation(.easeInOut(duration: 0.4)) {
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

    /// Тап по контролу ориентации: свободна → следование → поворот → следование.
    /// Вернуть «свободу» тапом нельзя — она наступает сама, когда карту тянут
    /// рукой; кнопка, отменяющая слежение, водителю не нужна.
    func cycleOrientation(coordinate: CLLocationCoordinate2D?,
                          course: CLLocationDirection, inTrip: Bool) {
        let next: Orientation = orientation == .following ? .heading : .following
        apply(orientation: next, coordinate: coordinate, course: course, inTrip: inTrip)
    }

    func apply(orientation next: Orientation, coordinate: CLLocationCoordinate2D?,
               course: CLLocationDirection, inTrip: Bool) {
        orientation = next
        switch next {
        case .free:
            followsDeviceHeading = false
        case .following:
            followsDeviceHeading = false
            setMapHeading(0)   // .userLocation ставит карту на север
            withAnimation(.easeInOut(duration: 0.35)) {
                position = .userLocation(fallback: .region(AppConfig.uzbekistanRegion))
            }
        case .heading:
            if inTrip {
                // В движении крутим по КУРСУ: компас телефона в держателе врёт
                // (магнитное поле машины), да и смотрит водитель вперёд, а не
                // туда, куда лежит телефон.
                followsDeviceHeading = false
                follow(coordinate: coordinate, course: course, pitched: true, force: true)
            } else {
                followsDeviceHeading = true
                setMapHeading(nil)   // карту крутит компас телефона — угла мы не знаем
                withAnimation(.easeInOut(duration: 0.35)) {
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
        withAnimation(force ? .easeOut(duration: duration) : .linear(duration: duration)) {
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
        withAnimation(.easeInOut(duration: 0.4)) {
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
        withAnimation(.easeInOut(duration: 0.3)) {
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
