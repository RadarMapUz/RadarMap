//
//  WatchSession.swift
//  RadarWatch
//
//  Приём состояния поездки с телефона (WatchConnectivity applicationContext —
//  «последнее состояние», не очередь: пропущенные апдейты не копятся).
//  Тактильная эскалация: уровень вырос — часы «тукают» по запястью.
//  Обратно — «Радар!» сообщением с ответом (9.3): телефон в держателе, рука
//  на руле, запястье ближе экрана.
//  Толчок циферблату (14.5) — userInfo с тем же снимком: будит спящее
//  приложение ради компликации. Это очередь, поэтому берём его, только если
//  он новее применённого (WatchComplication.acceptsPush), и без тука — тук
//  остаётся за контекстом, иначе запоздавший толчок «тукнул» бы о камере,
//  которая уже позади.
//

import Foundation
import Observation
import WatchConnectivity
import WatchKit
import os

@MainActor
@Observable
final class WatchSession: NSObject {
    /// Поездка на телефоне активна (иначе показываем «откройте RadarMap»).
    private(set) var isTripActive = false
    /// Скорость — только в тревоге или при превышении (9.3); nil — не показывать.
    private(set) var speedKmh: Int?
    private(set) var cameraTitle: String?
    /// SF Symbol типа камеры.
    private(set) var cameraSymbol: String?
    private(set) var distanceMeters: Int?
    /// Ограничение дороги, км/ч; nil — не знаем.
    private(set) var limitKmh: Int?
    /// Едем быстрее ограничения (решает телефон, с его допуском).
    private(set) var isOverspeeding = false
    /// Ответ на «Радар!»: nil — кнопка в покое.
    private(set) var report: ReportState?

    enum ReportState: Equatable {
        case sending
        /// Отметка ещё в пути (слабая связь или прошлое нажатие) — не «✕»:
        /// итог скажет голос телефона.
        case pending
        case done(ok: Bool)
        /// Отмечено, и ещё можно отменить (8 с): кнопка — «Отменить».
        case undoable
        /// «Отменить» ушла — ждём ответа телефона.
        case cancelling
    }

    /// Сброс ответа через 3 с — один на нажатие: новое нажатие отменяет
    /// прошлый, иначе он обрезал бы свежий итог (ревью 9.3).
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    /// Уровень тревоги AlertEngine (0 — вне радиуса, 1–3 — эскалация).
    private(set) var alertLevel = 0
    /// Телефон доступен (для подсказки «откройте приложение на iPhone»).
    private(set) var isReachable = false

    @ObservationIgnored private var lastHapticLevel = 0
    /// Компликация «следующая камера» (9.3б) — из того же контекста.
    @ObservationIgnored private let complication = ComplicationFeed()
    /// Когда телефон отправил последнее применённое состояние (ключ «t»):
    /// толчок не старше него не берём.
    @ObservationIgnored private var lastAppliedAt: Date?
    @ObservationIgnored private let log = Logger(subsystem: "uz.radarmap.ios.watch", category: "session")

    #if DEBUG
    /// `-demo`: живой HUD без телефона — для скриншотов и превью на симуляторе.
    func seedDemo() {
        isTripActive = true
        speedKmh = 64
        cameraTitle = String(localized: "Стационарная камера")
        cameraSymbol = "camera.fill"
        distanceMeters = 350
        limitKmh = 60
        isOverspeeding = true
        alertLevel = 2
        complication.update(isTripActive: true, symbol: cameraSymbol, title: cameraTitle,
                            distanceMeters: distanceMeters)
    }
    #endif

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Состояние с телефона. `pushed` — толчок циферблату (userInfo), а не
    /// контекст: берётся только новее применённого и без тука по запястью.
    private func apply(_ context: [String: Any], pushed: Bool = false) {
        let sentAt = (context["t"] as? Double).map { Date(timeIntervalSince1970: $0) }
        if pushed {
            guard WatchComplication.acceptsPush(sentAt: sentAt, lastAppliedAt: lastAppliedAt,
                                                now: Date()) else {
                log.info("толчок с телефона устарел — не применяем")
                return
            }
        }
        // Контекст — всегда последний: применяем, даже если часы телефона
        // сбиты назад, и меряем толчки от него.
        if let sentAt { lastAppliedAt = sentAt }
        // Пишем только на смене: каждое присваивание @Observable будит HUD,
        // а контекст с телефона приходит и с совпавшими значениями.
        let active = context["active"] as? Bool ?? false
        if active != isTripActive { isTripActive = active }
        let speed = context["speed"] as? Int
        if speed != speedKmh { speedKmh = speed }
        let title = context["title"] as? String
        if title != cameraTitle { cameraTitle = title }
        let symbol = context["sym"] as? String
        if symbol != cameraSymbol { cameraSymbol = symbol }
        let distance = context["dist"] as? Int
        if distance != distanceMeters { distanceMeters = distance }
        let limit = context["limit"] as? Int
        if limit != limitKmh { limitKmh = limit }
        let over = context["over"] as? Bool ?? false
        if over != isOverspeeding { isOverspeeding = over }
        let level = context["level"] as? Int ?? 0
        complication.update(isTripActive: active, symbol: symbol, title: title,
                            distanceMeters: distance, cameraID: context["cid"] as? Int,
                            sentAt: sentAt)
        guard !pushed else {
            if level != alertLevel { alertLevel = level }
            return
        }

        // Тук на запястье при росте уровня; сброс серии — когда камера позади.
        if isTripActive, level > lastHapticLevel {
            WKInterfaceDevice.current().play(level >= 3 ? .notification
                                           : level == 2 ? .directionUp : .start)
        }
        lastHapticLevel = level == 0 ? 0 : max(lastHapticLevel, level)
        if level != alertLevel { alertLevel = level }
    }
}

extension WatchSession {
    /// «Радар!» с запястья: телефон ставит отметку той же дверью, что кнопка
    /// на карте, и отвечает, ушла ли она. Не дотянулись до телефона — отказ
    /// сразу, а не тишина.
    func sendReport() {
        guard report != .sending else { return }
        clearTask?.cancel()
        report = .sending
        WKInterfaceDevice.current().play(.click)
        let session = WCSession.default
        guard session.activationState == .activated else {
            finish(.done(ok: false))
            return
        }
        session.sendMessage(["action": "report"], replyHandler: { reply in
            let ok = reply["ok"] as? Bool ?? false
            let state: ReportState = reply["pending"] as? Bool == true ? .pending
                : ok && reply["undo"] as? Bool == true ? .undoable : .done(ok: ok)
            Task { @MainActor in self.finish(state) }
        }, errorHandler: { _ in
            Task { @MainActor in self.finish(.done(ok: false)) }
        })
        // Свой предел ожидания: ни ответа, ни ошибки — кнопка не должна
        // застыть в «отправке». Телефон отвечает не позже своих 8 с.
        clearTask = Task {
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, self.report == .sending else { return }
            self.finish(.pending)
        }
    }

    /// «Отменить» с запястья, пока окно открыто: телефон отзывает отметку
    /// той же дверью, что кнопка на карте (ReportFlow.undo), и говорит итог.
    func cancelReport() {
        guard report == .undoable else { return }
        clearTask?.cancel()
        report = .cancelling
        WKInterfaceDevice.current().play(.click)
        WCSession.default.sendMessage(["action": "cancelReport"], replyHandler: { _ in
            Task { @MainActor in self.settle(nil) }
        }, errorHandler: { _ in
            Task { @MainActor in self.settle(nil) }
        })
    }

    private func settle(_ state: ReportState?) {
        guard report == .cancelling else { return }
        report = state
    }

    private func finish(_ state: ReportState) {
        guard report == .sending else { return }   // поздний ответ после тайм-аута
        report = state
        switch state {
        case .done(ok: true), .undoable: WKInterfaceDevice.current().play(.success)
        case .done(ok: false): WKInterfaceDevice.current().play(.failure)
        case .pending, .sending, .cancelling: WKInterfaceDevice.current().play(.click)
        }
        clearTask?.cancel()
        // «Отменить» живёт окно отмены телефона (8 с), остальное — 3 с.
        let seconds: Double = state == .undoable ? 8 : 3
        clearTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.report = nil
        }
    }
}

extension WatchSession {
    /// Фоновое пробуждение ради контекста (`.backgroundTask(.watchConnectivity)`):
    /// компликация на циферблате живёт, пока приложение часов спит, и контекст
    /// или толчок с телефона (14.5) будят его в фоне. `hasContentPending`
    /// покрывает оба. Задачу держим, пока сессия не примет всё,
    /// и ещё чуть-чуть — чтобы `apply` успел на главном акторе. Не дольше 10 с.
    nonisolated static func drainPendingContent() async {
        let session = WCSession.default
        for _ in 0..<50 {
            if Task.isCancelled { return }
            if session.activationState == .activated, !session.hasContentPending { break }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }   // отмена
        }
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
    }
}

extension WatchSession: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        // Контекст мог прийти, пока приложение спало, — подхватываем последний.
        let context = session.receivedApplicationContext
        Task { @MainActor in
            self.isReachable = session.isReachable
            if !context.isEmpty { self.apply(context) }
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }

    /// Толчок циферблату с телефона (`transferCurrentComplicationUserInfo`, 14.5).
    /// Других userInfo телефон не шлёт.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.apply(userInfo, pushed: true) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }
}
