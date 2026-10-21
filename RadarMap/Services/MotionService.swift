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
import os

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
    /// Телефон стоит (CoreMotion уверен в «stationary»). Для сторожа сигнала:
    /// стоим — значит фиксов нет из-за distanceFilter, а не из-за спутников.
    /// Без слежения за движением (ручной старт) — всегда false: «не знаю».
    @ObservationIgnored private(set) var isStationary = false
    /// С какого момента CoreMotion видит езду (startDate первого сэмпла
    /// «в машине» этого старта): автостарт бывает поздним — машина уже
    /// проехала сотни метров, — и склейке после магазина это надо знать (S19).
    @ObservationIgnored private(set) var drivingSince: Date?
    @ObservationIgnored private var pendingSince: Date?
    /// Поездку закрыло прибытие к цели, а CoreMotion всё ещё видит «в машине,
    /// стоим»: следующий старт — только по настоящему движению (ArrivalFinish).
    @ObservationIgnored private var needsMovementToStart = false

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
        isStationary = false
        stopTask?.cancel(); stopTask = nil
        startTask?.cancel(); startTask = nil
        manager.stopActivityUpdates()
    }

    /// Перечитать настройку (сменили режим старта поездки).
    func syncEnabled() {
        settings.tripStartMode.usesMotion ? start() : stop()
    }

    /// Что CoreMotion знает о последних часах — для тихого фона (26.1).
    /// История копится сопроцессором и без слежения (режим «Ручной» и
    /// «Только в машине» тоже), нужна только авторизация: без неё — «не знаем»
    /// (спросить её из фона нельзя, и запрос здесь показал бы диалог).
    func recentMotion(now: Date = Date()) async -> QuietAlertGate.Motion {
        guard Self.isAvailable, CMMotionActivityManager.authorizationStatus() == .authorized else {
            return .unknown
        }
        let from = now.addingTimeInterval(-AppConfig.quietAlertMotionLookbackSeconds)
        let samples: [QuietAlertGate.MotionSample] = await withCheckedContinuation { continuation in
            manager.queryActivityStarting(from: from, to: now, to: .main) { activities, error in
                if let error {
                    Log.location.error("история CoreMotion: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: (activities ?? []).map {
                    QuietAlertGate.MotionSample(start: $0.startDate, automotive: $0.automotive,
                                                walking: $0.walking, running: $0.running,
                                                cycling: $0.cycling, stationary: $0.stationary,
                                                confident: $0.confidence != .low)
                })
            }
        }
        return QuietAlertGate.motion(from: samples, now: now)
    }

    /// Поездку закрыли у цели, пока CoreMotion считает, что мы едем (стоим с
    /// мотором — automotive + stationary). Без сброса `isDriving` так и
    /// остался бы true, и поехав дальше (высадили пассажира, ждали у подъезда)
    /// водитель не получил бы автостарта вовсе. Сброс без условия поднял бы
    /// поездку тут же, по следующему сэмплу «в машине, стоим», — поэтому
    /// новый старт ждёт движения. Вышел из машины (любой сэмпл не «в машине»)
    /// — условие снимается: дальше обычные правила.
    func rearmAfterArrival() {
        stopTask?.cancel(); stopTask = nil
        startTask?.cancel(); startTask = nil
        isDriving = false
        drivingSince = nil
        pendingSince = nil
        needsMovementToStart = true
    }

    /// Считается ли сэмпл ездой. После закрытия у цели (`needsMovement`) —
    /// только движущийся: «в машине, стоим» там — та же стоянка.
    nonisolated static func countsAsDriving(automotive: Bool, stationary: Bool,
                                            lowConfidence: Bool, needsMovement: Bool) -> Bool {
        guard automotive, !lowConfidence else { return false }
        return !(needsMovement && stationary)
    }

    private func beginDriving() {
        guard !isDriving else { return }
        needsMovementToStart = false
        isDriving = true
        drivingSince = pendingSince ?? Date()
        pendingSince = nil
        onDrivingStart?()
    }

    private func handle(_ activity: CMMotionActivity) {
        isStationary = activity.stationary && activity.confidence != .low
        // Вышли из машины — закрытие у цели больше не держит старт.
        if !activity.automotive { needsMovementToStart = false }
        let drivingNow = Self.countsAsDriving(automotive: activity.automotive,
                                              stationary: activity.stationary,
                                              lowConfidence: activity.confidence == .low,
                                              needsMovement: needsMovementToStart)

        if drivingNow {
            stopTask?.cancel(); stopTask = nil
            guard !isDriving else { return }
            if pendingSince == nil { pendingSince = min(activity.startDate, Date()) }
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
            pendingSince = nil
        } else if isDriving, activity.stationary || activity.walking || activity.running || activity.cycling {
            // Не гасим сразу — вдруг светофор/пробка. Ждём устойчивую остановку.
            guard stopTask == nil else { return }
            stopTask = Task { [weak self] in
                await Task.pause(seconds: AppConfig.autoStopAfterSeconds)
                guard let self, !Task.isCancelled else { return }
                self.isDriving = false
                self.drivingSince = nil
                self.stopTask = nil
                self.onDrivingStop?()
            }
        }
    }
}
