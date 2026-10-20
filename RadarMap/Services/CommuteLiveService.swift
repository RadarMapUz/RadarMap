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
        /// Прибытие, округлённое до ближайшей минуты.
        let arrival: Date
        /// Отклонение от обычного всего пути, мин (0 — «как обычно»).
        let deltaMinutes: Int
        /// Запас до срока «быть к 9:00»; nil — срока нет (или не сегодня).
        var slack: CommuteGhost.TargetSlack?
        /// Почему дольше — одним словом (8.8.12); nil — причины не видно.
        var reason: CommuteGhost.Reason? = nil
    }

    private(set) var display: Display?
    /// Плашку «опаздываю — предупредить?» (8.8.14) в этой поездке уже закрыли
    /// или использовали: она одна на поездку.
    private(set) var latePlaqueDone = false
    /// Плашку уже показали — дальше она держится, пока не закроют, не
    /// отправят или не истечёт её время, а не мигает на каждом «стоим/едем».
    private(set) var latePlaqueShown = false

    func dismissLatePlaque() { latePlaqueDone = true }
    func markLatePlaqueShown() { if !latePlaqueShown { latePlaqueShown = true } }

    /// Показывать ли плашку «опаздываю» (8.8.14): только со сроком и когда
    /// показано «позже срока», стоя (лист «Поделиться» на ходу — помеха за
    /// рулём), не под оповещением о камере и один раз за поездку. Сама
    /// никогда ничего не отправляет и «поторопитесь» не говорит.
    nonisolated static func showsLatePlaque(slack: CommuteGhost.Slack?, done: Bool, shown: Bool = false,
                                            speedKmh: Double, coveredByCamera: Bool) -> Bool {
        guard slack == .late, !done, !coveredByCamera else { return false }
        // Появляется стоя; показанная — держится (не мигает в «едем-стоим»).
        return shown || speedKmh < AppConfig.commuteLatePromptMaxKmh
    }

    @ObservationIgnored private var session: CommuteLiveSession?
    @ObservationIgnored private var direction: Commute.Direction?
    @ObservationIgnored private var announcer = CommuteGhost.Announcer()
    @ObservationIgnored private var deadline: Date?
    @ObservationIgnored private var slackTracker = CommuteGhost.SlackTracker()
    @ObservationIgnored private var lateNotice = CommuteGhost.LateNotice()
    @ObservationIgnored private var sessionDeparture: Date?
    /// Ревизия пробок, уже отданная сессии; −1 — новой сессии пробки не давали.
    @ObservationIgnored private var trafficRevision = -1
    /// Маршрут, для которого посчитано совпадение с вариантами (8.8.11).
    @ObservationIgnored private var routeKey: ObjectIdentifier?
    @ObservationIgnored private var routeMatches: Set<Int> = []
    /// Последний прогноз ведущего варианта: остаток, когда посчитан, кто вёл.
    @ObservationIgnored private var lastForecast: (remaining: TimeInterval, at: Date, lead: Int)?
    /// Фраза призрака (8.7) — голос решает, можно ли сейчас говорить
    /// (оповещение о камере и манёвр важнее); true — сказана. Несказанная
    /// не засчитывается и прозвучит на следующем пересчёте.
    @ObservationIgnored var onAnnounce: ((String) -> Bool)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onAnnounce,
                                               "CommuteLiveService.onAnnounce") }
    }

    var isRunning: Bool { session != nil }

    /// Начать сессию: направление решено по месту старта, варианты — из
    /// профиля. Нет базы — тихо ничего (призрак не обязателен). `deadline` —
    /// срок «быть к» на сегодня (ArrivalTarget.deadline), иначе nil.
    /// `workday` — суббота шестидневки (срок «и по субботам»): её поездки
    /// сравниваются с будними, а не с воскресными.
    func start(direction: Commute.Direction, variants: [CommuteProfile.Variant], departure: Date,
               deadline: Date? = nil, workday: Bool = false, calendar: Calendar = .current) {
        // Та же поездка, продолженная после остановки (TripMerge), — голос
        // помнит, что уже сказал: иначе «позже срока» звучало бы после
        // каждого заезда.
        let resumed = departure == sessionDeparture
        stop()
        guard let session = CommuteLiveSession(variants: variants,
                                               weekend: !workday && UzHolidays.isDayOff(departure, calendar: calendar),
                                               departure: departure, calendar: calendar)
        else {
            Log.trips.info("призрак: \(direction.rawValue, privacy: .public) — мало поездок этого часа и дня (вариантов \(variants.count, privacy: .public), строк \(variants.reduce(0) { $0 + $1.rows.count }, privacy: .public))")
            return
        }
        self.session = session
        self.direction = direction
        self.deadline = deadline
        trafficRevision = -1
        routeKey = nil
        routeMatches = []
        lastForecast = nil
        sessionDeparture = departure
        slackTracker = CommuteGhost.SlackTracker()
        if !resumed {
            announcer = CommuteGhost.Announcer()
            lateNotice = CommuteGhost.LateNotice()
            latePlaqueDone = false
            latePlaqueShown = false
        }
        Log.trips.info("призрак: \(direction.rawValue, privacy: .public), вариантов \(variants.count, privacy: .public)")
    }

    /// Построенный маршрут (8.8.11): совпадает с вариантом дороги на работу —
    /// его остаток считает призрак. Считается один раз на маршрут (`key` —
    /// линия маршрута), координаты берутся, только если маршрут сменился.
    func noteRoute(key: ObjectIdentifier?, coordinates: @autoclosure () -> [CLLocationCoordinate2D]?) {
        guard key != routeKey else { return }
        routeKey = key
        routeMatches = key == nil ? [] : (coordinates().flatMap { session?.matchingCandidates(route: $0) } ?? [])
    }

    /// Остаток пути по призраку для маршрута (8.8.11) — прогноз ведущего
    /// варианта минус прошедшее с пересчёта; nil — маршрут не по своей
    /// дороге, прогноза нет или сошли: тогда маршрут считает сам.
    func routeRemaining(now: Date) -> TimeInterval? {
        guard display != nil, let forecast = lastForecast, routeMatches.contains(forecast.lead) else { return nil }
        // Без свежих фиксов (стоим с погашенным экраном — фильтр по расстоянию
        // не даёт их) прогноз не тает до нуля: маршрут считает сам и честно
        // сдвигает прибытие.
        let age = now.timeIntervalSince(forecast.at)
        guard age <= AppConfig.commuteRouteForecastMaxAge else { return nil }
        return max(0, forecast.remaining - age)
    }

    /// Пробки для прогноза (8.8.10): новый файл `now.json` — в сессию; тот же
    /// (ревизия не сменилась) — ничего. Зовётся на фиксах поездки.
    func noteTraffic(_ snapshot: TrafficSnapshot?, revision: Int, now: Date) {
        guard session != nil, revision != trafficRevision else { return }
        trafficRevision = revision
        session?.setTraffic(snapshot, now: now)
    }

    func note(_ coordinate: CLLocationCoordinate2D, accuracy: Double, at now: Date) {
        guard var session, let direction else { return }
        let output = session.note(lat: coordinate.latitude, lon: coordinate.longitude,
                                  accuracy: accuracy, at: now)
        self.session = session
        if output.isOff || !output.hasLead {
            // «Сегодня другой дорогой» или ведущий сошёл, а другой путь ещё
            // не подтверждён: прогноз и голос молчат до возврата.
            if display != nil {
                display = nil
                Log.trips.info("призрак: \(output.isOff ? "другой дорогой" : "ведущий сошёл", privacy: .public) — прогноз скрыт")
            }
            lastForecast = nil
            return
        }
        guard let forecast = output.forecast else { return }
        lastForecast = (forecast.remaining, now, session.active ?? -1)
        // Журнал прогноза (В5, 8.8.9): на каждом пересчёте — раз в участок
        // или в 30 с. Без координат: остаток пути, прибытие и отклонение.
        Log.trips.info("призрак: осталось \(Int(output.remainingMeters), privacy: .public) м, \(Int(forecast.remaining), privacy: .public) с, прибытие \(CommuteGhost.clock(forecast.arrival), privacy: .public), к обычному \(Int(forecast.delta), privacy: .public) с, разброс \(Int(forecast.sigma), privacy: .public) с")
        let minute = (forecast.arrival.timeIntervalSince1970 / 60).rounded() * 60
        let raw = deadline.map { ArrivalTarget.slackMinutes(deadline: $0, arrival: forecast.arrival) }
        let slack: CommuteGhost.TargetSlack? = Self.all(slackTracker.update(slackMinutes: raw, now: now), raw, deadline)
            .map { CommuteGhost.TargetSlack(state: $0, minutes: Int($1.rounded()), deadline: $2) }
        let next = Display(direction: direction, arrival: Date(timeIntervalSince1970: minute),
                           deltaMinutes: forecast.deltaMinutes, slack: slack, reason: output.reason)
        if next != display { display = next }
        // Голос — на каждом пересчёте (≤ раз в 30 с), а не только при смене
        // строки: фраза, отложенная из-за камеры, не ждёт сдвига на 3 мин.
        // Позже срока — своё правило: один раз и снова, только если хуже на 5 мин.
        let late = slack?.shown == .late ? slack?.lateMinutes : nil
        let wants = late.map {
            lateNotice.wants(lateMinutes: $0)
                && announcer.allowsLate(remainingMeters: output.remainingMeters, now: now)
        } ?? announcer.wants(deltaMinutes: next.deltaMinutes, remainingMeters: output.remainingMeters, now: now)
        if wants, onAnnounce?(CommuteGhost.phrase(direction: direction, arrival: next.arrival,
                                                  deltaMinutes: next.deltaMinutes, slack: slack)) == true {
            announcer.commit(deltaMinutes: next.deltaMinutes, now: now)
            if let late { lateNotice.commit(lateMinutes: late) }
        }
    }

    /// Три необязательных — вместе или ничего.
    private static func all<A, B, C>(_ a: A?, _ b: B?, _ c: C?) -> (A, B, C)? {
        guard let a, let b, let c else { return nil }
        return (a, b, c)
    }

    #if DEBUG
    /// Скриншот-хук `-demoGhost`: строка призрака без настоящей истории.
    func showDemo(direction: Commute.Direction, arrival: Date, deltaMinutes: Int,
                  slack: CommuteGhost.TargetSlack? = nil) {
        display = Display(direction: direction, arrival: arrival, deltaMinutes: deltaMinutes, slack: slack)
    }
    #endif

    func stop() {
        session = nil
        direction = nil
        deadline = nil
        routeKey = nil
        routeMatches = []
        lastForecast = nil
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
