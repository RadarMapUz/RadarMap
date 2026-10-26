//
//  RoadMemoryService.swift
//  RadarMap
//
//  Память своих дорог и новости о камерах на них (31E, п. 4). Чистая логика
//  — CameraNews/RoadCells; здесь только диск и момент «база сменилась».
//
//  Клетки лежат в Documents/road_cells.json, вне резервной копии iCloud (как
//  посекундный трек): это грубая, но всё же карта мест, где человек бывает.
//  Набор виденных id и новости — в Storage (числа без координат).
//

import Foundation
import Observation
import os

@MainActor @Observable
final class RoadMemoryService {
    /// См. TripStats: без синтезированного isolated deinit (рантайм iOS 26).
    nonisolated deinit {}

    /// Новые камеры на своих дорогах, ещё не убранные человеком.
    private(set) var news: [CameraNews.Item] = Storage.decoded([CameraNews.Item].self, for: .cameraNews) ?? []

    @ObservationIgnored private var roads = RoadCells()
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var pendingTracks: [([(lat: Double, lon: Double)], Date)] = []
    /// Версия базы, по которой уже сверялись: сверка — на смену версии, а не
    /// на каждую ревизию (её двигают и отметки водителей каждые 75 с).
    @ObservationIgnored private var checkedVersion: Int?

    nonisolated private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("road_cells.json")
    }

    init() {
        Task { await load() }
    }

    private func load() async {
        let url = Self.fileURL
        let loaded = await Task.detached(priority: .utility) {
            JSONFile.load(RoadCells.self, from: url, log: Log.trips)
        }.value
        roads = loaded ?? RoadCells()
        isLoaded = true
        // Поездки, закончившиеся до чтения файла, — поверх прочитанного.
        let queued = pendingTracks
        pendingTracks = []
        for (track, date) in queued { roads.add(track, on: date) }
        if !queued.isEmpty { save() }
    }

    /// Поездка сохранена: её дорога — «своя».
    func note(track: [(lat: Double, lon: Double)], on date: Date) {
        guard track.count >= 2 else { return }
        guard isLoaded else { pendingTracks.append((track, date)); return }
        roads.add(track, on: date)
        roads.prune(now: date)
        save()
    }

    /// Первый запуск с этой возможностью: свои дороги — из треков, что ещё
    /// лежат в истории (неделя). Дальше память копится поездками.
    func seedIfEmpty(from history: [TripRecord]) {
        guard isLoaded, roads.isEmpty else { return }
        for record in history where record.hasTrack {
            roads.add(record.trackPoints.map { ($0.lat, $0.lon) }, on: record.startedAt)
        }
        guard !roads.isEmpty else { return }
        roads.prune(now: Date())
        save()
    }

    /// База камер прочитана или обновилась: сверить с виденным набором.
    /// `points` — камеры БАЗЫ (без своих и отметок водителей).
    func refresh(points: [CameraNews.Point], version: Int, now: Date = Date()) async {
        guard checkedVersion != version else { return }
        // Свои дороги нужны до сравнения: без них «новых на ваших дорогах» нет.
        while !isLoaded { await Task.pause(seconds: 0.2) }
        checkedVersion = version
        let known = Storage.decoded([Int].self, for: .cameraKnownIDs)
        if let update = CameraNews.update(known: known, current: points, roads: roads, now: now) {
            Storage.encode(update.known, for: .cameraKnownIDs)
            if !update.found.isEmpty {
                news = (news + update.found).sorted { $0.found > $1.found }
                Storage.encode(news, for: .cameraNews)
                Log.cameras.notice("новые камеры на своих дорогах: \(update.found.count, privacy: .public)")
            }
        }
        // Камеры, снятые с базы, и старые новости — долой.
        let visible = CameraNews.visible(news, existing: Set(points.map(\.id)), now: now)
        if visible != news {
            news = visible
            Storage.encode(news, for: .cameraNews)
        }
    }

    /// «Понятно» на карточке.
    func dismissNews() {
        news = []
        Storage.remove(.cameraNews)
    }

    /// «Удалить всю историю»: память дорог — производное от поездок.
    func eraseRoads() {
        roads = RoadCells()
        news = []
        Storage.remove(.cameraNews)
        // Той же очередью, что и запись: стирание не обгонит отложенную запись.
        JSONFile.removeOrdered(at: Self.fileURL, log: Log.trips)
    }

    #if DEBUG
    /// Снимки «Итогов» (`-itogiDemo`): новость без обновления базы.
    func seedDemo(ids: [Int]) {
        news = ids.map { CameraNews.Item(id: $0, found: Date().addingTimeInterval(-3600)) }
    }
    #endif

    private func save() {
        let snapshot = roads
        let url = Self.fileURL
        // Очередь записи общая с остальными JSON-файлами: две поездки подряд
        // не перепишут друг друга в обратном порядке.
        JSONFile.enqueue(wait: false) {
            guard JSONFile.save(snapshot, to: url, log: Log.trips) else { return }
            var file = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            do { try file.setResourceValues(values) } catch {
                Log.trips.error("память дорог: не исключена из копии — \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
