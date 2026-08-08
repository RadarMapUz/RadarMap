//
//  WatchSession.swift
//  RadarWatch
//
//  Приём состояния поездки с телефона (WatchConnectivity applicationContext —
//  «последнее состояние», не очередь: пропущенные апдейты не копятся).
//  Тактильная эскалация: уровень вырос — часы «тукают» по запястью.
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
    private(set) var speedKmh: Int = 0
    private(set) var cameraTitle: String?
    private(set) var distanceMeters: Int?
    /// Уровень тревоги AlertEngine (0 — вне радиуса, 1–3 — эскалация).
    private(set) var alertLevel = 0
    /// Телефон доступен (для подсказки «откройте приложение на iPhone»).
    private(set) var isReachable = false

    @ObservationIgnored private var lastHapticLevel = 0

    #if DEBUG
    /// `-demo`: живой HUD без телефона — для скриншотов и превью на симуляторе.
    func seedDemo() {
        isTripActive = true
        speedKmh = 84
        cameraTitle = String(localized: "Стационарная камера")
        distanceMeters = 350
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
        let speed = context["speed"] as? Int ?? 0
        if speed != speedKmh { speedKmh = speed }
        let title = context["title"] as? String
        if title != cameraTitle { cameraTitle = title }
        let distance = context["dist"] as? Int
        if distance != distanceMeters { distanceMeters = distance }
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
