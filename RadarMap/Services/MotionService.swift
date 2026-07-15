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
    private let manager = CMMotionActivityManager()
    private let settings: AppSettings

    private(set) var isDriving = false

    /// Колбэки — вешает AppEnvironment/RootView (старт/стоп поездки).
    @ObservationIgnored var onDrivingStart: (() -> Void)?
    @ObservationIgnored var onDrivingStop: (() -> Void)?

    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var isMonitoring = false

    static var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }

    init(settings: AppSettings) { self.settings = settings }

    func start() {
        guard Self.isAvailable, !isMonitoring, settings.autoStartTrip else { return }
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
        manager.stopActivityUpdates()
    }

    /// Перечитать настройку (включили/выключили автостарт).
    func syncEnabled() {
        settings.autoStartTrip ? start() : stop()
    }

    private func handle(_ activity: CMMotionActivity) {
        let drivingNow = activity.automotive && activity.confidence != .low

        if drivingNow {
            stopTask?.cancel(); stopTask = nil
            if !isDriving {
                isDriving = true
                onDrivingStart?()
            }
        } else if isDriving, activity.stationary || activity.walking || activity.running || activity.cycling {
            // Не гасим сразу — вдруг светофор/пробка. Ждём устойчивую остановку.
            guard stopTask == nil else { return }
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(AppConfig.autoStopAfterSeconds))
                guard let self, !Task.isCancelled else { return }
                self.isDriving = false
                self.stopTask = nil
                self.onDrivingStop?()
            }
        }
    }
}
