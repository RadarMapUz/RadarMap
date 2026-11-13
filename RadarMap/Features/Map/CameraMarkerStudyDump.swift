//
//  CameraMarkerStudyDump.swift
//  RadarMap
//
//  DEBUG, задача 90 (`-dumpMarkerStudy <папка>`): снимки НАШЕЙ карты
//  (EngineMapSnapshot — тот же стиль и тайлы, что у живой) без камер и
//  экранные точки камер базы на них. Значки вариантов кладёт поверх тот же
//  CameraMarkerStudy — лист сравнения собирается без перестройки приложения.
//  Кадры — `scenes.json` в папке: [{name, lat, lon, width, w, h, scale, daylight, extra}].
//

#if DEBUG && canImport(MapLibre)
import CoreLocation
import MapKit
import os
import UIKit

enum CameraMarkerStudyDump {

    struct Scene: Decodable {
        let name: String
        let lat: Double
        let lon: Double
        /// Ширина кадра в метрах.
        let width: Double
        let w: Double
        let h: Double
        let scale: Double
        let daylight: Bool
    }

    @MainActor
    static func run(directory: URL, cameras: [Camera]) async {
        let scenes: [Scene]
        do {
            scenes = try JSONDecoder().decode([Scene].self, from: Data(contentsOf: directory.appendingPathComponent("scenes.json")))
        } catch {
            Log.app.error("90: scenes.json не прочитан: \(error.localizedDescription, privacy: .public)")
            return
        }
        for scene in scenes {
            let center = CLLocationCoordinate2D(latitude: scene.lat, longitude: scene.lon)
            let perMeter = MKMapPointsPerMeterAtLatitude(scene.lat)
            let width = scene.width * perMeter
            let height = width * scene.h / scene.w
            let middle = MKMapPoint(center)
            let rect = MKMapRect(x: middle.x - width / 2, y: middle.y - height / 2, width: width, height: height)
            guard let shot = await EngineMapSnapshot.render(rect: rect, size: CGSize(width: scene.w, height: scene.h),
                                                            daylight: scene.daylight, scale: scene.scale) else {
                Log.app.error("90: снимок \(scene.name, privacy: .public) не вышел")
                continue
            }
            let inside = cameras.compactMap { camera -> [String: Any]? in
                let point = shot.project(camera.coordinate)
                guard point.x > -40, point.y > -40, point.x < scene.w + 40, point.y < scene.h + 40 else { return nil }
                return ["id": camera.id, "type": camera.type, "lat": camera.lat, "lon": camera.lon,
                        "x": Double(point.x), "y": Double(point.y)]
            }
            let nw = MKMapPoint(x: rect.minX, y: rect.minY).coordinate
            let se = MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate
            let corners = [nw, se].map { coordinate -> [String: Double] in
                let point = shot.project(coordinate)
                return ["lat": coordinate.latitude, "lon": coordinate.longitude,
                        "x": Double(point.x), "y": Double(point.y)]
            }
            let meta: [String: Any] = ["cameras": inside, "corners": corners, "w": scene.w, "h": scene.h,
                                       "scale": scene.scale]
            do {
                try shot.image.pngData()?.write(to: directory.appendingPathComponent(scene.name + ".png"))
                try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent(scene.name + ".json"))
            } catch {
                Log.app.error("90: кадр \(scene.name, privacy: .public) не записан: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            try Data("done".utf8).write(to: directory.appendingPathComponent("done.txt"))
        } catch {
            Log.app.error("90: метка готовности не записана: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
