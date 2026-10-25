//
//  MapDetailInput.swift
//  RadarMap
//
//  Что нужно решению «что показывать сейчас» (MapDetailPolicy, 29.H) от
//  сервисов — одно место для телефона, экрана машины, плитки и приборки.
//  Зовётся из тела карты — вью-изолятора тика (правило 13), как
//  StopViewInput; гистерезис подъезда к цели хранит вызывающий
//  (`arriving`, не наблюдаемое).
//

import CoreLocation
import Foundation

@MainActor
enum MapDetailInput {

    struct Output {
        var decision: MapDetailPolicy.Decision
        /// Наши значки, разрешённые решением.
        var marks: [MapDetailPlaces.Mark]
        /// Пунктир от конца маршрута к цели (режим прибытия).
        var approach: [CLLocationCoordinate2D]?
        /// Цель маршрута, если решение показывает её флагом или ореолом.
        var destination: CLLocationCoordinate2D?
        /// Точки, которые кадр держит в режиме прибытия: цель и ближайшие
        /// парковки у неё.
        var keepPoints: [CLLocationCoordinate2D]
    }

    /// - Parameters:
    ///   - standing: стоим — StopView.State.standing (гистерезис 29.D).
    ///   - arriving: прошлое решение было «подъезд к цели» — читается и пишется.
    static func read(_ arriving: inout Bool, env: AppEnvironment, surface: MapDetailPolicy.Surface,
                     tripActive: Bool, standing: Bool, night: Bool, covered: Bool = false) -> Output {
        let route = env.route
        let remaining = route.isActive ? route.remainingDistance : nil
        // Время до цели — только там, где оно решает (ближе потолка): остаток
        // по своим поездкам и хвост прибытия не нужны на каждом тике трассы.
        let seconds = remaining.flatMap { $0 <= AppConfig.mapDetailArrivalTimeCeilingMeters ? route.remainingTime : nil }
        let context = MapDetailPolicy.Context(
            surface: surface, tripActive: tripActive, standing: standing,
            hasRoute: route.isActive,
            routePending: route.isProgressFrozen || (route.isBuilding && route.destinationCoordinate != nil),
            remainingMeters: remaining, remainingSeconds: seconds,
            routeMeters: route.selected?.distance ?? 0,
            night: night, hot: env.thermal.mode != .full, covered: covered,
            fuelLow: nil, wasArriving: arriving)
        let decision = MapDetailPolicy.decide(context)
        arriving = decision.isArrival
        let marks = MapDetailPlaces.marks(decision, found: env.mapDetail.found)
        let destination = decision.destination >= .flag ? route.destinationCoordinate : nil
        var approach: [CLLocationCoordinate2D]?
        var keep: [CLLocationCoordinate2D] = []
        if decision.destination == .arrival, let destination {
            approach = MapDetailPlaces.approach(routeEnd: route.routeCoordinates.last, destination: destination)
        }
        if decision.keepDestination, let destination {
            keep = [destination] + marks.filter { $0.kind == .parking }.prefix(2).map(\.coordinate)
        }
        return Output(decision: decision, marks: marks, approach: approach, destination: destination,
                      keepPoints: keep)
    }
}
