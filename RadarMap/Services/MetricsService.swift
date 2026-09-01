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
    private static var deviceID: String { Storage.anonymousID(.metricsDeviceID) }

    private var started = false

    /// Пульт: приём метрик можно погасить, если на сервере беда с местом или
    /// разбором. Проверяем в момент отправки, а не подписки: пакеты приходят
    /// раз в сутки, и к этому времени пульт давно загружен.
    weak var config: RemoteConfigService?

    private var isUploadAllowed: Bool { config?.areMetricsEnabled ?? true }

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
            guard await self.isUploadAllowed else { return }
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
