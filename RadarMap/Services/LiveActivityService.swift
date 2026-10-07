//
//  LiveActivityService.swift
//  RadarMap
//
//  Live Activity «поездка»: ближайшая камера на локскрине и в Dynamic Island.
//  Стартует в foreground при начале движения (ограничение iOS: запуск возможен
//  только на переднем плане), живёт при сворачивании/блокировке, обновляется на
//  фоновых пробуждениях, завершается при возвращении в приложение.
//

import Foundation
import ActivityKit
import os

@MainActor
final class LiveActivityService {

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
    private var activity: Activity<CameraActivityAttributes>?
    private var lastSentState: CameraActivityAttributes.ContentState?
    /// Когда обновляли: квант 25 м в движении — это раз в 1–2 секунды, ≈2500
    /// пробуждений расширения виджета за час. Локскрин не нуждается в
    /// секундной точности дистанции — раз в 3 с достаточно.
    private var lastSentAt = Date.distantPast
    private static let minInterval: TimeInterval = 3

    var isActive: Bool { activity != nil }

    /// Момент, после которого показанная дистанция перестаёт быть правдой.
    /// Без staleDate система считает плашку вечно свежей: приложение убили или
    /// GPS замолчал, а на экране блокировки всё ещё «камера 300 м» — цифра,
    /// на которую водитель смотрит и верит. Пять минут — заведомо больше
    /// обычного интервала обновления и заведомо меньше поездки.
    private static func staleDate() -> Date {
        Date().addingTimeInterval(300)
    }

    func startIfNeeded(state: CameraActivityAttributes.ContentState) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let quantized = Self.quantize(state)
        do {
            activity = try Activity.request(
                attributes: CameraActivityAttributes(),
                content: .init(state: quantized, staleDate: Self.staleDate())
            )
        } catch {
            // Пользователь мог выключить Live Activities — работаем без плашки.
            Log.alerts.notice("Live Activity не стартовала: \(error.localizedDescription, privacy: .public)")
        }
        lastSentState = quantized
    }

    func update(state: CameraActivityAttributes.ContentState) {
        guard let activity else { return }
        // Квантуем расстояние до 25 м и не шлём одинаковые состояния —
        // у Live Activity ограниченный бюджет обновлений.
        let quantized = Self.quantize(state)
        guard quantized != lastSentState else { return }
        // Смена камеры (заголовка) — сразу; бегущая дистанция — не чаще
        // minInterval.
        if quantized.nearestTitle == lastSentState?.nearestTitle,
           Date().timeIntervalSince(lastSentAt) < Self.interval(for: quantized) { return }
        lastSentState = quantized
        lastSentAt = Date()
        Task { await activity.update(.init(state: quantized,
                                           staleDate: Self.staleDate())) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastSentState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Вблизи камеры — каждые 25 м и раз в 3 с, как раньше. Вдали — 100 м и
    /// раз в 15 с: на трассе плашка обновлялась ~1 200 раз в час, и каждый раз
    /// будила расширение виджета и экран блокировки, а дистанцию «4,3 км»
    /// за рулём точнее сотни метров не читают (docs/perf_audit_2026-10-07.md).
    static func quantize(_ state: CameraActivityAttributes.ContentState) -> CameraActivityAttributes.ContentState {
        var s = state
        if let d = s.distanceMeters {
            let step = d > AppConfig.liveActivityNearMeters ? 100.0 : 25.0
            s.distanceMeters = (d / step).rounded() * step
        }
        return s
    }

    static func interval(for state: CameraActivityAttributes.ContentState) -> TimeInterval {
        guard let d = state.distanceMeters, d <= AppConfig.liveActivityNearMeters else {
            return AppConfig.liveActivityFarInterval
        }
        return minInterval
    }
}
