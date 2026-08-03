//
//  CameraMapContent.swift
//  RadarMap
//
//  Что рисовать на карте для данной области: отдельные камеры или кластеры.
//
//  Раньше это решал зум: шире 1.2° — кластеры, иначе до 220 одиночных точек с
//  жёстким усечением по расстоянию от центра. На обзоре района в Ташкенте камер
//  многократно больше 220, и лишние молча пропадали: по краям экрана пусто, при
//  панораме точки то появляются, то исчезают — «камеры не загрузились».
//
//  Теперь решение принимают ДАННЫЕ: если камер в области больше бюджета
//  аннотаций, область кластеризуется целиком, и ни одна камера не теряется —
//  она либо точка, либо часть кластера с числом. Плюс кластеры строятся по
//  пространственному индексу (а не полным перебором всех 3467 камер на главном
//  потоке) и с упакованным Int64-ключом вместо строковой интерполяции.
//

import Foundation
import MapKit

/// Кластер камер: центроид + количество.
struct CameraCluster: Identifiable, Equatable {
    let id: Int64
    let coordinate: CLLocationCoordinate2D
    let count: Int

    static func == (lhs: CameraCluster, rhs: CameraCluster) -> Bool {
        lhs.id == rhs.id && lhs.count == rhs.count
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

nonisolated enum CameraMapContent {

    /// Готовый слой карты: либо точки, либо кластеры (одновременно — только
    /// одиночки в своих ячейках рядом с кластерами).
    struct Layer: Equatable {
        var cameras: [Camera] = []
        var clusters: [CameraCluster] = []
        var isClustered = false
    }

    /// Собрать слой для области. Тяжёлая часть (перебор области и группировка)
    /// уходит с главного потока: на обзорном зуме это тысячи камер.
    @concurrent
    static func layer(cameras: [Camera], region: MKCoordinateRegion,
                      filter: CameraFilter, budget: Int,
                      divisions: Double = AppConfig.clusterGridDivisions) async -> Layer {
        let box = Box(region)
        let inside = cameras.filter { filter.matches($0) && box.contains(lat: $0.lat, lon: $0.lon) }
        guard inside.count > budget else {
            return Layer(cameras: inside, clusters: [], isClustered: false)
        }

        let cellLat = region.span.latitudeDelta / divisions
        let cellLon = region.span.longitudeDelta / divisions
        guard cellLat > 0, cellLon > 0 else {
            return Layer(cameras: Array(inside.prefix(budget)), clusters: [], isClustered: true)
        }

        struct Bucket {
            var sumLat = 0.0
            var sumLon = 0.0
            var count = 0
            var first: Camera?
        }
        var buckets: [Int64: Bucket] = [:]
        buckets.reserveCapacity(inside.count / 4 + 1)
        for camera in inside {
            let y = Int64((camera.lat - box.latMin) / cellLat)
            let x = Int64((camera.lon - box.lonMin) / cellLon)
            let key = y << 32 | (x & 0xFFFF_FFFF)
            var bucket = buckets[key] ?? Bucket()
            bucket.sumLat += camera.lat
            bucket.sumLon += camera.lon
            bucket.count += 1
            if bucket.count == 1 { bucket.first = camera }
            buckets[key] = bucket
        }

        var clusters: [CameraCluster] = []
        var singles: [Camera] = []
        for (key, bucket) in buckets {
            // Одна камера в ячейке — рисуем как обычный маркер, не как «кластер из 1».
            if bucket.count == 1, let single = bucket.first {
                singles.append(single)
            } else {
                clusters.append(CameraCluster(
                    id: key,
                    coordinate: CLLocationCoordinate2D(latitude: bucket.sumLat / Double(bucket.count),
                                                       longitude: bucket.sumLon / Double(bucket.count)),
                    count: bucket.count))
            }
        }
        // Одиночек тоже может быть много (разреженная область) — держим в бюджете.
        if singles.count > budget {
            singles = Array(singles.prefix(budget))
        }
        return Layer(cameras: singles, clusters: clusters, isClustered: true)
    }

    /// Рамка области в градусах — считается один раз, а не на каждую камеру.
    private struct Box {
        let latMin, latMax, lonMin, lonMax: Double

        init(_ region: MKCoordinateRegion) {
            latMin = region.center.latitude - region.span.latitudeDelta / 2
            latMax = region.center.latitude + region.span.latitudeDelta / 2
            lonMin = region.center.longitude - region.span.longitudeDelta / 2
            lonMax = region.center.longitude + region.span.longitudeDelta / 2
        }

        func contains(lat: Double, lon: Double) -> Bool {
            lat >= latMin && lat <= latMax && lon >= lonMin && lon <= lonMax
        }
    }
}
