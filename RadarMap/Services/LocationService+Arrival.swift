//
//  LocationService+Arrival.swift
//  RadarMap
//
//  Приехали к цели маршрута — поездка закрывается сама, когда встали у неё
//  или заглушили машину (CarPlay отключился). Решение — ArrivalFinish; здесь
//  только факты и таймер: на стоянке фиксов нет, и ждать их нельзя.
//

import Foundation
import CoreLocation
import os

extension LocationService {

    /// Маршрут выполнен (RouteService.onArrived): следить, когда встанем.
    /// Прибытие без поездки (открытый экран) и на её конце
    /// (finishIfNearDestination) сюда тоже приходит — закрывать там нечего.
    func watchArrival(_ summary: RouteService.ArrivalSummary?) {
        guard let summary, isTripActive else { return }
        arrivalWatch = ArrivalFinish.Arrival(at: summary.at, destination: summary.destination,
                                             point: currentCoordinate.map(Self.point))
        Log.trips.notice("прибытие к цели — поездка закроется сама на стоянке")
        checkArrivalFinish()
    }

    /// CarPlay отключился: если это после прибытия — заглушили у цели.
    func noteCarPlayDisconnectedForArrival() {
        guard arrivalWatch != nil else { return }
        arrivalWatch?.carPlayDisconnected = true
        checkArrivalFinish()
    }

    /// Проверка: на фиксе, по таймеру и на отключении CarPlay. Фикс зовёт
    /// её последней в тике: закрытая посреди тика поездка оставила бы его
    /// хвост работать по уже закрытой.
    func checkArrivalFinish(now: Date = Date()) {
        guard let arrival = arrivalWatch else { return }
        let situation = ArrivalFinish.Situation(
            arrival: arrival, now: now,
            isTripActive: isTripActive,
            startsByItself: settings.tripStartMode.usesMotion,
            hasNewRoute: route?.isActive == true || route?.isBuilding == true,
            speedKmh: speedKmh,
            lastMovementAt: lastMovementAt,
            here: currentCoordinate.map(Self.point))
        switch ArrivalFinish.decide(situation) {
        case .wait(let recheckIn):
            // Таймер — только запасной путь без фиксов: срок лишь отодвигается
            // (движение после прибытия), и ранний таймер просто проверит снова.
            guard arrivalRecheck == nil else { return }
            arrivalRecheck = Task { [weak self] in
                await Task.pause(seconds: recheckIn)
                guard !Task.isCancelled, let self else { return }
                self.arrivalRecheck = nil
                self.checkArrivalFinish()
            }
        case .drop:
            stopArrivalWatch()
        case .finish(let reason):
            stopArrivalWatch()
            let stoodFor = Int(now.timeIntervalSince(max(arrival.at, lastMovementAt)))
            Log.trips.notice("поездка закрыта у цели сама: \(reason.rawValue, privacy: .public), стоим \(stoodFor, privacy: .public) с")
            endTrip(auto: true, atDestination: true)
            // CoreMotion, скорее всего, так и считает, что мы «в машине»
            // (стоим с мотором) — иначе автостоп успел бы раньше. Поехали
            // дальше — новый старт по первому настоящему движению, а не по
            // следующему сэмплу «в машине, стоим», который поднял бы поездку
            // тут же, на стоянке.
            motion?.rearmAfterArrival()
        }
    }

    func stopArrivalWatch() {
        arrivalWatch = nil
        arrivalRecheck?.cancel()
        arrivalRecheck = nil
    }

    private static func point(_ coordinate: CLLocationCoordinate2D) -> ArrivalFinish.Point {
        ArrivalFinish.Point(lat: coordinate.latitude, lon: coordinate.longitude)
    }
}
