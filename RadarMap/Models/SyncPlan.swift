//
//  SyncPlan.swift
//  RadarMap
//
//  Какие службы идут в этот выход в сеть (36B, 28.10).
//
//  До этого у каждой службы был свой таймер: отметки водителей 40/70/150 с,
//  пробки 120 с (с «примыканием» к отметкам), погода на перевалах 30 мин,
//  профиль пробок со своим циклом, метан — прицепом к отметкам, «Поделиться
//  прибытием» — POST раз в минуту своим циклом, редкие файлы
//  (пульт, правки, база, треноги, лимиты, дороги, полосы, граф) — каждый на
//  своей активации. Каждый выход в сеть держит сотовое радио в высокой
//  мощности ещё 5–10 с, поэтому стоимость считается в пробуждениях, а не в
//  байтах: два запроса в одном окне дешевле двух окон по запросу.
//
//  Правила:
//  • Ведущие — отметки водителей и пробки: только они открывают окно по
//    времени. В поездке такт = интервал отметок (PollSchedule: 40/70/150 с
//    по скорости, ×2 на жаре — свежесть отметок прежняя), пробки — когда их
//    срок (150 с, без экрана и маршрута 300) подошёл к ближайшему такту, то
//    есть каждый второй такт в городе. Открытый экран без поездки — один
//    такт 150 с для обоих. Подключённая машина без поездки (ручной старт,
//    до автостарта) — лестница поездки (40I): там едут, и тренога, дошедшая
//    на 2–3 мин позже, уже позади.
//  • Попутные — всё остальное. Сами окно по времени не открывают (кроме
//    случая, когда ведущих нет вовсе), едут в окне ведущих, на активации,
//    на возврате связи, на старте поездки и в фоновом подъёме системы.
//    Подошёл ли срок, решает сама служба по своим часам (без сети): её
//    правила, подпись, храповик лимитов, fail-closed — не здесь и не меняются.
//  • Пульт главнее: разреженный им интервал отметок не сужается, выключенная
//    им функция в окно не попадает (её локальную чистку делает исполнитель).
//  • Ошибка — пауза только этой службы (ведущие — интервал × 2^n, попутные —
//    5 мин × 2^(n−1) до часа, тяжёлые — час до суток), такт остальных не
//    сдвигается. Без связи окно
//    не открывается вовсе.
//  • Порядок внутри окна: пульт первым (он может выключить остальное),
//    дальше все разом — APIClient держит одну сессию, то есть одно HTTP/2.
//
//  Оповещения о камерах от этого плана не зависят никак: база на телефоне,
//  предупреждение работает без сети (ARCHITECTURE.md, правило 20).
//
//  Чистая логика без часов и сети — NetSchedulerTests.
//

import Foundation

nonisolated enum SyncPlan {

    enum Job: String, CaseIterable, Sendable, Hashable, Comparable {
        // Ведущие: открывают окно по времени.
        case mobile, traffic
        // Своя очередь отметок без сети: попутная без зрителя — обещанное
        // «отправлю позже» уходит и после поездки, с телефоном в кармане.
        case reports
        // Попутные частые: нужны тому, кто смотрит или едет.
        case roadWeather, trafficProfile, cng, offlineRoute, etaShare
        // Попутные редкие файлы.
        case remoteConfig, cameraDB, hotspots, speedLimits, roads, laneOverlay, offlineGraph

        var isDriver: Bool { self == .mobile || self == .traffic }

        /// Нужна только экрану, машине или поездке — в фоновом подъёме без
        /// поездки её не будим.
        var needsAudience: Bool {
            switch self {
            case .roadWeather, .trafficProfile, .cng, .offlineRoute, .etaShare: true
            default: false
            }
        }

        /// Мегабайты, а не килобайты: не в коротком фоновом окне системы
        /// (~30 с), где загрузку оборвут на середине.
        var isHeavy: Bool {
            switch self {
            case .speedLimits, .roads, .laneOverlay, .offlineGraph: true
            default: false
            }
        }

        static func < (lhs: Job, rhs: Job) -> Bool {
            // Пульт — первым, дальше в порядке объявления.
            func rank(_ job: Job) -> Int {
                job == .remoteConfig ? -1 : allCases.firstIndex(of: job) ?? 0
            }
            return rank(lhs) < rank(rhs)
        }
    }

    enum Mode: Sendable, Equatable {
        /// Идёт поездка (экран может быть погашен).
        case trip
        /// Поездки нет, но на карту смотрят: телефон или машина.
        case watching
        /// Ни поездки, ни экрана: своих тактов нет.
        case idle
    }

    enum Trigger: Sendable, Equatable {
        /// Срок по таймеру.
        case tick
        /// Запуск, возврат в приложение, подключение машины.
        case activation
        /// Связь вернулась.
        case online
        /// Поездка началась: список отметок нужен сейчас, а не через такт.
        case tripStart
        /// Фоновый подъём системы (BGAppRefresh): только лёгкие файлы.
        case background
    }

    struct Situation: Sendable, Equatable {
        var now: Date
        var mode: Mode
        var isOnline = true
        /// Телефон на переднем плане или подключена машина.
        var screenOn = false
        /// Подключена машина (CarPlay).
        var carConnected = false
        var hasRoute = false
        var speedKmh: Double = 0
        var thermal: PerformanceMode = .full
        /// Интервал отметок из пульта (nil — пульта нет).
        var remotePollInterval: TimeInterval?
        /// Интервал пробок из пульта: только разрежает (nil — как в сборке).
        var remoteTrafficInterval: TimeInterval?
        /// Выключено пультом или настройкой.
        var disabled: Set<Job> = []
        /// Попутные, чей срок по часам самой службы подошёл.
        var riderDue: Set<Job> = []
    }

    /// Память исполнителя о службе.
    struct Track: Sendable, Equatable {
        var lastAttempt: Date?
        var failures = 0
    }

    struct Decision: Sendable, Equatable {
        /// В этом окне — по порядку (пульт первым).
        var jobs: [Job]
        /// Когда снова посмотреть (с); nil — своих тактов нет.
        var nextCheck: TimeInterval?
    }

    // MARK: - Интервалы ведущих

    /// Интервал ведущей службы в этом режиме; nil — сейчас не нужна.
    static func interval(_ job: Job, _ s: Situation) -> TimeInterval? {
        switch (job, s.mode) {
        case (_, .idle):
            return nil
        case (.mobile, .trip):
            return PollSchedule.interval(isTripActive: true, speedKmh: s.speedKmh,
                                         thermal: s.thermal, remoteBaseline: s.remotePollInterval)
        case (.mobile, .watching) where s.carConnected:
            // Машина подключена, поездки нет (40I): за рулём, хоть и без
            // «Поездки», — отметки по той же лестнице, что в поездке. Стоя —
            // её верхняя ступень (150 с), то есть такт экрана. Пульт главнее
            // в обе стороны: разредил — его интервал (это решает лестница),
            // ужал — не реже его, как у экрана без машины.
            let ladder = PollSchedule.interval(isTripActive: true, speedKmh: s.speedKmh,
                                               thermal: s.thermal, remoteBaseline: s.remotePollInterval)
            guard let remote = s.remotePollInterval, remote < AppConfig.mobilePollInterval else { return ladder }
            let narrowed = s.thermal >= .reduced ? remote * AppConfig.mobilePollThermalFactor : remote
            return min(ladder, narrowed)
        case (.mobile, .watching):
            let remote = s.remotePollInterval ?? AppConfig.mobilePollInterval
            // Пульт разредил — слушаемся; ужал — тоже (его право); иначе такт экрана.
            var interval = remote > AppConfig.mobilePollInterval ? remote : min(remote, AppConfig.netWatchInterval)
            if s.thermal >= .reduced { interval *= AppConfig.mobilePollThermalFactor }
            return interval
        case (.traffic, _):
            let own = s.screenOn || s.hasRoute ? AppConfig.trafficRefreshInterval : AppConfig.trafficQuietInterval
            return max(own, s.remoteTrafficInterval ?? 0)
        default:
            return nil
        }
    }

    /// Насколько раньше срока ведущая может прыгнуть в уже открытое окно:
    /// 30 с, но не больше четверти интервала (иначе опрос раз в 40 с на
    /// трассе превратился бы в раз в 30).
    static func joinSlack(_ interval: TimeInterval) -> TimeInterval {
        min(AppConfig.radioJoinSlackSeconds, interval / 4)
    }

    /// Пауза после сбоев отметок снимается, когда связь вернулась или
    /// человек открыл приложение: она меряла мёртвую сеть, а не сервер. Без
    /// этого после трёх таймаутов «связь есть» опрос шёл раз в 320 с (а при
    /// открытом экране — в 1200), и ни чужих треног, ни досылки своей.
    static func forgiven(_ tracks: [Job: Track], trigger: Trigger) -> [Job: Track] {
        guard trigger == .online || trigger == .activation else { return tracks }
        var result = tracks
        for (job, track) in tracks where (job.isDriver || job == .reports) && track.failures > 0 {
            result[job]?.failures = 0
        }
        return result
    }

    /// Пауза ведущей после n сбоев подряд.
    static func driverPause(interval: TimeInterval, failures: Int) -> TimeInterval {
        guard failures > 0 else { return interval }
        return interval * pow(2, Double(min(failures, AppConfig.netDriverBackoffMaxExponent)))
    }

    /// Пауза попутной после n сбоев подряд (срок так и остался подошедшим).
    /// Лёгкие — 5 мин, дальше вдвое, до часа; тяжёлые — час, до суток:
    /// сломанный на сервере набор лимитов (3,4 МБ) не должен качаться по
    /// сотовой каждые несколько тактов поездки.
    static func riderPause(_ job: Job, failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let base = job.isHeavy ? AppConfig.netHeavyRetryBaseSeconds : AppConfig.netRiderRetryBaseSeconds
        let cap = job.isHeavy ? AppConfig.netHeavyRetryMaxSeconds : AppConfig.netRiderRetryMaxSeconds
        return min(base * pow(2, Double(failures - 1)), cap)
    }

    // MARK: - План окна

    static func plan(_ s: Situation, tracks: [Job: Track], trigger: Trigger) -> Decision {
        let drivers = Job.allCases.filter(\.isDriver)
        // Ведущие, которые вообще нужны сейчас: режим + не выключены.
        let wanted = drivers.compactMap { job -> (Job, TimeInterval)? in
            guard !s.disabled.contains(job), let interval = interval(job, s) else { return nil }
            return (job, interval)
        }
        let next = nextCheck(s, wanted: wanted, tracks: tracks)
        // Без связи срок ведущих не сдвигается (попыток нет), и «к ближайшему
        // сроку» значило бы пробуждение каждую секунду, пока связи нет.
        guard s.isOnline else {
            return Decision(jobs: [], nextCheck: s.mode == .idle ? nil : AppConfig.netSchedulerStepSeconds)
        }

        func since(_ job: Job) -> TimeInterval {
            guard let at = tracks[job]?.lastAttempt else { return .infinity }
            return s.now.timeIntervalSince(at)
        }
        func pause(_ job: Job, _ interval: TimeInterval) -> TimeInterval {
            driverPause(interval: interval, failures: tracks[job]?.failures ?? 0)
        }

        // Открывается ли окно: по таймеру — только когда срок ведущей вышел
        // строго; любой другой повод — окно уже есть.
        let strictlyDue = wanted.filter { since($0.0) >= pause($0.0, $0.1) }.map(\.0)
        var jobs: [Job] = []
        for (job, interval) in wanted {
            let forced = trigger == .tripStart && job == .mobile && (tracks[job]?.failures ?? 0) == 0
            if forced || since(job) >= pause(job, interval) - joinSlack(interval) {
                jobs.append(job)
            }
        }

        let riders = Job.allCases.filter { job in
            guard !job.isDriver, s.riderDue.contains(job), !s.disabled.contains(job) else { return false }
            if job.needsAudience, s.mode == .idle { return false }
            if job.isHeavy, trigger == .background { return false }
            if let track = tracks[job], track.failures > 0, let at = track.lastAttempt,
               s.now.timeIntervalSince(at) < riderPause(job, failures: track.failures) { return false }
            return true
        }

        let windowOpens: Bool
        switch trigger {
        case .tick where s.mode == .idle:
            // Без поездки и экрана своих тактов нет вовсе.
            windowOpens = false
        case .tick:
            // Ведущих нет вовсе (пульт выключил обе) — попутные открывают
            // окно сами, иначе экран без отметок и пробок не видел бы и
            // погоды на перевалах. Есть ведущие — только их срок.
            windowOpens = wanted.isEmpty ? !riders.isEmpty : !strictlyDue.isEmpty
        case .activation, .online, .tripStart, .background:
            windowOpens = true
        }
        guard windowOpens else { return Decision(jobs: [], nextCheck: next) }
        // Окно по таймеру без единой ведущей в нём (обе на паузе после сбоя)
        // попутных не везёт — иначе пауза ведущих будила бы радио ради них.
        if trigger == .tick, !wanted.isEmpty, jobs.isEmpty { return Decision(jobs: [], nextCheck: next) }
        return Decision(jobs: (jobs + riders).sorted(), nextCheck: next)
    }

    /// Когда снова посмотреть: к ближайшему строгому сроку ведущей, но не
    /// реже шага (режим, скорость и нагрев меняются на ходу).
    private static func nextCheck(_ s: Situation, wanted: [(Job, TimeInterval)],
                                  tracks: [Job: Track]) -> TimeInterval? {
        guard s.mode != .idle else { return nil }
        let step = AppConfig.netSchedulerStepSeconds
        let waits = wanted.map { job, interval -> TimeInterval in
            guard let at = tracks[job]?.lastAttempt else { return 0 }
            let due = driverPause(interval: interval, failures: tracks[job]?.failures ?? 0)
            return due - s.now.timeIntervalSince(at)
        }
        guard let soonest = waits.min() else { return step }
        return min(max(soonest, 1), step)
    }
}
