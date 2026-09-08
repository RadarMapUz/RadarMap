//
//  EngineMapView.swift
//  RadarMap
//
//  Карта, которую рисует ДВИЖОК (MapLibre Native), а не наш холст.
//
//  Зачем. Самописный рендер упёрся не в скорость, а в картографию: ленты
//  разной ширины встык, срезанные торцы, тёмные пятна оболочек перекрёстков,
//  подписи без расстановки, порядок отрисовки, ломающийся на границе тайлов.
//  Всё это движок делает сам, и делает так же, как большие карты, потому что
//  это ровно тот же движок и тот же формат стиля.
//
//  Данные — НАШИ. Те же тайлы, что собирает build_roads.py, только в MVT, и
//  тот же стиль, который уже год работает в панели модератора. Ни одного
//  чужого источника: ни подложки, ни спутника, ни шрифтов из сети.
//
//  Вся обвязка под `canImport(MapLibre)`: пока пакет не добавлен в проект,
//  файл компилируется в пустоту, а экран остаётся на прежней схеме. Это и
//  есть выключатель на случай, если движок не выживет на живом телефоне.
//

#if canImport(MapLibre)
import CoreLocation
import MapLibre
import SwiftUI
import os

private final class EngineNativeMapView: MLNMapView {
    var onLayout: ((MLNMapView) -> Void)?
    private var previousSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, bounds.size != previousSize else { return }
        previousSize = bounds.size
        onLayout?(self)
    }
}

struct EngineMapView: UIViewRepresentable {

    /// Где мы (уже прижатые к оси координаты — те же, что у схемы).
    var coordinate: CLLocationCoordinate2D
    /// Курс, градусы. Отрицательный — курса нет, карту не крутим.
    var courseDegrees: Double
    /// Охват по высоте вида, метры.
    var spanMeters: Double
    var anchorY: Double = RoadSketch.meY
    /// Наклон, градусы.
    var pitchDegrees: Double
    var daylight: Bool
    /// Дома. Тот же тумблер, что у своей схемы: подложка меняется, а правило
    /// «за что мы платим трафиком» остаётся одно на оба рендера.
    var houses: Bool = false
    /// Камеры окрестности; `alert` — та, о которой сейчас предупреждаем.
    var cameras: [Camera]
    var alertCameraID: Int?
    var cameraLimits: [Int: Int] = [:]
    var route: [CLLocationCoordinate2D]
    var onSelectCamera: (Camera) -> Void = { _ in }

    func makeUIView(context: Context) -> MLNMapView {
        // Сторож тайлов — ДО первой карты: движок начинает качать сразу, и
        // поставить проверку после значило бы пропустить первые тайлы без неё.
        EngineTileGuard.install()
        // Кэш тайлов — это ОФЛАЙН, а не ускорение. Связи в поездке по стране
        // нет часами, а карта обязана рисоваться: движок держит уже виденные
        // тайлы в своей базе и берёт их оттуда, пока они не протухли. Двести
        // мегабайт — примерно область, по которой человек ездит каждый день;
        // полноценные offline-паки на регион — отдельная работа.
        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(
            UInt(AppConfig.engineMapCacheBytes)) { _ in }
        let view = EngineNativeMapView(frame: .zero)
        // Жесты карты выключены целиком: за рулём вид ведёт машина, а не
        // палец. Осмотр и щипок вернутся отдельной работой, вместе с
        // автовозвратом, как в схеме.
        view.isScrollEnabled = false
        view.isZoomEnabled = false
        view.isRotateEnabled = false
        view.isPitchEnabled = false
        view.compassView.isHidden = true
        view.logoView.isHidden = true
        // Ссылка на источник данных обязана остаться: тайлы построены по OSM.
        view.attributionButtonPosition = .bottomLeft
        view.delegate = context.coordinator
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator,
                                                          action: #selector(Coordinator.selectCamera(_:))))
        context.coordinator.view = view
        view.onLayout = { [weak coordinator = context.coordinator] view in
            guard let coordinator, let model = coordinator.current else { return }
            coordinator.apply(model, to: view)
        }
        context.coordinator.loadStyle(self, in: view)
        Task { @MainActor [weak view, weak coordinator = context.coordinator] in
            await EngineTileGuard.prepare()
            guard EngineTileGuard.isReady, let view, let coordinator,
                  let model = coordinator.current else { return }
            // The first tile requests can precede the signed index. Retry only
            // after verification; never bypass the tile guard for a preview.
            coordinator.loadStyle(model, in: view)
        }
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        context.coordinator.apply(self, to: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate {

    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей:
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor изолирует КАЖДЫЙ класс, а не
    /// только помеченный @MainActor, и синтезированный isolated deinit ведёт
    /// в свободу указателя, который никто не выделял (см. MapState).
    nonisolated deinit {}
        weak var view: MLNMapView?
        private var cameraPlaced = false
        private var styleReady = false
        private var lastDaylight: Bool?
        private var lastHouses: Bool?
        private var lastCameras: [Camera]?
        private var lastLimits: [Int: Int] = [:]
        private var lastAlertID: Int?
        private var lastRoute: [CLLocationCoordinate2D]?

        private func installCameraIcons(in style: MLNStyle) {
            let renderer = ImageRenderer(content: MeCursor(scale: 1)
                .frame(width: 30, height: 36).padding(8))
            renderer.scale = 3
            if let image = renderer.uiImage { style.setImage(image, forName: "radar-user") }
            let kinds: [CameraType] = [.stationaryCamera, .stationaryRadar,
                .intelligentRadar, .mobileRadar, .tripod, .dpsPost, .accident, .other("")]
            for kind in kinds {
                let configuration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                if let image = UIImage(systemName: kind.symbolName, withConfiguration: configuration) {
                    // Bake SF Symbol tint into pixels: Native does not apply
                    // UIKit's template rendering mode to a style image.
                    let bitmap = UIGraphicsImageRenderer(size: image.size).image { _ in
                        image.withTintColor(.white, renderingMode: .alwaysOriginal)
                            .draw(at: .zero)
                    }
                    style.setImage(bitmap, forName: kind.symbolName)
                }
            }
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            Log.network.info("MapLibre: стиль загружен")
            installCameraIcons(in: style)
            lastCameras = nil
            lastRoute = nil
            styleReady = true
            pending.map { apply($0, to: mapView) }
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            Log.network.error("MapLibre: ошибка загрузки: \(error.localizedDescription, privacy: .public)")
        }

        private var pending: EngineMapView?
        fileprivate var current: EngineMapView?

        @objc func selectCamera(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view, let current else { return }
            let point = gesture.location(in: view)
            let rect = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            let features = view.visibleFeatures(in: rect, styleLayerIdentifiers: ["camera-dot"])
            let ids = Set(features.compactMap { ($0.attribute(forKey: "id") as? NSNumber)?.intValue })
            let nearest = current.cameras.filter { ids.contains($0.id) }.min { a, b in
                let pa = view.convert(a.coordinate, toPointTo: view)
                let pb = view.convert(b.coordinate, toPointTo: view)
                return hypot(pa.x - point.x, pa.y - point.y) < hypot(pb.x - point.x, pb.y - point.y)
            }
            if let nearest { current.onSelectCamera(nearest) }
        }

        func loadStyle(_ model: EngineMapView, in view: MLNMapView) {
            // Keep pending state ready before the asynchronous style callback.
            // The delegate is already installed when the first style is set.
            current = model
            pending = model
            styleReady = false
            lastDaylight = model.daylight
            lastHouses = model.houses
            view.styleJSON = EngineMapStyle.json(daylight: model.daylight,
                                                 base: AppConfig.syncBaseURL,
                                                 houses: model.houses,
                                                 tilesReady: EngineTileGuard.isReady)
        }

        func apply(_ model: EngineMapView, to view: MLNMapView) {
            current = model
            guard styleReady, view.bounds.width > 0, view.bounds.height > 0 else {
                pending = model
                return
            }
            pending = nil

            if lastDaylight != model.daylight || lastHouses != model.houses {
                loadStyle(model, in: view)
                return
            }

            // Точка зрения. «Я» стоит не в центре, а ниже — впереди должно
            // быть видно больше, чем позади. contentInset для этого НЕ
            // используем осознанно: связка «слежение за курсом + наклон +
            // contentInset» — известная беда движка (issue #3029, до 400 %
            // процессора и перегрев). Смещаем саму точку взгляда вперёд по
            // курсу: та же картинка, обычной арифметикой.
            let ahead = model.spanMeters * (model.anchorY - 0.5)
            let centre = GeoMath.destination(from: model.coordinate,
                                              bearing: max(0, model.courseDegrees),
                                              distanceMeters: ahead)
            let zoom = Self.zoom(spanMeters: model.spanMeters, height: view.bounds.height,
                                 latitude: centre.latitude)
            let altitude = MLNAltitudeForZoomLevel(zoom, model.pitchDegrees,
                                                  centre.latitude, view.bounds.size)
            let camera = MLNMapCamera(lookingAtCenter: centre, altitude: altitude,
                                      pitch: model.pitchDegrees,
                                      heading: max(0, model.courseDegrees))
            view.setCamera(camera, withDuration: cameraPlaced ? 0.9 : 0,
                           animationTimingFunction: CAMediaTimingFunction(name: .linear))
            if !cameraPlaced {
                Log.network.info("MapLibre: камера установлена, zoom \(view.zoomLevel, privacy: .public)")
            }
            cameraPlaced = true
            update(source: "position", in: view, geoJSON: [
                "type": "Feature", "properties": [:],
                "geometry": ["type": "Point", "coordinates":
                    [model.coordinate.longitude, model.coordinate.latitude]],
            ])

            if model.cameras != lastCameras || model.alertCameraID != lastAlertID || model.cameraLimits != lastLimits {
                lastCameras = model.cameras
                lastAlertID = model.alertCameraID
                lastLimits = model.cameraLimits
                update(source: "cameras", in: view, geoJSON: Self.cameraFeatures(
                    model.cameras, alert: model.alertCameraID, limits: model.cameraLimits))
            }
            if lastRoute == nil || !model.route.elementsEqual(lastRoute!, by: {
                $0.latitude == $1.latitude && $0.longitude == $1.longitude
            }) {
                lastRoute = model.route
                update(source: "route", in: view, geoJSON: Self.lineFeature(model.route))
            }
        }

        static func zoom(spanMeters: Double, height: Double, latitude: Double) -> Double {
            let circumference = 40_075_016.686 * cos(latitude * .pi / 180)
            return min(19, max(11, log2(circumference * max(1, height)
                                       / (512 * max(1, spanMeters)))))
        }

        private func update(source: String, in view: MLNMapView, geoJSON: [String: Any]) {
            guard let style = view.style,
                  let shape = style.source(withIdentifier: source) as? MLNShapeSource,
                  let data = try? JSONSerialization.data(withJSONObject: geoJSON),
                  let feature = try? MLNShape(data: data, encoding: String.Encoding.utf8.rawValue)
            else { return }
            shape.shape = feature
        }

        static func cameraFeatures(_ cameras: [Camera], alert: Int?, limits: [Int: Int] = [:]) -> [String: Any] {
            [
                "type": "FeatureCollection",
                "features": cameras.map { camera in
                    [
                        "type": "Feature",
                        "properties": ["id": camera.id, "alert": camera.id == alert,
                                       "icon": camera.kind.symbolName,
                                       "limit": limits[camera.id].map { String($0) } ?? "",
                                       "unconfirmed": camera.isUnconfirmedMobile],
                        "geometry": ["type": "Point",
                                     "coordinates": [camera.lon, camera.lat]],
                    ]
                },
            ]
        }

        static func lineFeature(_ points: [CLLocationCoordinate2D]) -> [String: Any] {
            guard points.count >= 2 else {
                return ["type": "FeatureCollection", "features": []]
            }
            return [
                "type": "FeatureCollection",
                "features": [[
                    "type": "Feature",
                    "properties": [:],
                    "geometry": ["type": "LineString",
                                 "coordinates": points.map { [$0.longitude, $0.latitude] }],
                ]],
            ]
        }
    }
}
#endif
