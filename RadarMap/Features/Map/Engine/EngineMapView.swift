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

struct EngineMapView: UIViewRepresentable {

    /// Где мы (уже прижатые к оси координаты — те же, что у схемы).
    var coordinate: CLLocationCoordinate2D
    /// Курс, градусы. Отрицательный — курса нет, карту не крутим.
    var courseDegrees: Double
    /// Охват по высоте вида, метры.
    var spanMeters: Double
    /// Наклон, градусы.
    var pitchDegrees: Double
    var daylight: Bool
    /// Камеры окрестности; `alert` — та, о которой сейчас предупреждаем.
    var cameras: [Camera]
    var alertCameraID: Int?
    var route: [CLLocationCoordinate2D]

    func makeUIView(context: Context) -> MLNMapView {
        // Сторож тайлов — ДО первой карты: движок начинает качать сразу, и
        // поставить проверку после значило бы пропустить первые тайлы без неё.
        EngineTileGuard.install()
        Task { await EngineTileGuard.prepare() }
        // Кэш тайлов — это ОФЛАЙН, а не ускорение. Связи в поездке по стране
        // нет часами, а карта обязана рисоваться: движок держит уже виденные
        // тайлы в своей базе и берёт их оттуда, пока они не протухли. Двести
        // мегабайт — примерно область, по которой человек ездит каждый день;
        // полноценные offline-паки на регион — отдельная работа.
        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(
            UInt(AppConfig.engineMapCacheBytes)) { _ in }
        let view = MLNMapView(frame: .zero)
        view.styleJSON = EngineMapStyle.json(daylight: daylight, base: AppConfig.syncBaseURL)
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
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        context.coordinator.apply(self, to: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate {
        weak var view: MLNMapView?
        private var styleReady = false
        private var lastDaylight: Bool?
        private var lastCameras: [Int] = []
        private var lastRouteCount = -1

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            styleReady = true
            pending.map { apply($0, to: mapView) }
        }

        private var pending: EngineMapView?

        func apply(_ model: EngineMapView, to view: MLNMapView) {
            guard styleReady else { pending = model; return }
            pending = nil

            if lastDaylight != model.daylight {
                lastDaylight = model.daylight
                view.styleJSON = EngineMapStyle.json(daylight: model.daylight,
                                                     base: AppConfig.syncBaseURL)
                styleReady = false
                pending = model
                return
            }

            // Точка зрения. «Я» стоит не в центре, а ниже — впереди должно
            // быть видно больше, чем позади. contentInset для этого НЕ
            // используем осознанно: связка «слежение за курсом + наклон +
            // contentInset» — известная беда движка (issue #3029, до 400 %
            // процессора и перегрев). Смещаем саму точку взгляда вперёд по
            // курсу: та же картинка, обычной арифметикой.
            let ahead = model.spanMeters * (RoadSketch.meY - 0.5)
            let centre = model.courseDegrees >= 0
                ? GeoMath.destination(from: model.coordinate,
                                      bearing: model.courseDegrees,
                                      distanceMeters: ahead)
                : model.coordinate
            let camera = MLNMapCamera(lookingAtCenter: centre,
                                      acrossDistance: model.spanMeters,
                                      pitch: model.pitchDegrees,
                                      heading: max(0, model.courseDegrees))
            view.setCamera(camera, withDuration: 0.9,
                           animationTimingFunction: CAMediaTimingFunction(name: .linear))

            let ids = model.cameras.map(\.id)
            if ids != lastCameras || model.alertCameraID != nil {
                lastCameras = ids
                update(source: "cameras", in: view, geoJSON: Self.cameraFeatures(
                    model.cameras, alert: model.alertCameraID))
            }
            if model.route.count != lastRouteCount {
                lastRouteCount = model.route.count
                update(source: "route", in: view, geoJSON: Self.lineFeature(model.route))
            }
        }

        private func update(source: String, in view: MLNMapView, geoJSON: [String: Any]) {
            guard let style = view.style,
                  let shape = style.source(withIdentifier: source) as? MLNShapeSource,
                  let data = try? JSONSerialization.data(withJSONObject: geoJSON),
                  let feature = try? MLNShape(data: data, encoding: String.Encoding.utf8.rawValue)
            else { return }
            shape.shape = feature
        }

        static func cameraFeatures(_ cameras: [Camera], alert: Int?) -> [String: Any] {
            [
                "type": "FeatureCollection",
                "features": cameras.map { camera in
                    [
                        "type": "Feature",
                        "properties": ["alert": camera.id == alert],
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
