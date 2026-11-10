//
//  TripodZoneDisplay.swift
//  RadarMap
//
//  Участок треноги на асфальте (TripodZone, 83) — одно решение на телефон и
//  машину, рядом с CameraZoneDisplay.
//
//  Дёшево на кадре: выбор цели — проход по живым отметкам (по стране их
//  горстка) и зонам «часто ставят». Места целей на линии маршрута считаются
//  раз на маршрут и набор целей; оси дорог у цели запрашиваются раз на цель,
//  куски — на смене цели или курса на 15°. Движок пишет источник только при
//  смене участка (EngineTripodZone).
//
//  Только картинка: ни один сервис это не читает.
//

import CoreLocation
import MapKit

extension AppEnvironment {

    func tripodZone() -> TripodZone.Band? {
        guard let me = location.displayCoordinate ?? location.currentCoordinate else { return nil }
        let own = mobile.ownFreshIDs
        let tripods = cameras.mobile.compactMap { camera -> TripodZone.Candidate? in
            guard camera.kind == .tripod || camera.kind == .mobileRadar else { return nil }
            // Ступень доверия — та же, что у метки (CameraMarkerLook.isGhost).
            let ghost = CameraMarkerLook.isGhost(unconfirmed: camera.isUnconfirmedMobile, own: own.contains(camera.id))
            return TripodZone.Candidate(key: camera.id, coordinate: camera.coordinate,
                                        grade: ghost ? .unconfirmed : .confirmed)
        }
        let spots = settings.tripodHints ? hotspots.spots.map { spot in
            TripodZone.Candidate(key: TripodZone.hotspotKey(latitude: spot.lat, longitude: spot.lon),
                                 coordinate: spot.coordinate, grade: .hotspot)
        } : []
        guard !tripods.isEmpty || !spots.isEmpty else { return nil }
        let course = location.displayRoadBearing ?? location.displayCourse
        let cache = TripodZoneCache.shared
        let routeLine = route.isActive ? route.polyline : nil
        let routePoints = { [route] in route.selected?.points ?? [] }
        let routeAlong = routeLine.map { cache.alongs(route: $0, points: routePoints, candidates: tripods + spots) }
        guard let target = TripodZone.target(tripods: tripods, hotspots: spots, me: me, course: course,
                                             routeAlong: routeAlong, progress: routeLine == nil ? nil : route.progressAlong)
        else { return nil }
        let limitIndex = settings.speedLimitsEnabled ? speedLimits.limitIndex : nil
        return cache.band(target: target, routeLine: routeLine, routePoints: routePoints,
                          along: routeAlong?[target.key], course: course,
                          revision: speedLimits.indexRevision,
                          network: { [roads] in roads.vehicleNetwork },
                          limit: { limitIndex?.match($0, courseDegrees: $1) })
    }
}

/// Кэши участка: места на маршруте, оси дорог у цели, куски.
@MainActor
final class TripodZoneCache {
    static let shared = TripodZoneCache()

    private var alongKey: Int?
    private var alongValues: [Int: Double] = [:]

    func alongs(route: MKPolyline, points: () -> [MKMapPoint],
                candidates: [TripodZone.Candidate]) -> [Int: Double] {
        var hasher = Hasher()
        hasher.combine(ObjectIdentifier(route))
        for candidate in candidates {
            hasher.combine(candidate.key)
            hasher.combine(candidate.latitude)
            hasher.combine(candidate.longitude)
        }
        let key = hasher.finalize()
        if key == alongKey { return alongValues }
        alongKey = key
        let line = points()
        let rect = route.boundingMapRect
        let margin = MKMapPointsPerMeterAtLatitude(rect.origin.coordinate.latitude) * AppConfig.tripodZoneRouteMeters
        let reach = rect.insetBy(dx: -margin, dy: -margin)
        var out: [Int: Double] = [:]
        for candidate in candidates where reach.contains(MKMapPoint(candidate.coordinate)) {
            if let along = TripodZone.along(of: candidate.coordinate, route: line) { out[candidate.key] = along }
        }
        alongValues = out
        return out
    }

    private struct GeometryKey: Equatable {
        let key: Int
        let latitude: Double
        let longitude: Double
        let route: ObjectIdentifier?
        /// Курс на 15°; −1 — без курса. На маршруте — 0: сторону даёт линия.
        let bucket: Int
        let revision: Int
    }

    private var geometryKey: GeometryKey?
    private var lastPieces: [TripodZone.Piece]?
    private var linesKey: (key: Int, revision: Int)?
    private var lines: [RoadLine] = []
    private var emptyAt: Date?
    private var band: TripodZone.Band?

    func band(target: TripodZone.Candidate, routeLine: MKPolyline?, routePoints: () -> [MKMapPoint],
              along: Double?, course: Double, revision: Int,
              network: () -> any RoadNetworkSource,
              limit: @escaping (CLLocationCoordinate2D, Double) -> Int?) -> TripodZone.Band? {
        let bucket = routeLine != nil ? 0 : (course < 0 ? -1 : Int(course / 15) % 24)
        let key = GeometryKey(key: target.key, latitude: target.latitude, longitude: target.longitude,
                              route: routeLine.map(ObjectIdentifier.init), bucket: bucket, revision: revision)
        // Сеть дорог ещё пуста (тайлы и лимиты грузятся) — переспросить не чаще раза в 10 с.
        let retry = lastPieces?.isEmpty == true && (emptyAt.map { Date().timeIntervalSince($0) > 10 } ?? true)
        if key != geometryKey || retry {
            geometryKey = key
            let pieces: [TripodZone.Piece]
            if routeLine != nil {
                pieces = along.flatMap { TripodZone.routePiece(route: routePoints(), along: $0) }.map { [$0] } ?? []
            } else {
                if linesKey?.key != target.key || linesKey?.revision != revision || retry {
                    linesKey = (target.key, revision)
                    lines = network().roads(near: target.coordinate,
                                            radius: AppConfig.tripodZoneBeforeMeters + AppConfig.tripodZoneAfterMeters + 100)
                }
                pieces = TripodZone.roadPieces(lines: lines, tripod: target.coordinate, course: course)
            }
            emptyAt = pieces.isEmpty ? Date() : nil
            lastPieces = pieces
            band = TripodZone.band(candidate: target, pieces: pieces, limit: limit)
            return band
        }
        // Ступень сменилась на месте (отметку подтвердили) — участок тот же.
        if let current = band, current.grade != target.grade {
            band = TripodZone.band(candidate: target, pieces: current.pieces, limit: limit)
        }
        return band
    }
}
