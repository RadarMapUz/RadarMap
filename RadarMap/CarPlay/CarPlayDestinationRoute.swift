//
//  CarPlayDestinationRoute.swift
//  RadarMap
//
//  Маршрут к месту из машины — одно на обе сцены: «Куда» основного экрана
//  (CarPlaySceneDelegate+Destinations) и ярлыки «Дом»/«Работа» плитки
//  главного экрана машины (CarPlayDashboardSceneDelegate).
//
//  До 22.10 плитка держала свою копию: выбор «ручное → выученное», «обычно
//  N мин» и само построение — и без защиты от двойного касания: два тапа
//  «Дом» давали два `route.build` и два запроса OSRM (отчёт качества 22.10,
//  п. 3). Теперь защита одна на обе сцены — касание «Дом» на плитке, пока тот
//  же маршрут строится с основного экрана, тоже не уходит вторым запросом.
//

import CoreLocation
import Foundation
import os

/// Куда ведёт слот «Дом»/«Работа»: заданный руками адрес или выученное по
/// поездкам место (FrequentPlaces). Ручной адрес всегда старше догадки.
enum CarPlaySlotTarget: Equatable {
    case manual(SavedPlace)
    case learned(SavedPlace)

    var saved: SavedPlace {
        switch self {
        case .manual(let place), .learned(let place): return place
        }
    }

    /// Писать ли цель в «недавние». Выученное — нет: оно двигается с
    /// привычками и забывается выключателем, а запись осталась бы вторым «Домом».
    var remembers: Bool {
        if case .manual = self { return true }
        return false
    }

    static func resolve(_ slot: PlaceSlot, manual: SavedPlace?,
                        learned: [FrequentPlaces.Place]) -> CarPlaySlotTarget? {
        if let manual { return .manual(manual) }
        guard let place = learned.first(where: { $0.kind.rawValue == slot.rawValue }) else { return nil }
        return .learned(SavedPlace(title: slot.name, lat: place.lat, lon: place.lon))
    }

    /// «обычно 39 мин» — медиана своих поездок туда (Commute), без сети: в
    /// машине это ответ на «сколько ехать» до касания.
    static func usual(_ slot: PlaceSlot, commute: [Commute.Summary]) -> String? {
        commute.first { $0.direction == (slot == .work ? .toWork : .toHome) }?.usual
            .map { String(format: String(localized: "обычно %@"), Formatting.duration($0)) }
    }
}

/// Один маршрут к одной цели за раз: повторное касание, пока он строится, —
/// не второй запрос. Чистое — CarPlayDestinationRouteTests.
struct CarPlayTapGuard {
    private var inFlight: Set<String> = []

    /// true — можно строить; false — к этой цели уже строится.
    mutating func begin(_ key: String) -> Bool { inFlight.insert(key).inserted }
    mutating func end(_ key: String) { inFlight.remove(key) }

    static func routeKey(_ place: SavedPlace) -> String { "route:\(place.lat),\(place.lon)" }
}

/// Что делать, когда маршрут из «Куда» достроился. Пока он строится, в баре
/// одна «Отмена»; нажатая в эти секунды, она снимала выбор, а поездка всё равно
/// начиналась. Чистое — CarPlayDestinationRouteTests.
nonisolated enum CarPlayBuiltChoice: Equatable, Sendable {
    /// Показать выбор варианта.
    case showChoice
    /// Выбора не просили или показать нечего: едем.
    case startTrip
    /// Водитель отменил, пока строился, или машину отключили.
    case nothing

    static func decide(wantedChoice: Bool, stillChoosing: Bool, hasRoute: Bool, failed: Bool) -> CarPlayBuiltChoice {
        guard wantedChoice else { return .startTrip }
        guard stillChoosing else { return .nothing }
        return hasRoute && !failed ? .showChoice : .startTrip
    }
}

/// Построение маршрута из машины: точный фикс → маршрут → «недавние» →
/// поездка. Что показать водителю при отказе, решает сцена (у основного
/// экрана — диалог, у плитки — голос: своих диалогов у неё нет).
@MainActor
enum CarPlayRouteRequest {
    enum Outcome: Equatable {
        /// К этой цели маршрут уже строится — касание повторное.
        case busy
        /// Нет точного фикса: маршрут от грубой точки начался бы за километры
        /// (plan_drive_complaints.md, Ж5).
        case noFix
        /// Построен; поездка идёт (или ждёт «Поехали» на выборе варианта).
        case built
        /// Не построился — текст ошибки маршрутизатора.
        case failed(String)
    }

    /// Общая защита обеих сцен.
    private static var taps = CarPlayTapGuard()

    /// - Parameters:
    ///   - prepare: после фикса, до построения; возвращает, нужны ли
    ///     альтернативы (выбор варианта стоя — у основного экрана).
    ///   - startsTrip: после построения; false — поездку пока не начинать
    ///     (сцена показала выбор варианта, поездка — по «Поехали»).
    static func run(env: AppEnvironment, to place: SavedPlace, remember: Bool,
                    prepare: () -> Bool = { false },
                    startsTrip: () -> Bool = { true }) async -> Outcome {
        let key = CarPlayTapGuard.routeKey(place)
        guard taps.begin(key) else {
            Log.carplay.notice("повторное касание — маршрут уже строится")
            return .busy
        }
        defer { taps.end(key) }
        guard let from = await env.location.awaitPreciseCoordinate() else { return .noFix }
        let alternatives = prepare()
        // На ходу — по курсу (20.9); стоя (выбор варианта) курса нет.
        await env.route.build(from: from, heading: env.location.routeHeading,
                              to: place.coordinate, name: place.title,
                              cameras: env.cameras.cameras, alternatives: alternatives)
        if remember { env.settings.addRecent(title: place.title, lat: place.lat, lon: place.lon) }
        guard startsTrip() else { return .built }
        // Едем уже с активной поездкой — не обнулять её накат.
        if !env.location.isTripActive { env.location.startTrip() }
        if let error = env.route.errorMessage { return .failed(error) }
        return .built
    }
}
