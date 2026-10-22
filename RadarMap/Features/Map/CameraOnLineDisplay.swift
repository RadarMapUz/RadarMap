//
//  CameraOnLineDisplay.swift
//  RadarMap
//
//  Камеры на пути и где их рисовать (CameraOnLine, 27.B) — одно решение на
//  телефон и машину, чтобы значок, его цвет и подпись «400 м» стояли в одной
//  точке на обоих экранах.
//
//  Дёшево на кадре: точки камер маршрута посчитаны при построении (вне
//  главного потока, RouteService.apply); здесь — отбор по прогрессу и, без
//  маршрута, одна проекция ближайшей камеры на ось нашей дороги.
//  Только картинка: ни один сервис это не читает.
//

import CoreLocation

extension AppEnvironment {

    var cameraOnLine: CameraOnLine.Display {
        let nearest = location.displayNearestCamera
        let routeActive = route.isActive
        #if DEBUG
        // Снимки «до» (27.B): прежний выбор — все камеры коридора, на своих координатах.
        if Self.cameraOnLineOff {
            return CameraOnLine.Display(pathIDs: CameraMarkerLook.pathIDs(
                route: route.camerasOnRoute.map { (id: $0.id, along: $0.distanceAlong) },
                progress: routeActive ? route.progressAlong : nil,
                passedTolerance: AppConfig.routePassedToleranceMeters, nearest: nearest?.id))
        }
        #endif
        var onRoad: CameraOnLine.Point?
        if !routeActive, let nearest, let origin = location.displayCoordinate,
           let bearing = location.displayRoadBearing {
            onRoad = CameraOnLine.roadSpot(camera: nearest, origin: origin, bearing: bearing)
        }
        return CameraOnLine.display(
            route: route.camerasOnRoute.map { (id: $0.id, along: $0.distanceAlong) },
            spots: route.cameraSpotsOnRoute,
            progress: routeActive ? route.progressAlong : nil,
            passedTolerance: AppConfig.routePassedToleranceMeters,
            nearest: nearest?.id, nearestOnRoad: onRoad)
    }

    #if DEBUG
    private static let cameraOnLineOff = ProcessInfo.processInfo.arguments.contains("-cameraOnLineOff")
    #endif
}
