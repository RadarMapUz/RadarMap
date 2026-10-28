//
//  NetScheduler.swift
//  RadarMap
//
//  Исполнитель плана сети (36B, 28.10): один таймер на всё приложение.
//  Что и когда — решает SyncPlan (чистый, протестирован), здесь только
//  часы, память о попытках и вызов служб. Службы своих таймеров больше не
//  держат; как они грузят, проверяют подпись (SignedPayload), храповик
//  лимитов и fail-closed — их дело, как и было.
//
//  Оповещения о камерах сюда не ходят и от него не зависят.
//

import Foundation
import os

@MainActor
final class NetScheduler {
    /// Служба для планировщика.
    struct Lane {
        /// Сходить в сеть. Ведущие отвечают, удалось ли (для паузы после
        /// сбоя); ответ попутных не читается — их сбой виден по сроку.
        let run: @MainActor () async -> Bool
        /// Попутные: подошёл ли срок по часам самой службы (без сети).
        let isDue: (@MainActor () -> Bool)?
        /// Выключено пультом или настройкой: снять показанное (без сети).
        let whenDisabled: (@MainActor () -> Void)?
        /// Сбой попутной ставит её на паузу. false — служба, которой пауза
        /// хуже повтора в следующем такте (живая ссылка прибытия).
        let pausesOnFailure: Bool

        init(run: @escaping @MainActor () async -> Bool,
             isDue: (@MainActor () -> Bool)? = nil,
             whenDisabled: (@MainActor () -> Void)? = nil,
             pausesOnFailure: Bool = true) {
            self.run = run
            self.isDue = isDue
            self.whenDisabled = whenDisabled
            self.pausesOnFailure = pausesOnFailure
        }
    }

    /// Всё о моменте, кроме часов и сроков попутных: режим, связь, скорость,
    /// пульт, выключатели. Ставит AppEnvironment.
    var situation: (() -> SyncPlan.Situation)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: situation,
                                               "NetScheduler.situation") }
    }
    /// Каждый шаг таймера, без сети (снять истёкшие отметки). Ставит AppEnvironment.
    var onStep: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onStep,
                                               "NetScheduler.onStep") }
    }

    private var lanes: [SyncPlan.Job: Lane] = [:]
    private var tracks: [SyncPlan.Job: SyncPlan.Track] = [:]
    private var loop: Task<Void, Never>?
    /// Поколение таймера: старый цикл, доживающий после отмены, не снимет новый.
    private var loopGeneration = 0
    private var running: Task<Void, Never>?
    /// Повод, пришедший, пока окно уже шло: отработать сразу после.
    private var queued: SyncPlan.Trigger?

    /// Подписать службу. Один раз на службу — из AppEnvironment.init.
    func register(_ job: SyncPlan.Job, _ lane: Lane) {
        assert(lanes[job] == nil, "служба \(job) подписана дважды")
        lanes[job] = lane
    }

    // MARK: - Режим и поводы

    /// Режим мог смениться (поездка, экран, машина): завести или погасить таймер.
    func modeChanged() {
        let mode = currentSituation(now: Date()).mode
        if mode == .idle {
            loop?.cancel()
            loop = nil
        } else if loop == nil {
            loopGeneration &+= 1
            let generation = loopGeneration
            loop = Task { [weak self] in await self?.runLoop(generation) }
        }
    }

    /// Внешний повод: окно сейчас — с тем, чей срок подошёл.
    func kick(_ trigger: SyncPlan.Trigger) {
        Task { await window(trigger) }
    }

    /// Окно по поводу, дождаться конца (фоновый подъём системы держит
    /// процесс ровно до возврата).
    func window(_ trigger: SyncPlan.Trigger) async {
        if let running {
            // Окно уже идёт — этот повод отработает следом, одним разом.
            queued = Self.stronger(queued, trigger)
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            var next: SyncPlan.Trigger? = trigger
            while let current = next {
                await self.perform(current)
                next = self.queued
                self.queued = nil
            }
            // Здесь же, без паузы после последней проверки очереди: повод,
            // пришедший позже, уже не застанет «идущее» окно, которое ушло.
            self.running = nil
        }
        running = task
        await task.value
    }

    // MARK: - Таймер

    private func runLoop(_ generation: Int) async {
        while !Task.isCancelled {
            onStep?()
            let now = Date()
            let s = currentSituation(now: now)
            guard s.mode != .idle else { break }
            let decision = SyncPlan.plan(s, tracks: tracks, trigger: .tick)
            if !decision.jobs.isEmpty, running == nil {
                await window(.tick)
            }
            let wait = SyncPlan.plan(currentSituation(now: Date()), tracks: tracks, trigger: .tick).nextCheck
                ?? AppConfig.netSchedulerStepSeconds
            await Task.pause(seconds: wait)
        }
        if generation == loopGeneration { loop = nil }
    }

    // MARK: - Окно

    private func perform(_ trigger: SyncPlan.Trigger) async {
        let now = Date()
        var s = currentSituation(now: now)
        applyDisabled(s.disabled)
        var jobs = SyncPlan.plan(s, tracks: tracks, trigger: trigger).jobs
        guard !jobs.isEmpty else { return }
        Log.network.info("такт сети (\(String(describing: trigger), privacy: .public)): \(jobs.map(\.rawValue).joined(separator: ", "), privacy: .public)")

        // Пульт — первым: он может выключить то, что идёт следом.
        if jobs.first == .remoteConfig {
            jobs.removeFirst()
            await attempt(.remoteConfig, at: now)
            s = currentSituation(now: now)
            applyDisabled(s.disabled)
            jobs.removeAll { s.disabled.contains($0) }
        }
        // Остальные — разом: одна сессия APIClient, одно соединение HTTP/2,
        // одно пробуждение радио.
        await withTaskGroup(of: Void.self) { group in
            for job in jobs {
                group.addTask { @MainActor [weak self] in await self?.attempt(job, at: now) }
            }
        }
    }

    private func attempt(_ job: SyncPlan.Job, at now: Date) async {
        guard let lane = lanes[job] else { return }
        var track = tracks[job] ?? SyncPlan.Track()
        track.lastAttempt = now
        tracks[job] = track
        let ok = await lane.run()
        let failed: Bool
        if job.isDriver {
            failed = !ok
        } else {
            // Срок так и остался подошедшим — служба не получила своё.
            failed = lane.pausesOnFailure && (lane.isDue?() ?? false)
        }
        track.failures = failed ? track.failures + 1 : 0
        tracks[job] = track
        if failed {
            Log.network.notice("такт сети: \(job.rawValue, privacy: .public) не удалось (\(track.failures, privacy: .public) подряд) — пауза службы")
        }
    }

    private func applyDisabled(_ disabled: Set<SyncPlan.Job>) {
        for job in disabled { lanes[job]?.whenDisabled?() }
    }

    private func currentSituation(now: Date) -> SyncPlan.Situation {
        var s = situation?() ?? SyncPlan.Situation(now: now, mode: .idle)
        s.now = now
        s.riderDue = Set(lanes.compactMap { job, lane in
            guard !job.isDriver, lane.isDue?() ?? false else { return nil }
            return job
        })
        return s
    }

    /// Из двух поводов — тот, что берёт больше.
    private static func stronger(_ a: SyncPlan.Trigger?, _ b: SyncPlan.Trigger) -> SyncPlan.Trigger {
        guard let a else { return b }
        func weight(_ t: SyncPlan.Trigger) -> Int {
            switch t {
            case .tick: 0
            case .background: 1
            case .online: 2
            case .activation: 3
            case .tripStart: 4
            }
        }
        return weight(b) > weight(a) ? b : a
    }

    /// Снос без прыжка на актор (см. MotionService).
    nonisolated deinit {}
}
