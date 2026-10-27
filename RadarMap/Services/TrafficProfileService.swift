//
//  TrafficProfileService.swift
//  RadarMap
//
//  traffic/profile.json — типичные пробки по часу недели (33C,
//  server/traffic_profile.py) для времени прибытия во времени
//  (TrafficTimeAhead). Один файл на страну, пересборка раз в сутки: телефон
//  перепроверяет его с ETag не чаще `trafficProfileRefreshSeconds` и только
//  когда он нужен (маршрут). Серверу запрос не говорит ничего, кроме самого
//  запроса: маршрут, дом и работа остаются на телефоне.
//
//  Выключатели те же, что у пробок: «Пробки» в настройках и пульт
//  (`features.traffic`) — `isAllowed`. Выключено — файл забывается.
//

import Foundation
import os

@MainActor
final class TrafficProfileService {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    private var profile: TrafficProfile?
    private var etag: String?
    private var checkedAt: Date?
    private var loading: Task<Void, Never>?

    /// Пробки включены в настройках и пультом; ставит AppEnvironment.
    var isAllowed: () -> Bool = { true }
    var isOnline: () -> Bool = { true }

    private let api = APIClient()
    static let path = "traffic/profile.json"

    /// Профиль из памяти, без сети; nil — не загружен, выключен или старше 36 ч.
    func current(now: Date = Date()) -> TrafficProfile? {
        guard isAllowed() else { return nil }
        return profile.flatMap { $0.isFresh(now: now) ? $0 : nil }
    }

    /// Обновить, если пора. true — профиль сменился (маршрут пересчитает время).
    @discardableResult
    func refreshIfDue(now: Date = Date()) async -> Bool {
        if let loading {
            await loading.value
            return false
        }
        guard isAllowed() else {
            profile = nil
            etag = nil
            return false
        }
        if let checkedAt, now.timeIntervalSince(checkedAt) < AppConfig.trafficProfileRefreshSeconds { return false }
        guard isOnline() else { return false }
        checkedAt = now
        let before = profile?.generated
        let task = Task { [weak self] in _ = await self?.load(now: now) }
        loading = task
        await task.value
        loading = nil
        return profile?.generated != before
    }

    private func load(now: Date) async {
        do {
            if let fresh = try await Self.fetch(api: api, etag: etag) {
                guard isAllowed() else { return }
                etag = fresh.etag
                profile = fresh.profile
                if let profile = fresh.profile {
                    Log.network.info("профиль пробок: рёбер \(profile.slots.count, privacy: .public)")
                } else {
                    Log.network.notice("профиль пробок не разобран — данных нет")
                }
            }   // nil — 304, прежний файл в силе
        } catch {
            // До выкладки сервера файла нет (404) — повтор позже, не на каждом маршруте.
            checkedAt = now.addingTimeInterval(AppConfig.trafficProfileRetrySeconds
                                               - AppConfig.trafficProfileRefreshSeconds)
            Log.network.notice("профиль пробок не загрузился: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Загрузка и разбор вне главного потока.
    @concurrent
    private static func fetch(api: APIClient, etag: String?) async throws
        -> (profile: TrafficProfile?, etag: String?)? {
        guard let answer = try await api.getRawIfChanged(path, etag: etag) else { return nil }
        return (TrafficProfile.decode(answer.data), answer.etag)
    }
}
