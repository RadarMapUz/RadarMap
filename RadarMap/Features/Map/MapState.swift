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

    private var repository: CameraRepository?
    @ObservationIgnored private weak var speedLimits: SpeedLimitService?
    private var currentRegion: MKCoordinateRegion?
    private var loadedRegion: MKCoordinateRegion?   // область, для которой посчитаны точки (с буфером)

    /// Координата центра карты (для добавления камеры «здесь»).
    var mapCenter: CLLocationCoordinate2D? { currentRegion?.center }

    func configure(_ repository: CameraRepository, speedLimits: SpeedLimitService? = nil) {
        if self.repository == nil { self.repository = repository }
        if self.speedLimits == nil { self.speedLimits = speedLimits }
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
        Task {
            let layer = await CameraMapContent.layer(
                cameras: cameras, region: buffered, filter: filter,
                budget: AppConfig.maxVisibleAnnotations, limitIndex: limitIndex)
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
        let movedLat = abs(region.center.latitude - loaded.center.latitude)
        let movedLon = abs(region.center.longitude - loaded.center.longitude)
        return movedLat > loaded.span.latitudeDelta / 2 * AppConfig.recomputeThreshold
            || movedLon > loaded.span.longitudeDelta / 2 * AppConfig.recomputeThreshold
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

    /// Центрировать карту на пользователе и повернуть по курсу движения.
    /// `pitched` — 3D-вид навигатора: камера наклонена, смотрим вперёд по дороге.
    /// Троттлинг: пропускаем мелкие сдвиги/повороты, чтобы карта не дёргалась.
    func follow(coordinate: CLLocationCoordinate2D?, course: CLLocationDirection, pitched: Bool = false) {
        guard let coordinate else { return }
        if let last = lastFollowCoord {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            let courseDelta = (course >= 0 && lastFollowCourse >= 0)
                ? GeoMath.angleDifference(course, lastFollowCourse) : 999
            if moved < 12 && courseDelta < 8 { return }
        }
        lastFollowCoord = coordinate
        lastFollowCourse = course
        // В 3D центрируем точку впереди машины — сам ты в нижней трети экрана, как в навигаторе.
        let center = (pitched && course >= 0)
            ? GeoMath.destination(from: coordinate, bearing: course, distanceMeters: 160)
            : coordinate
        withAnimation(.easeOut(duration: 0.4)) {
            position = .camera(MapCamera(
                centerCoordinate: center,
                distance: pitched ? 700 : 900,
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
