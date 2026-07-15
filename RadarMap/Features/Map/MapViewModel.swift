//
//  MapViewModel.swift
//  RadarMap
//
//  Логика карты: умная подгрузка аннотаций (буфер), выбор, зум, центрирование.
//

import SwiftUI
import MapKit
import Observation
import CoreLocation

/// Кластер камер на широком зуме: центроид + количество.
struct CameraCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let count: Int
}

@MainActor
@Observable
final class MapViewModel {
    var visibleCameras: [Camera] = []
    var clusters: [CameraCluster] = []
    var selectedCamera: Camera?          // открытый попап детали
    var highlightedID: Int?              // подсвеченный маркер на карте
    var showNearbySheet = false
    var showSearch = false
    var showSettings = false
    var showStats = false
    var isAddingCamera = false
    var filter: CameraFilter = .all
    var position: MapCameraPosition = .userLocation(fallback: .region(AppConfig.uzbekistanRegion))

    private var repository: CameraRepository?
    private var currentRegion: MKCoordinateRegion?
    private var loadedRegion: MKCoordinateRegion?   // область, для которой посчитаны точки (с буфером)

    /// Координата центра карты (для добавления камеры «здесь»).
    var mapCenter: CLLocationCoordinate2D? { currentRegion?.center }

    func configure(_ repository: CameraRepository) {
        if self.repository == nil { self.repository = repository }
    }

    /// Первый GPS-фикс после запуска: показываем окрестности (~2.5 км), а не всю страну —
    /// на экране только ближайшие камеры, старт мгновенный и плавный на любом железе.
    @ObservationIgnored private var didInitialSnap = false
    func snapToUserOnce(_ coordinate: CLLocationCoordinate2D) {
        guard !didInitialSnap else { return }
        didInitialSnap = true
        withAnimation(.easeOut(duration: 0.6)) {
            position = .region(MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 2500,
                longitudinalMeters: 2500
            ))
        }
    }

    /// Принудительно перезагрузить видимые камеры (после добавления/скрытия/смены фильтра).
    func invalidateVisible() {
        loadedRegion = nil
        if let region = currentRegion { updateVisible(for: region) }
    }

    // MARK: - Подгрузка аннотаций

    /// Вызывается при остановке движения карты. Буфер + проверка покрытия дают «умный» плавный зум:
    /// мелкие сдвиги/приближения внутри уже загруженной области не вызывают пересчёт.
    /// На широких зумах вместо отдельных точек — кластеры с количеством.
    func updateVisible(for region: MKCoordinateRegion) {
        currentRegion = region
        guard let repository else { return }

        if region.span.latitudeDelta > AppConfig.maxVisibleSpanDegrees {
            loadedRegion = nil
            buildClusters(for: region.scaled(by: 1.3), from: repository)
            return
        }
        if !clusters.isEmpty { clusters = [] }

        // Всё ещё внутри загруженного буфера → точки уже отрисованы, пересчёт не нужен.
        if let loaded = loadedRegion, loaded.contains(region) { return }

        let buffered = region.scaled(by: AppConfig.annotationBufferFactor)
        let found = repository.cameras(in: buffered, limit: AppConfig.maxVisibleAnnotations)
            .filter { filter.matches($0) }
        withAnimation(.easeInOut(duration: 0.25)) {
            visibleCameras = found
        }
        loadedRegion = buffered
    }

    /// Сетка span/N × span/N; ячейки с одной камерой рисуются как обычный маркер.
    private func buildClusters(for area: MKCoordinateRegion, from repository: CameraRepository) {
        let cellLat = area.span.latitudeDelta / AppConfig.clusterGridDivisions
        let cellLon = area.span.longitudeDelta / AppConfig.clusterGridDivisions
        let latMin = area.center.latitude - area.span.latitudeDelta / 2
        let latMax = area.center.latitude + area.span.latitudeDelta / 2
        let lonMin = area.center.longitude - area.span.longitudeDelta / 2
        let lonMax = area.center.longitude + area.span.longitudeDelta / 2

        struct Bucket { var sumLat = 0.0; var sumLon = 0.0; var count = 0; var single: Camera? }
        var buckets: [String: Bucket] = [:]

        for camera in repository.cameras where filter.matches(camera) {
            guard camera.lat >= latMin, camera.lat <= latMax,
                  camera.lon >= lonMin, camera.lon <= lonMax else { continue }
            let key = "\(Int((camera.lat - latMin) / cellLat))_\(Int((camera.lon - lonMin) / cellLon))"
            var bucket = buckets[key] ?? Bucket()
            bucket.sumLat += camera.lat
            bucket.sumLon += camera.lon
            bucket.count += 1
            bucket.single = bucket.count == 1 ? camera : nil
            buckets[key] = bucket
        }

        var newClusters: [CameraCluster] = []
        var singles: [Camera] = []
        for (key, bucket) in buckets {
            if let single = bucket.single {
                singles.append(single)
            } else {
                newClusters.append(CameraCluster(
                    id: key,
                    coordinate: CLLocationCoordinate2D(
                        latitude: bucket.sumLat / Double(bucket.count),
                        longitude: bucket.sumLon / Double(bucket.count)
                    ),
                    count: bucket.count
                ))
            }
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            clusters = newClusters
            visibleCameras = Array(singles.prefix(60))
        }
    }

    func zoomInto(_ cluster: CameraCluster) {
        let span = currentRegion?.span ?? MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 12)
        withAnimation(.easeInOut(duration: 0.4)) {
            position = .region(MKCoordinateRegion(
                center: cluster.coordinate,
                span: MKCoordinateSpan(
                    latitudeDelta: max(0.05, span.latitudeDelta / 4),
                    longitudeDelta: max(0.05, span.longitudeDelta / 4)
                )
            ))
        }
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
    }

    func move(to coordinate: CLLocationCoordinate2D) {
        withAnimation(.easeInOut(duration: 0.4)) {
            position = .region(MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 4000,
                longitudinalMeters: 4000
            ))
        }
    }

    func zoom(_ factor: Double) {
        guard let region = currentRegion else { return }
        let span = MKCoordinateSpan(
            latitudeDelta: min(80, max(0.002, region.span.latitudeDelta * factor)),
            longitudeDelta: min(80, max(0.002, region.span.longitudeDelta * factor))
        )
        withAnimation(.easeInOut(duration: 0.3)) {
            position = .region(MKCoordinateRegion(center: region.center, span: span))
        }
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
