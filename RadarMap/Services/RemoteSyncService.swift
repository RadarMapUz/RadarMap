//
//  RemoteSyncService.swift
//  RadarMap
//
//  OTA-обновление базы камер: раз в сутки (или вручную из настроек) сравниваем
//  версию на сервере с локальной; при новой версии скачиваем, валидируем и
//  атомарно подменяем базу. Без сети приложение работает на локальной копии.
//

import Foundation
import Observation

@MainActor
@Observable
final class RemoteSyncService {
    enum SyncState: Equatable {
        case idle, checking, downloading, upToDate
        case updated(count: Int)
        case failed
    }

    private(set) var state: SyncState = .idle
    private(set) var lastError: String?

    @ObservationIgnored private let store: CameraStore
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let session: URLSession

    private static let lastCheckKey = "lastSyncCheck"

    init(store: CameraStore) {
        self.store = store
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
    }

    var lastCheckDate: Date? {
        defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    /// Тихая автопроверка при запуске — не чаще, чем раз в `syncCheckInterval`.
    func autoCheckIfNeeded() async {
        if let last = lastCheckDate,
           Date().timeIntervalSince(last) < AppConfig.syncCheckInterval { return }
        await check()
    }

    private struct Manifest: Decodable {
        let version: Int
        let count: Int
    }

    func check() async {
        guard state != .checking && state != .downloading else { return }
        state = .checking
        lastError = nil
        do {
            let manifestURL = AppConfig.syncBaseURL.appendingPathComponent("version.json")
            let (data, _) = try await session.data(from: manifestURL)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)

            guard manifest.version > store.dbVersion else {
                defaults.set(Date(), forKey: Self.lastCheckKey)
                state = .upToDate
                return
            }

            state = .downloading
            let dbURL = AppConfig.syncBaseURL.appendingPathComponent("cameras.json")
            let (payload, _) = try await session.data(from: dbURL)
            let count = try await store.applyRemote(data: payload, version: manifest.version)

            defaults.set(Date(), forKey: Self.lastCheckKey)
            state = .updated(count: count)
        } catch {
            lastError = error.localizedDescription
            state = .failed
        }
    }
}
