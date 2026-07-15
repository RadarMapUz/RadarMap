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

@MainActor
final class MetricsService: NSObject, MXMetricManagerSubscriber {
    private static let deviceKey = "metricsDeviceID"

    private static var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: deviceKey) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: deviceKey)
        return fresh
    }

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
            for data in payloads {
                guard let parsed = try? JSONSerialization.jsonObject(with: data) else { continue }
                let body: [String: Any] = [
                    "device": await Self.deviceID,
                    "kind": kind,
                    "payload": parsed,
                ]
                guard let encoded = try? JSONSerialization.data(withJSONObject: body) else { continue }
                var request = URLRequest(
                    url: AppConfig.syncBaseURL.appendingPathComponent("api/metrics"),
                    timeoutInterval: 20
                )
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = encoded
                // Потерянный пакет не страшен — придёт со следующим суточным отчётом.
                _ = try? await URLSession.shared.data(for: request)
            }
        }
    }
}
