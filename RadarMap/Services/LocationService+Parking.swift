//
//  LocationService+Parking.swift
//  RadarMap
//
//  «Где машина» (12б.1): конец поездки ставит точку, фиксы вне поездки
//  решают, показывать ли её. Ни одного нового запроса GPS — только фиксы,
//  которые и так приходят открытому экрану. Правила — в ParkedCar.
//

import Foundation
import CoreLocation
import os

extension LocationService {
    /// Конец поездки за рулём: точка парковки, если фикс точный.
    func parkCar() {
        guard settings.parkedCarHint else { return }
        parkedCar = ParkedCar.park(lastDriven: lastDrivenFix, asPassenger: false, speedKmh: speedKmh, now: Date())
        lastDrivenFix = nil
        refreshParkedCar()
    }

    /// Принятый фикс в поездке: запомнить, если ещё едем.
    func noteDrivenFix(_ coordinate: CLLocationCoordinate2D) {
        guard isTripActive, ParkedCar.isDriving(speedKmh: speedKmh) else { return }
        lastDrivenFix = ParkedCar.Fix(lat: coordinate.latitude, lon: coordinate.longitude,
                                      accuracy: horizontalAccuracy)
    }

    /// Новая поездка, выключенная настройка, возвращение к машине.
    func forgetParkedCar() {
        parkedCarRecheck?.cancel()
        parkedCarRecheck = nil
        parkedCar = nil
        if parkedCarOnMap != nil { parkedCarOnMap = nil }
        if parkedCarHint != nil { parkedCarHint = nil }
    }

    /// Пересчитать показ по нынешней позиции. Зовётся на принятом фиксе вне
    /// поездки, при запуске и по таймеру «две минуты ещё не прошли».
    func refreshParkedCar(now: Date = Date()) {
        guard var spot = parkedCar else { return }
        guard !isTripActive, settings.parkedCarHint else {
            if parkedCarOnMap != nil { parkedCarOnMap = nil }
            if parkedCarHint != nil { parkedCarHint = nil }
            return
        }
        // Грубая точка — не повод ни показывать, ни решать «вернулись».
        let here = isPositionCoarse ? nil : currentCoordinate
        let state = spot.update(here: here, now: now)
        if spot != parkedCar { parkedCar = spot }
        parkedCarRecheck?.cancel()
        parkedCarRecheck = nil
        switch state {
        case .expired:
            forgetParkedCar()
        case .hidden(let recheckIn):
            if parkedCarOnMap != nil { parkedCarOnMap = nil }
            if parkedCarHint != nil { parkedCarHint = nil }
            // Стоим за 150 м, а две минуты ещё не прошли: фиксов на месте не
            // будет (distanceFilter) — перепроверить самим.
            if let recheckIn {
                parkedCarRecheck = Task { [weak self] in
                    await Task.pause(seconds: recheckIn + 1)
                    guard !Task.isCancelled else { return }
                    self?.refreshParkedCar()
                }
            }
        case .shown(let meters, let bearing):
            if parkedCarOnMap != spot { parkedCarOnMap = spot }
            let hint = ParkedCar.Hint(meters: meters, bearing: bearing)
            if parkedCarHint != hint { parkedCarHint = hint }
        }
    }
}

extension ParkedCar {
    static func load() -> ParkedCar? {
        guard let data = Storage.data(.parkedCar) else { return nil }
        do {
            return try JSONDecoder().decode(ParkedCar.self, from: data)
        } catch {
            Log.trips.error("точка парковки не прочиталась: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func save(_ spot: ParkedCar?) {
        guard let spot else { Storage.remove(.parkedCar); return }
        do {
            Storage.set(try JSONEncoder().encode(spot), for: .parkedCar)
        } catch {
            Log.trips.error("точка парковки не записалась: \(error.localizedDescription, privacy: .public)")
        }
    }
}
