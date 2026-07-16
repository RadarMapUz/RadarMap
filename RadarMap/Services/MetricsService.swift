//
//  MetricsService.swift
//  RadarMap
//
//  Телеметрия здоровья приложения: MetricKit (нативно, без сторонних SDK).
//  iOS раз в сутки отдаёт агрегаты (батарея, зависания, краши) — шлём на наш сервер,
//  чтобы узнавать о проблемах раньше злых отзывов. Ничего личного: анонимный UUID,
//  ни координат, ни контента.
//

import Foundation
import MetricKit
import os

@MainActor
final class MetricsService: NSObject, MXMetricManagerSubscriber {
    private static var deviceID: String { Storage.anonymousID(.metricsDeviceID) }

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    // MetricKit зовёт эти методы на своей очереди.
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        upload(payloads.map { $0.jsonRepresentation() }, kind: "metric")
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        upload(payloads.map { $0.jsonRepresentation() }, kind: "diagnostic")
    }

    nonisolated private func upload(_ payloads: [Data], kind: String) {
        Task {
            let api = APIClient(timeout: 20)
            for data in payloads {
                guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
                    Log.network.error("MetricKit-пакет \(kind, privacy: .public) не распарсился")
                    continue
                }
                let body: [String: Any] = [
                    "device": await Self.deviceID,
                    "kind": kind,
                    "payload": parsed,
                ]
                // Словарь из уже валидного JSON — сериализация не падает.
                guard let encoded = try? JSONSerialization.data(withJSONObject: body) else { continue }
                // Потерянный пакет не страшен — придёт со следующим суточным отчётом.
                _ = await api.postAccepted("api/metrics", body: encoded)
            }
        }
    }
}
