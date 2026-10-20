//
//  RouteCamerasAhead.swift
//  RadarMap
//
//  Камеры впереди по маршруту — для плитки «Камер впереди: N» и списка в
//  машине (план 19.10, 10.4). Число камер на маршруте показывал только выбор
//  варианта до старта; во время ведения его не было видно нигде, а «сколько
//  ещё камер до дома» — вопрос, который водитель задаёт на ходу.
//
//  Чистая логика — RouteCamerasAheadTests.
//

import CoreLocation

enum RouteCamerasAhead {
    struct Item: Equatable {
        let camera: Camera
        /// Сколько ехать до неё по маршруту, м.
        let meters: CLLocationDistance
    }

    /// Камеры впереди по ходу маршрута, ближние первыми. Проеханная (позади
    /// точки прогресса) — не впереди, даже на метр.
    static func list(_ cameras: [RouteService.RouteCamera], progress: CLLocationDistance,
                     limit: Int = .max) -> [Item] {
        cameras
            .filter { $0.distanceAlong > progress }
            .sorted { $0.distanceAlong < $1.distanceAlong }
            .prefix(max(0, limit))
            .map { Item(camera: $0.camera, meters: $0.distanceAlong - progress) }
    }
}
