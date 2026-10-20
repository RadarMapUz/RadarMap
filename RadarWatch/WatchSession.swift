//
//  WatchSession.swift
//  RadarWatch
//
//  Приём состояния поездки с телефона (WatchConnectivity applicationContext —
//  «последнее состояние», не очередь: пропущенные апдейты не копятся).
//  Тактильная эскалация: уровень вырос — часы «тукают» по запястью.
//  Обратно — «Радар!» сообщением с ответом (9.3): телефон в держателе, рука
//  на руле, запястье ближе экрана.
//

import Foundation
import Observation
import WatchConnectivity
import WatchKit

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
    }

    /// Сброс ответа через 3 с — один на нажатие: новое нажатие отменяет
    /// прошлый, иначе он обрезал бы свежий итог (ревью 9.3).
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    /// Уровень тревоги AlertEngine (0 — вне радиуса, 1–3 — эскалация).
    private(set) var alertLevel = 0
    /// Телефон доступен (для подсказки «откройте приложение на iPhone»).
    private(set) var isReachable = false

    @ObservationIgnored private var lastHapticLevel = 0

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
    }
    #endif

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func apply(_ context: [String: Any]) {
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
            let state: ReportState = reply["pending"] as? Bool == true
                ? .pending : .done(ok: reply["ok"] as? Bool ?? false)
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

    private func finish(_ state: ReportState) {
        guard report == .sending else { return }   // поздний ответ после тайм-аута
        report = state
        switch state {
        case .done(ok: true): WKInterfaceDevice.current().play(.success)
        case .done(ok: false): WKInterfaceDevice.current().play(.failure)
        case .pending, .sending: WKInterfaceDevice.current().play(.click)
        }
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self.report = nil
        }
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

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }
}
