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
        // Не ушедшие в прошлый раз — сейчас (S26, 20.10).
        Self.flushPending(allowed: isUploadAllowed)
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
                // Не ушёл (трасса без сети, сервер лёг) — на диск: диагностика
                // (крэш, зависание) приходит от системы ОДИН раз, и крэши на
                // трассе без покрытия терялись первыми (S26, 20.10).
                if await !api.postAccepted("api/metrics", body: encoded) {
                    MetricsQueue.save(encoded)
                }
            }
        }
    }

    /// Дослать отложенные отчёты: по одному, до первой неудачи.
    nonisolated static func flushPending(allowed: Bool) {
        Task.detached(priority: .utility) {
            MetricsQueue.prune(now: Date())
            guard allowed else { return }
            let api = APIClient(timeout: 20)
            for url in MetricsQueue.pending() {
                guard let data = try? Data(contentsOf: url) else {
                    MetricsQueue.remove(url)
                    continue
                }
                guard await api.postAccepted("api/metrics", body: data) else { return }
                MetricsQueue.remove(url)
            }
        }
    }
}

/// Отчёты MetricKit, ждущие отправки (S26, 20.10): не больше 20 и не
/// старше недели — очередь не растёт без конца на телефоне, который месяцами
/// не видит сервер.
nonisolated enum MetricsQueue {
    static let maxFiles = 20
    static let maxAgeDays = 7.0

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("metrics_pending", isDirectory: true)
    }

    static func save(_ body: Data, now: Date = Date()) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(String(format: "%.0f-%@.json", now.timeIntervalSince1970,
                                                              UUID().uuidString))
            try body.write(to: url, options: .atomic)
        } catch {
            Log.network.error("отчёт MetricKit не отложен: \(error.localizedDescription, privacy: .public)")
        }
        prune(now: now)
    }

    /// Отложенные, от старых к новым (имя начинается со времени).
    static func pending() -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.sorted().map { directory.appendingPathComponent($0) }
    }

    static func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Log.network.error("отложенный отчёт не удалён: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Старше недели и сверх 20 — долой, старые первыми.
    static func prune(now: Date) {
        let files = pending()
        let limit = now.timeIntervalSince1970 - maxAgeDays * 86_400
        var kept: [URL] = []
        for url in files {
            let stamp = Double(url.lastPathComponent.split(separator: "-").first ?? "") ?? 0
            if stamp < limit { remove(url) } else { kept.append(url) }
        }
        for url in kept.dropLast(maxFiles) { remove(url) }
    }
}
