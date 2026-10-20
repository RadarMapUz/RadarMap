//
//  WatchBridgeService.swift
//  RadarMap
//
//  Мост на Apple Watch: шлём состояние поездки (ближайшая камера, уровень
//  тревоги, знак ограничения, скорость — в тревоге или при превышении) через
//  applicationContext — «последнее состояние», не очередь. Обратно — «Радар!»
//  сообщением с ответом (9.3).
//  Квантуем и дедупим, как в Live Activity: радио будим только когда цифры
//  реально изменились — батарея обоих устройств целее.
//

import Foundation
import WatchConnectivity
import os

@MainActor
final class WatchBridgeService: NSObject {

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
    /// Последнее отправленное состояние (для дедупа).
    private var lastSent: Payload?
    /// Когда отправляли: в движении кванты перешагиваются почти каждым тиком,
    /// и дедуп по значению превращался в честный 1 Гц — ≈3600 пробуждений
    /// BT-радио обоих устройств за час. Дистанция на запястье не нуждается в
    /// секундной точности — а смена уровня, камеры, знака и превышения
    /// проходит без очереди.
    private var lastSentAt = Date.distantPast
    /// Часы спарены и приложение на них стоит — по событиям сессии, а не
    /// опросом WCSession на каждом GPS-тике (аудит энергии 19.10).
    private var watchReady = false

    /// «Радар!» с часов (9.3): ответ — ушла ли отметка (или встала в очередь).
    var onReport: (() async -> Bool)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onReport,
                                               "WatchBridgeService.onReport") }
    }

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Что уходит на часы — квантованное, для дедупа (чистое, WatchBridgeTests).
    nonisolated struct Payload: Equatable {
        var active: Bool
        /// Скорость — только в тревоге или при превышении (9.3): в спокойном
        /// режиме часы её не показывают — ступень 5 км/ч раз в 10 с была
        /// старой цифрой на запястье. nil — не показывать.
        var speed: Int?
        var distance: Int?
        var level: Int
        var title: String?
        var symbol: String?
        var limit: Int?
        var over: Bool

        /// Повод отправить сразу, мимо интервала: то, что меняет смысл
        /// экрана, а не бегущую цифру.
        func isUrgent(comparedTo old: Payload?) -> Bool {
            guard let old else { return true }
            return level != old.level || title != old.title || limit != old.limit
                || over != old.over || active != old.active || (speed == nil) != (old.speed == nil)
        }

        var context: [String: Any] {
            var context: [String: Any] = ["active": active, "level": level, "over": over]
            if let speed { context["speed"] = speed }
            if let distance { context["dist"] = distance }
            if let title { context["title"] = title }
            if let symbol { context["sym"] = symbol }
            if let limit { context["limit"] = limit }
            return context
        }
    }

    nonisolated static func payload(isTripActive: Bool, speedKmh: Double, cameraTitle: String?,
                                    cameraSymbol: String?, distanceMeters: Double?, alertLevel: Int,
                                    limitKmh: Int?, isOverspeeding: Bool) -> Payload {
        let showsSpeed = isTripActive && (alertLevel > 0 || isOverspeeding)
        let speedStep = AppConfig.watchSpeedStepAlert
        let distStep = (distanceMeters ?? .infinity) > AppConfig.liveActivityNearMeters
            ? AppConfig.watchDistanceStepFar : AppConfig.watchDistanceStepNear
        return Payload(active: isTripActive,
                       speed: showsSpeed ? Int((speedKmh / speedStep).rounded() * speedStep) : nil,
                       distance: distanceMeters.map { Int(($0 / distStep).rounded() * distStep) },
                       level: alertLevel,
                       title: cameraTitle,
                       symbol: cameraTitle == nil ? nil : cameraSymbol,
                       limit: limitKmh,
                       over: isOverspeeding)
    }

    /// Обновить часы. Дёшево вызывать на каждом GPS-тике: без изменений — no-op.
    func update(isTripActive: Bool, speedKmh: Double, cameraTitle: String?, cameraSymbol: String?,
                distanceMeters: Double?, alertLevel: Int, limitKmh: Int?, isOverspeeding: Bool) {
        guard watchReady else { return }
        let payload = Self.payload(isTripActive: isTripActive, speedKmh: speedKmh,
                                   cameraTitle: cameraTitle, cameraSymbol: cameraSymbol,
                                   distanceMeters: distanceMeters, alertLevel: alertLevel,
                                   limitKmh: limitKmh, isOverspeeding: isOverspeeding)
        guard payload != lastSent else { return }
        // Смысл экрана поменялся — сразу; бегущие цифры — не чаще раза в
        // watchAlertInterval (скорость на часах) или watchCalmInterval.
        if !payload.isUrgent(comparedTo: lastSent),
           Date().timeIntervalSince(lastSentAt)
            < (payload.speed != nil ? AppConfig.watchAlertInterval : AppConfig.watchCalmInterval) {
            return
        }
        lastSent = payload
        lastSentAt = Date()
        // Ошибка отправки не критична: следующий тик пришлёт свежее состояние.
        try? WCSession.default.updateApplicationContext(payload.context)
    }
}

/// Ответ часам из главного актора: обработчик WatchConnectivity не Sendable,
/// но вызвать его можно из любого потока — ровно один раз.
private struct WatchReply: @unchecked Sendable {
    let send: ([String: Any]) -> Void
}

extension WatchBridgeService: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        noteWatchState(session)
    }
    /// Часы спарили, сняли, поставили или удалили приложение.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        noteWatchState(session)
    }
    nonisolated private func noteWatchState(_ session: WCSession) {
        let ready = session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
        Task { @MainActor in
            self.watchReady = ready
            if !ready { self.lastSent = nil }
        }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        noteWatchState(session)   // смена часов: пока неактивна — не шлём
    }
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        noteWatchState(session)
        session.activate()   // смена часов — переактивируемся
    }

    /// «Радар!» с часов. Часы будят приложение в фоне и ждут ответа — без
    /// него на запястье не узнать, ушла ли отметка.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = WatchReply(send: replyHandler)
        guard message["action"] as? String == "report" else {
            reply.send([:])
            return
        }
        Task { @MainActor in
            let ok = await self.onReport?() ?? false
            Log.network.info("часы: «Радар!» — \(ok ? "принято" : "отказ", privacy: .public)")
            reply.send(["ok": ok])
        }
    }
}
