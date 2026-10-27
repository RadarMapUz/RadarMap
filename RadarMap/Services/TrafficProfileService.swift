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
//  Слой «обычно в это время» (33G): пока на карту смотрят (`setWanted`, те же
//  экран, машина и поездка, что у живых пробок), раз в
//  `usualTrafficRecomputeSeconds` — рёбра, где в этот час обычно медленно
//  (TrafficProfile.usual, вне главного потока). Только показ и ETA: голосу
//  (JamAhead, объезд) этот слой не виден.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class TrafficProfileService {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    /// Рёбра слоя «обычно в это время»; пусто — нет профиля, выключено или
    /// в этот час везде как граф (ночь).
    private(set) var usualEdges: [TrafficProfile.UsualEdge] = []
    /// Растёт на каждом новом наборе слоя — по нему карта перерисовывает.
    private(set) var usualRevision = 0

    @ObservationIgnored private var profile: TrafficProfile?
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var checkedAt: Date?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var usualTask: Task<Void, Never>?

    /// Пробки включены в настройках и пультом; ставит AppEnvironment.
    @ObservationIgnored var isAllowed: () -> Bool = { true }
    @ObservationIgnored var isOnline: () -> Bool = { true }

    @ObservationIgnored private let api = APIClient(base: AppConfig.trafficFeedBaseURL)
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
        #if DEBUG
        // Снимки без сервера: `-trafficProfileFile /путь/profile.json`.
        if let path = UserDefaults.standard.string(forKey: "trafficProfileFile"),
           let data = FileManager.default.contents(atPath: path) {
            profile = TrafficProfile.decode(data)
            Log.network.info("профиль пробок из файла: рёбер \(self.profile?.slots.count ?? 0, privacy: .public)")
            return
        }
        #endif
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

    // MARK: - Слой «обычно в это время» (33G)

    /// Кто-то смотрит на карту (экран, машина, поездка) — слой нужен. Ставит
    /// AppEnvironment вместе с живыми пробками.
    func setWanted(_ wanted: Bool) {
        guard wanted != self.wanted else { return }
        self.wanted = wanted
        usualTask?.cancel()
        usualTask = nil
        guard wanted else { return }
        usualTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshIfDue()
                await self.recomputeUsual()
                await Task.pause(seconds: AppConfig.usualTrafficRecomputeSeconds)
            }
        }
    }

    /// Пересчитать слой на «сейчас» (или на момент DEBUG-хука `-usualTrafficAt`).
    func recomputeUsual(now: Date = Date()) async {
        guard isAllowed(), let profile = current(now: now) else {
            if !usualEdges.isEmpty {
                usualEdges = []
                usualRevision &+= 1
            }
            return
        }
        let moment = Self.layerMoment(now)
        let edges = await Self.usual(profile, at: moment)
        guard edges != usualEdges else { return }
        usualEdges = edges
        usualRevision &+= 1
        Log.network.info("обычно в это время: рёбер \(edges.count, privacy: .public) на \(moment.formatted(.iso8601), privacy: .public)")
    }

    @concurrent
    private static func usual(_ profile: TrafficProfile, at moment: Date) async -> [TrafficProfile.UsualEdge] {
        profile.usual(at: moment)
    }

    /// Момент слоя: сейчас; в DEBUG — `-usualTrafficAt 2026-10-26T18:30`
    /// (ташкентское время) для снимков карты в часы пик без ожидания вечера.
    private static func layerMoment(_ now: Date) -> Date {
        #if DEBUG
        if let date = UserDefaults.standard.object(forKey: "usualTrafficAt") as? Date { return date }
        if let text = UserDefaults.standard.string(forKey: "usualTrafficAt") {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = TypicalTraffic.tashkent.timeZone
            format.dateFormat = "yyyy-MM-dd'T'HH:mm"
            if let date = format.date(from: text) { return date }
        }
        #endif
        return now
    }

    /// Загрузка и разбор вне главного потока.
    @concurrent
    private static func fetch(api: APIClient, etag: String?) async throws
        -> (profile: TrafficProfile?, etag: String?)? {
        guard let answer = try await api.getRawIfChanged(path, etag: etag) else { return nil }
        return (TrafficProfile.decode(answer.data), answer.etag)
    }
}
