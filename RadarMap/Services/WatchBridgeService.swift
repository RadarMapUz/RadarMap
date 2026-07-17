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
    /// Последнее отправленное состояние (для дедупа).
    private var lastSent: [String: Int] = [:]

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
        ]
        guard quantized != lastSent else { return }
        lastSent = quantized

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
