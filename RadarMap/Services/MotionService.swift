//
//  MotionService.swift
//  RadarMap
//
//  Автоопределение вождения (Core Motion) — чтобы поездка включалась и гасла сама.
//  Батарея: непрерывный GPS живёт только пока реально едем, без действий пользователя.
//

import Foundation
import CoreMotion
import Observation

@MainActor
@Observable
final class MotionService {

    /// Снос — БЕЗ прыжка на актор, и это не стиль, а обход живого бага рантайма.
    ///
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor синтезирует isolated deinit
    /// каждому @MainActor-классу, даже когда своего deinit нет. Такой deinit
    /// уходит в swift_task_deinitOnExecutor, тот в синхронном кадре главного
    /// потока (текущей Task нет) заводит TaskLocal::StopLookupScope, а
    /// MarkerItem::create в рантайме iOS 26 берёт память у task-аллокатора
    /// БЕЗУСЛОВНО — при task == nullptr это статический слэб внутри
    /// libswift_Concurrency. Item::destroy потом зовёт free() по этому
    /// указателю: «pointer being freed was not allocated» → SIGABRT.
    ///
    /// Условия сходятся ровно там, где SwiftUI сносит вью с @State-моделью
    /// внутри GraphHost.runTransaction: там жива task-local привязка. В ветке
    /// main рантайма баг уже исправлен; до выхода такой iOS помогает одно —
    /// не синтезировать isolated deinit вовсе.
    nonisolated deinit {}
    private let manager = CMMotionActivityManager()
    private let settings: AppSettings

    private(set) var isDriving = false

    /// Колбэки — вешает AppEnvironment/RootView (старт/стоп поездки).
    @ObservationIgnored var onDrivingStart: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onDrivingStart,
                                               "MotionService.onDrivingStart") }
    }
    @ObservationIgnored var onDrivingStop: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onDrivingStop,
                                               "MotionService.onDrivingStop") }
    }

    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var isMonitoring = false

    static var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }

    init(settings: AppSettings) { self.settings = settings }

    func start() {
        guard Self.isAvailable, !isMonitoring, settings.tripStartMode.usesMotion else { return }
        isMonitoring = true
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            Task { @MainActor in self.handle(activity) }
        }
    }

    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        stopTask?.cancel(); stopTask = nil
        startTask?.cancel(); startTask = nil
        manager.stopActivityUpdates()
    }

    /// Перечитать настройку (сменили режим старта поездки).
    func syncEnabled() {
        settings.tripStartMode.usesMotion ? start() : stop()
    }

    private func beginDriving() {
        guard !isDriving else { return }
        isDriving = true
        onDrivingStart?()
    }

    private func handle(_ activity: CMMotionActivity) {
        let drivingNow = activity.automotive && activity.confidence != .low

        if drivingNow {
            stopTask?.cancel(); stopTask = nil
            guard !isDriving else { return }
            // Против ложных стартов (тряска пешком, автобус на секунду): high — сразу,
            // medium — только если «за рулём» держится подтверждающую паузу подряд.
            // Любой не-automotive сэмпл в ожидании отменяет старт.
            if activity.confidence == .high {
                startTask?.cancel(); startTask = nil
                beginDriving()
            } else if startTask == nil {
                startTask = Task { [weak self] in
                    await Task.pause(seconds: AppConfig.autoStartConfirmSeconds)
                    guard let self, !Task.isCancelled else { return }
                    self.startTask = nil
                    self.beginDriving()
                }
            }
        } else if !isDriving, !activity.automotive {
            // Вышли из машины/идём — ожидающий старт больше не актуален.
            startTask?.cancel(); startTask = nil
        } else if isDriving, activity.stationary || activity.walking || activity.running || activity.cycling {
            // Не гасим сразу — вдруг светофор/пробка. Ждём устойчивую остановку.
            guard stopTask == nil else { return }
            stopTask = Task { [weak self] in
                await Task.pause(seconds: AppConfig.autoStopAfterSeconds)
                guard let self, !Task.isCancelled else { return }
                self.isDriving = false
                self.stopTask = nil
                self.onDrivingStop?()
            }
        }
    }
}
