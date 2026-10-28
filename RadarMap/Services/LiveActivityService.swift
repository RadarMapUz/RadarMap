//
//  LiveActivityService.swift
//  RadarMap
//
//  Live Activity «поездка»: ближайшая камера на локскрине и в Dynamic Island.
//  Стартует в foreground при начале движения (ограничение iOS: запуск возможен
//  только на переднем плане), живёт при сворачивании/блокировке, обновляется на
//  фоновых пробуждениях, завершается при возвращении в приложение.
//

import CoreLocation
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
    /// Когда обновляли (ритм — quantize/interval: 50 м / 5 с вблизи камеры,
    /// 200 м / 30 с вдали, полосу между обновлениями ведёт система).
    private var lastSentAt = Date.distantPast
    /// Ответ на «Радар!» с плашки (9.1б) — накладывается на каждое состояние,
    /// пока не снят: `activityState` о нажатии не знает.
    private var reportFlash: Bool?
    /// Номер последней вспышки: снятие от прошлого нажатия не гасит новую.
    private var reportFlashID = 0

    var isActive: Bool { activity != nil }

    /// Плашка прошлого процесса (его убила система посреди поездки) живёт
    /// на локскрине и после смерти: `activity` нового процесса о ней не
    /// знал, и поездка заводила вторую, а старая висела «нет сигнала» до
    /// восьмичасового предела (S14, 20.10). Подхватываем её — обновлять из
    /// фона можно, а запросить новую из фона нельзя; лишние — снимаем.
    init() {
        let alive = Activity<CameraActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
        activity = alive.first
        for extra in alive.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
        if !alive.isEmpty {
            Log.alerts.notice("Live Activity прошлого процесса подхвачена (\(alive.count, privacy: .public))")
        }
    }

    /// Момент, после которого показанная дистанция перестаёт быть правдой.
    /// Без staleDate система считает плашку вечно свежей: приложение убили или
    /// GPS замолчал, а на экране блокировки всё ещё «камера 300 м» — цифра,
    /// на которую водитель смотрит и верит. Пять минут — заведомо больше
    /// обычного интервала обновления и заведомо меньше поездки.
    private static func staleDate() -> Date {
        Date().addingTimeInterval(AppConfig.liveActivityStaleSeconds)
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

    /// `nearMeters` — граница частых обновлений: зона оповещения при текущей
    /// скорости с запасом (см. `nearZone`).
    func update(state: CameraActivityAttributes.ContentState, nearMeters: CLLocationDistance) {
        guard let activity else { return }
        // Квантуем расстояние и не шлём одинаковые состояния — у Live Activity
        // ограниченный бюджет обновлений.
        var quantized = Self.quantize(state, nearMeters: nearMeters)
        quantized.reportFlash = reportFlash
        let now = Date()
        // Полоса — от начала подъезда к ЭТОЙ камере, а не от прошлой отправки:
        // иначе каждое обновление обнуляло бы её (ревью 19.10).
        quantized.since = Self.approachStart(new: quantized, sent: lastSentState, now: now)
        // Состояние давно не менялось (пробка, камер нет) — всё равно освежить
        // до staleDate: иначе плашка сказала бы «Нет сигнала GPS» при живом GPS.
        let keepAlive = now.timeIntervalSince(lastSentAt) >= AppConfig.liveActivityKeepAliveSeconds
        guard keepAlive || Self.differs(quantized, from: lastSentState, now: now) else { return }
        // Смена камеры (заголовка) — сразу; бегущая дистанция и полоса — не
        // чаще интервала ступени.
        if !keepAlive, !Self.answersTap(quantized, from: lastSentState),
           quantized.nearestTitle == lastSentState?.nearestTitle,
           now.timeIntervalSince(lastSentAt) < Self.interval(for: quantized,
                                                             nearMeters: nearMeters) { return }
        lastSentState = quantized
        lastSentAt = Date()
        Task { await activity.update(.init(state: quantized,
                                           staleDate: Self.staleDate())) }
    }

    /// Показать ответ на «Радар!»; отправка — следующим `update`, его зовёт
    /// тот, кто нажал. Возвращает номер для `clearReportFlash`.
    func flashReport(_ ok: Bool) -> Int {
        reportFlash = ok
        reportFlashID += 1
        return reportFlashID
    }

    /// Снять ответ, если он всё ещё от этого нажатия.
    func clearReportFlash(_ id: Int) {
        guard id == reportFlashID else { return }
        reportFlash = nil
    }

    func end() {
        self.activity = nil
        lastSentState = nil
        reportFlash = nil
        // Все плашки этого типа, а не только своя: осиротевшая от прошлого
        // процесса не должна пережить конец поездки (S14).
        for activity in Activity<CameraActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Вблизи камеры — шаг 50 м и раз в 5 с, вдали — 200 м и раз в 30 с. До
    /// 19.10 было 25 м / 3 с и 100 м / 15 с — до 20 пробуждений расширения в
    /// минуту у камеры (аудит энергии); теперь между обновлениями полосу
    /// приближения двигает сама система по `arrivesAt`.
    static func quantize(_ state: CameraActivityAttributes.ContentState,
                         nearMeters: CLLocationDistance = AppConfig.liveActivityNearMeters)
        -> CameraActivityAttributes.ContentState {
        var s = state
        if let d = s.distanceMeters {
            let step = d > nearMeters ? AppConfig.liveActivityFarStepMeters : AppConfig.liveActivityNearStepMeters
            s.distanceMeters = (d / step).rounded() * step
        }
        return s
    }

    static func interval(for state: CameraActivityAttributes.ContentState,
                         nearMeters: CLLocationDistance = AppConfig.liveActivityNearMeters) -> TimeInterval {
        guard let d = state.distanceMeters, d <= nearMeters else {
            return AppConfig.liveActivityFarInterval
        }
        return AppConfig.liveActivityNearInterval
    }

    /// Когда машина будет у камеры на текущей скорости. Стоим (ниже 5 км/ч)
    /// — nil: полоса не едет, а не «прибытие через час».
    static func arrival(distance: CLLocationDistance?, speedKmh: Double, now: Date) -> Date? {
        guard let distance, speedKmh >= 5 else { return nil }
        return now.addingTimeInterval(distance / (speedKmh / 3.6))
    }

    /// Начало полосы приближения: та же камера и машина едет — прежнее начало;
    /// новая камера или тронулись — сейчас.
    static func approachStart(new: CameraActivityAttributes.ContentState,
                              sent: CameraActivityAttributes.ContentState?, now: Date) -> Date? {
        guard new.arrivesAt != nil else { return nil }
        if let sent, sent.nearestTitle == new.nearestTitle, let since = sent.since, sent.arrivesAt != nil {
            return since
        }
        return now
    }

    /// Есть ли что отправлять: сменилась камера или дистанция по ступени, или
    /// прибытие уехало больше чем на долю оставшегося времени (скорость
    /// поменялась). Само течение времени поводом не является — полосу по
    /// нему ведёт система.
    static func differs(_ new: CameraActivityAttributes.ContentState,
                        from old: CameraActivityAttributes.ContentState?, now: Date) -> Bool {
        guard let old else { return true }
        if new.nearestTitle != old.nearestTitle || new.nearestSymbol != old.nearestSymbol
            || new.distanceMeters != old.distanceMeters { return true }
        // Прибытие (маршрут — 9.1, призрак — 8.8.3б) сменило минуту, появилось
        // или ушло, или сменилась тревожность. До 28.10 порог был 2 мин ради
        // бюджета плашки — и плашка спорила с панелью и машиной на минуту
        // (37: «время на телефоне другое»). Минута маршрута меняется не чаще
        // раза в полминуты (ArrivalClock удерживает её), так что и стоя в
        // пробке это не больше отправки в минуту.
        switch (old.etaClock, new.etaClock) {
        case let (was?, now?) where abs(now.timeIntervalSince(was)) >= AppConfig.liveActivityEtaStepSeconds: return true
        case (nil, .some), (.some, nil): return true
        default: break
        }
        if new.etaAlert != old.etaAlert { return true }
        if answersTap(new, from: old) { return true }
        // Знак лимита и уровень тревоги (9.1) меняются редко и значат много.
        if new.limitKmh != old.limitKmh || (new.alertLevel ?? 0) != (old.alertLevel ?? 0) { return true }
        switch (old.arrivesAt, new.arrivesAt) {
        case (nil, nil): return false
        case let (sent?, fresh?):
            let remaining = max(1, fresh.timeIntervalSince(now))
            return abs(fresh.timeIntervalSince(sent)) > max(3, remaining * AppConfig.liveActivityArrivalDrift)
        default: return true
        }
    }

    /// Ответ на нажатие кнопки плашки (9.1б): сменился значок звука или
    /// отметка «Радар!». Это ответ человеку, который смотрит на плашку, — он
    /// уходит сразу, мимо ступени и интервала.
    static func answersTap(_ new: CameraActivityAttributes.ContentState,
                           from old: CameraActivityAttributes.ContentState?) -> Bool {
        guard let old else { return false }
        return (new.muted ?? false) != (old.muted ?? false) || new.reportFlash != old.reportFlash
    }

    /// Граница частых обновлений — по настоящей зоне оповещения, а не одна
    /// на всё. Прежние фиксированные 1 200 м были запасом под трассу (радиус
    /// на 130 км/ч ~800 м), а в Ташкенте ближайшая камера почти всегда ближе
    /// 1,2 км — и плашка шла частой ступенью всю поездку, ~1 200 обновлений в
    /// час (аудит 11.10). Теперь — радиус при текущей скорости с запасом,
    /// не меньше `liveActivityMinNearMeters` и не больше прежней границы.
    static func nearZone(alertRadius: CLLocationDistance) -> CLLocationDistance {
        min(AppConfig.liveActivityNearMeters,
            max(AppConfig.liveActivityMinNearMeters, alertRadius * AppConfig.liveActivityNearMargin))
    }
}
