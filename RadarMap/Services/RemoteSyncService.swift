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
import os

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
    @ObservationIgnored private let api = APIClient(timeout: 15, resourceTimeout: 60)

    init(store: CameraStore) {
        self.store = store
    }

    var lastCheckDate: Date? {
        Storage.date(.lastSyncCheck)
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
            let manifest = try await api.get("version.json", as: Manifest.self)

            guard manifest.version > store.dbVersion else {
                Storage.set(Date(), for: .lastSyncCheck)
                state = .upToDate
                return
            }

            state = .downloading
            let payload = try await api.getData("cameras.json")
            let count = try await store.applyRemote(data: payload, version: manifest.version)

            Storage.set(Date(), for: .lastSyncCheck)
            state = .updated(count: count)
        } catch {
            Log.network.error("синк базы: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            state = .failed
        }
    }
}
