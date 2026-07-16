//
//  CarPlayMapView.swift
//  RadarMap
//
//  Карта CarPlay: MKMapView (тёмная, без POI) с камерами-аннотациями и линией
//  маршрута. Камеры подгружаются под видимую область из общего репозитория,
//  иконки кэшируются по типу — движение карты ничего не аллоцирует заново.
//

import SwiftUI
import MapKit

struct CarPlayMapView: UIViewRepresentable {
    let model: CarPlayMapModel
    let repository: CameraStore
    let route: RouteService
    let location: LocationService

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.mapType = .mutedStandard
        map.pointOfInterestFilter = .excludingAll
        map.showsTraffic = false
        map.showsBuildings = false
        map.showsCompass = false
        map.showsUserLocation = true
        map.userTrackingMode = .follow
        map.register(CameraMarkerView.self,
                     forAnnotationViewWithReuseIdentifier: CameraMarkerView.reuseID)

        // Старт: вокруг себя, если позиция уже есть; иначе — Ташкент.
        let center = location.currentCoordinate
            ?? CLLocationCoordinate2D(latitude: 41.3111, longitude: 69.2797)
        map.setRegion(MKCoordinateRegion(center: center,
                                         latitudinalMeters: 2600, longitudinalMeters: 2600),
                      animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator

        // Кнопки шаблона: «к себе» и зум (счётчики — обрабатываем дельту).
        if model.recenterRequests != coordinator.recenterHandled {
            coordinator.recenterHandled = model.recenterRequests
            map.setUserTrackingMode(.follow, animated: true)
        }
        if model.zoomInRequests != coordinator.zoomInHandled {
            coordinator.zoomInHandled = model.zoomInRequests
            coordinator.zoom(map, factor: 0.5)
        }
        if model.zoomOutRequests != coordinator.zoomOutHandled {
            coordinator.zoomOutHandled = model.zoomOutRequests
            coordinator.zoom(map, factor: 2.0)
        }

        // Линия маршрута: наблюдаемое чтение — SwiftUI дёрнет update при смене.
        let polyline = route.polyline
        if polyline !== coordinator.routeOverlay {
            if let old = coordinator.routeOverlay { map.removeOverlay(old) }
            if let polyline { map.addOverlay(polyline, level: .aboveRoads) }
            coordinator.routeOverlay = polyline
        }

        // База камер декодируется асинхронно: первый запрос области мог уйти
        // в пустой репозиторий — перезагружаем маркеры, когда данные пришли.
        let cameraCount = repository.cameras.count
        if cameraCount != coordinator.cameraCountSeen {
            coordinator.cameraCountSeen = cameraCount
            coordinator.reloadCameras(on: map)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(repository: repository)
    }

    // MARK: - Координатор

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        private let repository: CameraStore
        var routeOverlay: MKPolyline?
        var recenterHandled = 0
        var zoomInHandled = 0
        var zoomOutHandled = 0
        var cameraCountSeen = -1
        /// Показанные камеры по id — обновление области не пересоздаёт аннотации.
        private var shown: [Int: CameraAnnotation] = [:]

        init(repository: CameraStore) {
            self.repository = repository
        }

        func zoom(_ map: MKMapView, factor: Double) {
            var region = map.region
            region.span.latitudeDelta = min(max(region.span.latitudeDelta * factor, 0.002), 4)
            region.span.longitudeDelta = min(max(region.span.longitudeDelta * factor, 0.002), 4)
            map.setRegion(region, animated: true)
        }

        nonisolated func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            MainActor.assumeIsolated { reloadCameras(on: mapView) }
        }

        func reloadCameras(on map: MKMapView) {
            // На обзорном зуме камеры не показываем — это уровень «вся страна».
            guard map.region.span.latitudeDelta < 0.6 else {
                if !shown.isEmpty {
                    map.removeAnnotations(Array(shown.values))
                    shown.removeAll()
                }
                return
            }
            let fresh = repository.cameras(in: map.region, limit: 120)
            let freshIDs = Set(fresh.map(\.id))

            let outdated = shown.filter { !freshIDs.contains($0.key) }
            if !outdated.isEmpty {
                map.removeAnnotations(Array(outdated.values))
                outdated.keys.forEach { shown.removeValue(forKey: $0) }
            }
            let added = fresh.filter { shown[$0.id] == nil }.map(CameraAnnotation.init)
            if !added.isEmpty {
                map.addAnnotations(added)
                added.forEach { shown[$0.camera.id] = $0 }
            }
        }

        nonisolated func mapView(_ mapView: MKMapView,
                                 viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard annotation is CameraAnnotation else { return nil }
            return mapView.dequeueReusableAnnotationView(withIdentifier: CameraMarkerView.reuseID,
                                                         for: annotation)
        }

        nonisolated func mapView(_ mapView: MKMapView,
                                 rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = UIColor(Theme.accent)
            renderer.lineWidth = 6
            renderer.lineCap = .round
            return renderer
        }
    }
}

// MARK: - Аннотация и маркер камеры

final class CameraAnnotation: NSObject, MKAnnotation {
    let camera: Camera
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: camera.lat, longitude: camera.lon)
    }

    init(camera: Camera) {
        self.camera = camera
    }
}

/// Круглый маркер с глифом типа камеры — иконки кэшируются по типу.
final class CameraMarkerView: MKAnnotationView {
    static let reuseID = "camera"
    private static var cache: [String: UIImage] = [:]

    override var annotation: (any MKAnnotation)? {
        didSet {
            guard let camera = (annotation as? CameraAnnotation)?.camera else { return }
            image = Self.marker(for: camera.kind)
            displayPriority = .defaultHigh
            collisionMode = .circle
        }
    }

    private static func marker(for kind: CameraType) -> UIImage {
        let key = String(describing: kind)
        if let cached = cache[key] { return cached }
        let size = CGSize(width: 26, height: 26)
        let rendered = UIGraphicsImageRenderer(size: size).image { context in
            let rect = CGRect(origin: .zero, size: size)
            UIColor(kind.tint).setFill()
            UIBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            UIColor.white.withAlphaComponent(0.9).setStroke()
            let ring = UIBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1.5
            ring.stroke()
            let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            if let glyph = UIImage(systemName: kind.symbolName, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let glyphSize = glyph.size
                glyph.draw(in: CGRect(x: (size.width - glyphSize.width) / 2,
                                      y: (size.height - glyphSize.height) / 2,
                                      width: glyphSize.width, height: glyphSize.height))
            }
            _ = context
        }
        cache[key] = rendered
        return rendered
    }
}
