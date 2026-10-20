//
//  TypicalTrafficService.swift
//  RadarMap
//
//  Файлы «обычно по водителям» (traffic/typical/<wd|off>-<час>.json, план
//  19.10, 8.8.16) — рядом с TrafficService, но своим ритмом: не опрос каждые
//  две минуты, а один-два файла по запросу, перепроверка с ETag не чаще
//  `typicalTrafficRefreshSeconds`.
//
//  Просит их AppEnvironment и только тогда, когда они нужны: дом и работа
//  известны, путь уже лёг в профиль, а своих поездок для «обычно» ещё меньше
//  трёх. Серверу запрос говорит только час (файл общий для всех); линия
//  пути, дом и работа остаются на телефоне — время по линии складывает
//  TypicalTraffic.
//
//  Выключатели те же, что у пробок: «Пробки» в настройках и пульт
//  (`features.traffic`) — `isAllowed`. Выключено — кэш забывается.
//

import Foundation
import os

@MainActor
final class TypicalTrafficService {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    private struct Entry {
        var traffic: TypicalTraffic?
        var etag: String?
        /// Когда спрашивали сервер (после ошибки — сдвинуто к скорому повтору).
        var checkedAt: Date
    }

    private var cache: [String: Entry] = [:]
    /// Загрузки — по одной: два пересчёта подряд (старт сцены и загрузка
    /// профиля) иначе скачали бы один файл дважды.
    private var chain: Task<Void, Never>?

    /// Пробки включены в настройках и пультом; ставит AppEnvironment.
    var isAllowed: () -> Bool = { true }
    var isOnline: () -> Bool = { true }

    private let api = APIClient()

    /// Файлы этих часов — из памяти или с сервера; часа нет в ответе — данных
    /// нет (выключено, нет сети и кэша, файл пуст или чужого формата).
    func files(for buckets: Set<TypicalTraffic.Bucket>) async -> [TypicalTraffic.Bucket: TypicalTraffic] {
        let previous = chain
        let task = Task { [weak self] in
            await previous?.value
            await self?.load(buckets)
        }
        chain = task
        await task.value
        guard isAllowed() else { return [:] }
        var out: [TypicalTraffic.Bucket: TypicalTraffic] = [:]
        for bucket in buckets {
            if let traffic = cache[bucket.name]?.traffic { out[bucket] = traffic }
        }
        return out
    }

    private func load(_ buckets: Set<TypicalTraffic.Bucket>) async {
        guard isAllowed() else {
            if !cache.isEmpty { cache = [:] }
            return
        }
        // В памяти — только нужные часы: город целиком — тысячи рёбер на файл.
        let wanted = Set(buckets.map(\.name))
        cache = cache.filter { wanted.contains($0.key) }
        for bucket in buckets.sorted(by: { $0.name < $1.name }) {
            let now = Date()
            if let at = cache[bucket.name]?.checkedAt,
               now.timeIntervalSince(at) < AppConfig.typicalTrafficRefreshSeconds { continue }
            guard isOnline() else { continue }
            var entry = cache[bucket.name] ?? Entry(traffic: nil, etag: nil, checkedAt: now)
            entry.checkedAt = now
            do {
                if let fresh = try await Self.fetch(api: api, bucket: bucket, etag: entry.etag) {
                    entry.etag = fresh.etag
                    entry.traffic = fresh.traffic
                    if let traffic = fresh.traffic {
                        Log.network.info("обычно по водителям: \(bucket.name, privacy: .public), рёбер \(traffic.snapshot.edges.count, privacy: .public)")
                    } else {
                        Log.network.notice("обычно по водителям: \(bucket.name, privacy: .public) не разобран — данных нет")
                    }
                }   // nil — 304, прежний файл в силе
            } catch {
                // До выкладки сервера файла нет (404) — повтор через четверть
                // часа, а не на каждом пересчёте.
                entry.checkedAt = now.addingTimeInterval(AppConfig.typicalTrafficRetrySeconds
                                                         - AppConfig.typicalTrafficRefreshSeconds)
                Log.network.notice("обычно по водителям не загрузилось (\(bucket.name, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            }
            // Пока ждали сеть, пробки могли выключить — тогда не храним.
            guard isAllowed() else {
                cache = [:]
                return
            }
            cache[bucket.name] = entry
        }
    }

    /// Загрузка и разбор вне главного потока.
    @concurrent
    private static func fetch(api: APIClient, bucket: TypicalTraffic.Bucket, etag: String?) async throws
        -> (traffic: TypicalTraffic?, etag: String?)? {
        guard let answer = try await api.getRawIfChanged(bucket.path, etag: etag) else { return nil }
        return (TypicalTraffic.decode(answer.data, expected: bucket), answer.etag)
    }
}
