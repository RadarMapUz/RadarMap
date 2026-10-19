//
//  CommuteLiveService.swift
//  RadarMap
//
//  Призрак дороги на работу на ходу (этап 8.8.2): сессия CommuteLiveSession
//  на фиксах поездки, наружу — одна строка «Работа · 9:12 · +4 мин».
//  Наблюдаемое меняется только со сменой минуты прибытия или отклонения:
//  панель поездки не пересобирается на каждом фиксе.
//
//  Всё на телефоне: профиль — из CommuteProfileStore, на сервер ни дом, ни
//  работа, ни время выезда не уходят.
//

import CoreLocation
import Foundation
import os

@MainActor
@Observable
final class CommuteLiveService {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    struct Display: Equatable, Sendable {
        let direction: Commute.Direction
        /// Прибытие, округлённое вниз до минуты.
        let arrival: Date
        /// Отклонение от обычного всего пути, мин (0 — «как обычно»).
        let deltaMinutes: Int
    }

    private(set) var display: Display?

    @ObservationIgnored private var session: CommuteLiveSession?
    @ObservationIgnored private var direction: Commute.Direction?
    @ObservationIgnored private var announcer = CommuteGhost.Announcer()
    /// Фраза призрака (8.7) — голос решает, можно ли сейчас говорить
    /// (оповещение о камере и манёвр важнее).
    @ObservationIgnored var onAnnounce: ((String) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onAnnounce,
                                               "CommuteLiveService.onAnnounce") }
    }

    var isRunning: Bool { session != nil }

    /// Начать сессию: направление решено по месту старта, варианты — из
    /// профиля. Нет базы — тихо ничего (призрак не обязателен).
    func start(direction: Commute.Direction, variants: [CommuteProfile.Variant], departure: Date,
               calendar: Calendar = .current) {
        stop()
        guard let session = CommuteLiveSession(variants: variants,
                                               weekend: calendar.isDateInWeekend(departure),
                                               departure: departure, calendar: calendar)
        else { return }
        self.session = session
        self.direction = direction
        announcer = CommuteGhost.Announcer()
        Log.trips.info("призрак: \(direction.rawValue, privacy: .public), вариантов \(variants.count, privacy: .public)")
    }

    func note(_ coordinate: CLLocationCoordinate2D, accuracy: Double, at now: Date) {
        guard var session, let direction else { return }
        let output = session.note(lat: coordinate.latitude, lon: coordinate.longitude,
                                  accuracy: accuracy, at: now)
        self.session = session
        if output.isOff {
            // «Сегодня другой дорогой»: прогноз и голос молчат до возврата.
            if display != nil { display = nil }
            return
        }
        guard let forecast = output.forecast else { return }
        let minute = (forecast.arrival.timeIntervalSince1970 / 60).rounded(.down) * 60
        let next = Display(direction: direction, arrival: Date(timeIntervalSince1970: minute),
                           deltaMinutes: forecast.deltaMinutes)
        if next != display {
            display = next
            if announcer.shouldSpeak(deltaMinutes: next.deltaMinutes,
                                     remainingMeters: output.remainingMeters, now: now) {
                onAnnounce?(CommuteGhost.phrase(direction: direction, arrival: next.arrival,
                                                deltaMinutes: next.deltaMinutes))
            }
        }
    }

    #if DEBUG
    /// Скриншот-хук `-demoGhost`: строка призрака без настоящей истории.
    func showDemo(direction: Commute.Direction, arrival: Date, deltaMinutes: Int) {
        display = Display(direction: direction, arrival: arrival, deltaMinutes: deltaMinutes)
    }
    #endif

    func stop() {
        session = nil
        direction = nil
        if display != nil { display = nil }
    }

    /// Направление по месту старта: у дома — на работу, у работы — домой.
    nonisolated static func direction(start: CLLocationCoordinate2D,
                                      home: CLLocationCoordinate2D,
                                      work: CLLocationCoordinate2D,
                                      radius: CLLocationDistance = AppConfig.commuteGhostStartRadiusMeters)
        -> Commute.Direction? {
        let toHome = GeoMath.fastDistance(start.latitude, start.longitude, home.latitude, home.longitude)
        let toWork = GeoMath.fastDistance(start.latitude, start.longitude, work.latitude, work.longitude)
        if toHome <= radius, toHome < toWork { return .toWork }
        if toWork <= radius, toWork < toHome { return .toHome }
        return nil
    }
}
