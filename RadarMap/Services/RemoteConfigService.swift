//
//  RemoteConfigService.swift
//  RadarMap
//
//  Загрузка «пульта» (RemoteConfig): подписанный config.json рядом с
//  version.json. Отдельный сервис, а не ветка в RemoteSyncService: тот занят
//  базой камер — мегабайт, раз в сутки, с атомарной подменой файла, — а пульт
//  это триста байт каждые несколько часов и ни одной записи на диск, кроме кэша.
//
//  Живёт по правилу fail closed: любое сомнение — работаем на значениях сборки.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class RemoteConfigService {

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
    /// Действующие значения. До первой удачной загрузки — дефолты сборки.
    private(set) var current: RemoteConfig = .default

    @ObservationIgnored private let api = APIClient(timeout: 10)
    @ObservationIgnored private var isRefreshing = false

    private static var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("remote_config.json")
    }

    init() {
        // Кэш поднимаем сразу: стоп-кран, включённый вчера, обязан действовать
        // и на сегодняшнем холодном старте — иначе он не стоп-кран, а просьба.
        if let stored = JSONFile.load(StoredRemoteConfig.self, from: Self.cacheURL, log: Log.network),
           stored.isFresh() {
            current = stored.config
        }
    }

    /// Пора ли проверить пульт (без сети) — раз в `remoteConfigCheckInterval`.
    /// Спрашивает планировщик сети (NetScheduler, 36B): в окне активации и
    /// прицепом к такту поездки — первым в окне.
    var isCheckDue: Bool {
        guard !isRefreshing else { return false }
        guard let last = Storage.date(.remoteConfigCheck) else { return true }
        return Date().timeIntervalSince(last) >= AppConfig.remoteConfigCheckInterval
    }

    /// Тихая проверка — не чаще, чем раз в `remoteConfigCheckInterval`.
    func refreshIfNeeded() async {
        guard isCheckDue else { return }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let envelope = try await api.get(AppConfig.remoteConfigPath,
                                             as: RemoteConfigEnvelope.self)
            guard let config = envelope.verified() else {
                // Подпись не сошлась — это либо MITM на пути (пока живём по
                // HTTP), либо испорченный файл. И то и другое означает: пульту
                // верить нельзя, работаем на сборке.
                Log.network.error("пульт: подпись не сошлась — значения сборки")
                current = .default
                JSONFile.remove(at: Self.cacheURL, log: Log.network)
                Storage.set(Date(), for: .remoteConfigCheck)
                return
            }
            current = config
            JSONFile.save(StoredRemoteConfig(config: config, fetchedAt: Date()),
                          to: Self.cacheURL, log: Log.network)
            Storage.set(Date(), for: .remoteConfigCheck)
        } catch {
            // Сети нет — остаёмся на том, что было (кэш или дефолты).
            // Дату проверки не двигаем: попробуем снова при следующем запуске.
            Log.network.error("пульт не загрузился: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Что спрашивают у пульта

    var isRoutingEnabled: Bool { current.isRoutingEnabled }
    var areMobileReportsEnabled: Bool { current.areMobileReportsEnabled }
    var areMetricsEnabled: Bool { current.areMetricsEnabled }
    var pollInterval: TimeInterval { current.pollInterval }

    /// Плашка для пользователя: объявление сервера или просьба обновиться.
    /// Просьба обновиться важнее объявления — она про неработающую сборку.
    var banner: RemoteConfig.Message? {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        if current.requiresUpdate(currentVersion: version) {
            return current.activeMessage() ?? RemoteConfig.Message(
                title: String(localized: "Доступна новая версия"),
                body: String(localized: "Эта версия больше не поддерживается — обновите приложение в App Store."),
                until: nil)
        }
        return current.activeMessage()
    }
}
