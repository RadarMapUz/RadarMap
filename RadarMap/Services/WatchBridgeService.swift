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
//  Спящие часы ради циферблата будим толчком (14.5,
//  `transferCurrentComplicationUserInfo`) — только на начало и конец поездки
//  и другую камеру впереди; когда и хватит ли бюджета — WatchComplicationPush.
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
    /// Компликация на активном циферблате — тоже по событиям сессии.
    private var complicationEnabled = false
    /// Приложение часов на экране: контекст дойдёт сразу, толчок не нужен.
    private var watchAppRunning = false
    /// Учёт толчков циферблату (14.5).
    private var complicationLedger = WatchComplicationPush.Ledger()

    /// «Радар!» с часов (9.3): ответ — точка есть (ушла, в очереди или уже
    /// стояла), нет — или nil: прошлая отметка ещё в пути.
    var onReport: (() async -> Bool?)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onReport,
                                               "WatchBridgeService.onReport") }
    }

    /// Окно «Отменить» после отметки с часов открыто (ReportFlow.canUndo).
    var canUndoReport: (() -> Bool)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: canUndoReport,
                                               "WatchBridgeService.canUndoReport") }
    }
    /// «Отменить» с часов — отзыв последней отметки.
    var onCancelReport: (() async -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onCancelReport,
                                               "WatchBridgeService.onCancelReport") }
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
        /// id камеры (14.5): компликация отличает две камеры с одним адресом.
        /// Старая сборка часов ключ «cid» не читает.
        var cameraID: Int?
        var limit: Int?
        var over: Bool

        /// Повод отправить сразу, мимо интервала: то, что меняет смысл
        /// экрана, а не бегущую цифру. Превышение и появление скорости — по
        /// фронту вверх: «начали превышать» нужно сразу, а «перестали» ждёт
        /// интервала — иначе дребезг у самого лимита будил бы радио каждую
        /// секунду (ревью 9.3).
        func isUrgent(comparedTo old: Payload?) -> Bool {
            guard let old else { return true }
            return level != old.level || title != old.title || symbol != old.symbol
                || cameraID != old.cameraID
                || limit != old.limit || active != old.active
                || (over && !old.over) || (speed != nil && old.speed == nil)
        }

        /// Словарь для часов. `sentAt` («t») — когда телефон за это состояние
        /// ручается: толчок — очередь, и часы по нему отбрасывают старый
        /// (WatchComplication.acceptsPush), а снимок циферблата датируют им.
        func context(sentAt: Date) -> [String: Any] {
            var context: [String: Any] = ["active": active, "level": level, "over": over,
                                          "t": sentAt.timeIntervalSince1970]
            if let speed { context["speed"] = speed }
            if let distance { context["dist"] = distance }
            if let title { context["title"] = title }
            if let symbol { context["sym"] = symbol }
            if let cameraID { context["cid"] = cameraID }
            if let limit { context["limit"] = limit }
            return context
        }
    }

    nonisolated static func payload(isTripActive: Bool, speedKmh: Double, cameraTitle: String?,
                                    cameraSymbol: String?, cameraID: Int?, distanceMeters: Double?,
                                    alertLevel: Int, limitKmh: Int?, isOverspeeding: Bool) -> Payload {
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
                       cameraID: cameraTitle == nil ? nil : cameraID,
                       limit: limitKmh,
                       over: isOverspeeding)
    }

    /// Обновить часы. Дёшево вызывать на каждом GPS-тике: без изменений — no-op.
    func update(isTripActive: Bool, speedKmh: Double, cameraTitle: String?, cameraSymbol: String?,
                cameraID: Int?, distanceMeters: Double?, alertLevel: Int, limitKmh: Int?,
                isOverspeeding: Bool) {
        guard watchReady else { return }
        let payload = Self.payload(isTripActive: isTripActive, speedKmh: speedKmh,
                                   cameraTitle: cameraTitle, cameraSymbol: cameraSymbol,
                                   cameraID: cameraID, distanceMeters: distanceMeters,
                                   alertLevel: alertLevel, limitKmh: limitKmh,
                                   isOverspeeding: isOverspeeding)
        let now = Date()
        // Смысл экрана поменялся — сразу; бегущие цифры — не чаще раза в
        // watchAlertInterval (скорость на часах) или watchCalmInterval.
        if payload != lastSent,
           payload.isUrgent(comparedTo: lastSent)
            || now.timeIntervalSince(lastSentAt)
                >= (payload.speed != nil ? AppConfig.watchAlertInterval : AppConfig.watchCalmInterval) {
            lastSent = payload
            lastSentAt = now
            // Ошибка отправки не критична: следующий тик пришлёт свежее состояние.
            try? WCSession.default.updateApplicationContext(payload.context(sentAt: now))
        }
        // Циферблат — по тому, что ушло контекстом. Толчок, которому интервал
        // не дал уйти сразу, уйдёт на одном из следующих тиков, даже стоя.
        if let lastSent { pushComplicationIfNeeded(lastSent, now: now) }
    }

    /// Толчок циферблату (14.5). Решает WatchComplicationPush, здесь — только
    /// WatchConnectivity. Тик без нового для циферблата — одно сравнение;
    /// бюджет сессии читается, только когда толчок уже решён.
    private func pushComplicationIfNeeded(_ payload: Payload, now: Date) {
        let key = WatchComplicationPush.key(isTripActive: payload.active, cameraID: payload.cameraID)
        guard let event = WatchComplicationPush.event(for: key, delivered: complicationLedger.delivered) else {
            return
        }
        let link = WatchComplicationPush.Link(complicationEnabled: complicationEnabled,
                                              watchAppRunning: watchAppRunning)
        switch WatchComplicationPush.route(event, link: link, ledger: complicationLedger, now: now) {
        case .later:
            return
        case .context:
            complicationLedger = WatchComplicationPush.recording(.viaContext, key: key,
                                                                 ledger: complicationLedger, now: now)
        case .push(let event):
            let session = WCSession.default
            // Без активной сессии вызов — ошибка программиста (документация).
            guard session.activationState == .activated,
                  WatchComplicationPush.hasBudget(for: event,
                                                  remaining: session.remainingComplicationUserInfoTransfers)
            else {
                Log.network.info("часы: толчков циферблату не осталось — только контекст")
                complicationLedger = WatchComplicationPush.recording(.noBudget, key: key,
                                                                     ledger: complicationLedger, now: now)
                return
            }
            // Прошлый толчок ещё в пути — снять: новый несёт свежее, а с
            // компликациями WidgetKit очередь может дойти пачкой, когда часы
            // проснутся сами.
            for transfer in session.outstandingUserInfoTransfers where transfer.isCurrentComplicationInfo {
                transfer.cancel()
            }
            session.transferCurrentComplicationUserInfo(payload.context(sentAt: now))
            complicationLedger = WatchComplicationPush.recording(.pushed(event), key: key,
                                                                 ledger: complicationLedger, now: now)
            Log.network.info("часы: толчок циферблату — \(event == .tripEdge ? "поездка" : "камера", privacy: .public)")
        }
    }
}

/// Ответ часам из главного актора: обработчик WatchConnectivity не Sendable,
/// но вызвать его можно из любого потока — ровно один раз.
private struct WatchReply: @unchecked Sendable {
    let send: ([String: Any]) -> Void
}

/// Первый из ответов (итог или «в пути» по тайм-ауту) — единственный.
@MainActor
private final class WatchReplyOnce {
    private var reply: WatchReply?

    init(_ reply: WatchReply) { self.reply = reply }

    func send(_ message: [String: Any]) {
        reply?.send(message)
        reply = nil
    }
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
        // Свойства сессии верны только у активной сессии (документация).
        let complication = ready && session.isComplicationEnabled
        let running = ready && session.isReachable
        Task { @MainActor in
            self.watchReady = ready
            self.complicationEnabled = complication
            self.watchAppRunning = running
            if !ready {
                self.lastSent = nil
                self.complicationLedger = WatchComplicationPush.Ledger()   // другие часы — другой циферблат
            }
        }
    }
    /// Приложение часов вышло на экран или ушло с него.
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let running = session.activationState == .activated && session.isReachable
        Task { @MainActor in self.watchAppRunning = running }
    }
    /// Толчок циферблату не дошёл. Не беда: контекст ушёл вместе с ним.
    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer,
                             error: Error?) {
        guard let error else { return }
        Log.network.info("часы: толчок циферблату не дошёл — \(error.localizedDescription, privacy: .public)")
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
        let action = message["action"] as? String
        if action == "cancelReport" {
            let reply = WatchReply(send: replyHandler)
            Task { @MainActor in
                await self.onCancelReport?()
                reply.send(["ok": true])
            }
            return
        }
        guard action == "report" else {
            replyHandler([:])
            return
        }
        let reply = WatchReply(send: replyHandler)
        Task { @MainActor in
            let once = WatchReplyOnce(reply)
            // Часы ждут ответа недолго (тайм-аут WatchConnectivity не описан);
            // отметка на слабой связи может идти дольше — тогда честное «в
            // пути», а итог скажет голос телефона.
            Task { @MainActor in
                // Задачу никто не отменяет; ошибка sleep — только отмена, и ответ «в пути» тогда тоже уместен.
                try? await Task.sleep(for: .seconds(AppConfig.watchReplyMaxSeconds))
                once.send(["pending": true])
            }
            guard let onReport = self.onReport else { return once.send(["ok": false]) }
            let answer = await onReport()
            Log.network.info("часы: «Радар!» — \(answer.map { $0 ? "принято" : "отказ" } ?? "уже в пути", privacy: .public)")
            // nil — отметка с прошлого нажатия ещё в пути: не «✕», а «в пути».
            // «Отменить» на запястье — пока открыто окно (8 с, спецификация 02.11).
            once.send(answer.map { ["ok": $0, "undo": $0 && (self.canUndoReport?() ?? false)] }
                      ?? ["pending": true])
        }
    }
}
