//
//  WatchBridgeService.swift
//  RadarMap
//
//  Мост на Apple Watch: шлём состояние поездки (скорость, ближайшая камера,
//  уровень тревоги) через applicationContext — «последнее состояние», не очередь.
//  Квантуем и дедупим, как в Live Activity: радио будим только когда цифры
//  реально изменились — батарея обоих устройств целее.
//

import Foundation
import WatchConnectivity

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
    private var lastSent: [String: Int] = [:]
    /// Когда отправляли: в движении кванты (2 км/ч, 25 м) перешагиваются почти
    /// каждым тиком, и дедуп по значению превращался в честный 1 Гц — ≈3600
    /// пробуждений BT-радио обоих устройств за час. Скорость и дистанция на
    /// запястье не нуждаются в секундной точности — а смена уровня тревоги
    /// проходит без очереди.
    private var lastSentAt = Date.distantPast
    private static let minInterval: TimeInterval = 3

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Обновить часы. Дёшево вызывать на каждом GPS-тике: без изменений — no-op.
    func update(isTripActive: Bool, speedKmh: Double, cameraTitle: String?,
                distanceMeters: Double?, alertLevel: Int) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }

        // Квантуем: скорость до 2 км/ч, дистанцию до 25 м — меньше пробуждений радио.
        let quantized: [String: Int] = [
            "active": isTripActive ? 1 : 0,
            "speed": Int((speedKmh / 2).rounded()) * 2,
            "dist": distanceMeters.map { Int(($0 / 25).rounded()) * 25 } ?? -1,
            "level": alertLevel,
            // Смена ближайшей камеры при совпавших квантах — тоже повод отправить:
            // иначе на часах висело бы название прошлой камеры со свежей дистанцией.
            "title": cameraTitle?.hashValue ?? 0,
        ]
        guard quantized != lastSent else { return }
        // Вне тревоги — не чаще раза в minInterval; рост/сброс уровня — сразу.
        if quantized["level"] == lastSent["level"],
           Date().timeIntervalSince(lastSentAt) < Self.minInterval { return }
        lastSent = quantized
        lastSentAt = Date()

        var context: [String: Any] = [
            "active": isTripActive,
            "speed": quantized["speed"] ?? 0,
            "level": alertLevel,
        ]
        if let dist = quantized["dist"], dist >= 0 { context["dist"] = dist }
        if let cameraTitle { context["title"] = cameraTitle }
        // Ошибка отправки не критична: следующий тик пришлёт свежее состояние.
        try? session.updateApplicationContext(context)
    }
}

extension WatchBridgeService: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()   // смена часов — переактивируемся
    }
}
