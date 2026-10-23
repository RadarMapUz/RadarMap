//
//  CameraZoneDisplay.swift
//  RadarMap
//
//  Зона камеры на асфальте (CameraZone, 28.B) — одно решение на телефон и
//  машину, рядом с CameraOnLineDisplay: та же цель, что у цветного значка,
//  и лента кончается там, где этот значок нарисован.
//
//  Дёшево на кадре: выбор цели — проход по камерам маршрута; курс маршрута
//  у камеры (проход по линии) считается один раз на цель и маршрут и
//  запоминается; лента — десяток точек куска дороги. Движок пишет источник
//  только при смене ленты (EngineCameraZone).
//
//  Только картинка: ни один сервис это не читает.
//

import CoreLocation
import MapKit

extension AppEnvironment {

    func cameraZone(line: CameraOnLine.Display) -> CameraZone.Band? {
        let routeActive = route.isActive
        let routeCameras = route.camerasOnRoute
        let nearest = location.displayNearestCamera
        guard let id = CameraZone.target(
            route: routeCameras.map { (id: $0.id, along: $0.distanceAlong) },
            spots: route.cameraSpotsOnRoute,
            progress: routeActive ? route.progressAlong : nil,
            nearest: nearest?.id) else { return nil }
        let camera: Camera
        let heading: Double
        if routeActive {
            guard let routeCamera = routeCameras.first(where: { $0.id == id }),
                  let polyline = route.polyline,
                  let routeHeading = CameraZoneHeadings.shared.heading(
                      polyline: polyline, cameraID: id, along: routeCamera.distanceAlong,
                      points: { route.selected?.points ?? [] }) else { return nil }
            camera = routeCamera.camera
            heading = routeHeading
        } else {
            guard let nearest else { return nil }
            camera = nearest
            // Курс дороги под машиной, без прижима — курс значка.
            heading = location.displayRoadBearing ?? location.displayCourse
        }
        return CameraZone.band(camera: camera, heading: heading, anchor: line.points[id]?.coordinate)
    }
}

/// Курс маршрута у камеры: один проход по линии на цель и маршрут.
@MainActor
final class CameraZoneHeadings {
    static let shared = CameraZoneHeadings()

    private struct Key: Equatable {
        let route: ObjectIdentifier
        let camera: Int
        let along: Double
    }

    private var key: Key?
    private var value: Double?

    func heading(polyline: MKPolyline, cameraID: Int, along: Double,
                 points: () -> [MKMapPoint]) -> Double? {
        let wanted = Key(route: ObjectIdentifier(polyline), camera: cameraID, along: along)
        if key == wanted { return value }
        key = wanted
        value = CameraZone.routeHeading(points: points(), along: along)
        return value
    }
}
