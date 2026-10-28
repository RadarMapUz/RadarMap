//
//  AppEnvironment+Family.swift
//  RadarMap
//
//  «Близкие видят прибытие» (22.1): факты о поездке для FamilyShareService.
//  Решения — в чистом FamilyShare; здесь только сбор того, что знают
//  маршрут, призрак дороги, «Дорога на работу» и поездка.
//

import CoreLocation
import Foundation

extension AppEnvironment {

    /// Дом для близких: заданный вручную старше выученного — то же правило,
    /// что у подсказки «Домой». Работа для этого не нужна.
    var familyHome: CLLocationCoordinate2D? {
        settings.place(for: .home)?.coordinate
            ?? learnedPlaces.first { $0.kind == .home }?.coordinate
    }

    /// Что известно о поездке сейчас. Зовётся на фиксах поездки и на
    /// изменениях настроек близких — не в body.
    func familyContext() -> FamilyShare.Context {
        var context = FamilyShare.Context()
        context.isTripActive = location.isTripActive
        context.isPassenger = location.isPassengerSession
        context.isContinuation = trip.isContinuation
        context.screenVisible = isPhoneSceneActive
        let home = familyHome
        if route.isActive {
            // Время маршрута — та же минута, что на панели (RouteService.arrival).
            context.routeArrival = route.arrival
            context.routeToHome = FamilyShare.isNearHome(route.destinationCoordinate, home: home)
        }
        // В смене таксиста призрака нет, и старт у «работы» не значит «домой»
        // (12б.9): остаются цель маршрута и «Еду домой».
        guard !settings.workDriverMode else { return context }
        if let ghost = commuteLive.display, ghost.direction == .toHome {
            context.commuteToHome = true
            context.ghostArrival = ghost.arrival
        }
        // Призрак мог не начаться (мало поездок этого часа), а старт у работы —
        // уже «домой»; время — «обычно» плюс стоянки этой поездки.
        if let ends = commuteEnds, let start = trip.startCoordinate,
           CommuteLiveService.direction(start: start, home: ends.home, work: ends.work) == .toHome {
            context.commuteToHome = true
            if let usual = commute.first(where: { $0.direction == .toHome })?.usual,
               let started = trip.startedAt {
                let stopped = trip.stops.reduce(0) { $0 + $1.duration }
                context.typicalArrival = started.addingTimeInterval(usual + stopped)
            }
        }
        return context
    }

    /// Конец поездки для близких: «дома» — в 200 м от Дома или у цели
    /// маршрута, которая и есть Дом (ArrivalFinish закрыл поездку сам).
    func familyTripEnded() {
        let end = location.lastTripEnd
        let destination = route.lastArrival?.destination.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }
        let arrived = FamilyShare.arrivedHome(endedAt: location.currentCoordinate, home: familyHome,
                                              atDestination: end.atDestination, destination: destination)
        family.tripEnded(end.kind, arrivedHome: arrived)
    }
}
