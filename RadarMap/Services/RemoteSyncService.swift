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
        // Правки модератора идут своим темпом и не зависят от того, вышла ли
        // новая база: файл в 2 КБ, а «камеры больше нет» ждать сутки не должно.
        await checkOverridesIfNeeded()
        if let last = lastCheckDate,
           Date().timeIntervalSince(last) < AppConfig.syncCheckInterval { return }
        await check()
    }

    // MARK: - Правки модератора (overrides.json)

    func checkOverridesIfNeeded() async {
        if let last = Storage.date(.overridesCheck),
           Date().timeIntervalSince(last) < AppConfig.overridesCheckInterval { return }
        await checkOverrides()
    }

    func checkOverrides() async {
        do {
            let envelope = try await api.get(AppConfig.cameraOverridesPath,
                                             as: CameraOverridesEnvelope.self)
            guard let overrides = envelope.verified() else {
                // Правки применяются без участия пользователя и умеют гасить
                // камеры — неподписанным верить нельзя ни при каких условиях.
                Log.cameras.error("правки: подпись не сошлась — не применяю")
                Storage.set(Date(), for: .overridesCheck)
                return
            }
            if store.applyOverrides(overrides) {
                Storage.set(Date(), for: .overridesCheck)
            }
        } catch {
            // Файла нет (правок пока не публиковали) или сети нет — обычное
            // дело, живём на том, что уже применено. Дату не двигаем.
            Log.cameras.debug("правки не загрузились: \(error.localizedDescription, privacy: .public)")
        }
    }

    private struct Manifest: Decodable {
        let version: Int
        let count: Int
        /// Ed25519-подпись cameras.json (base64). Нет подписи — базу не применяем.
        let sig: String?
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
            // Подпись обязательна: неподписанная/подменённая база не применяется
            // (защита от MITM на HTTP и от компрометации сервера).
            guard OTASignature.isValid(data: payload, signatureB64: manifest.sig) else {
                Log.network.error("синк базы: подпись не сошлась — обновление отклонено")
                lastError = String(localized: "Подпись базы не прошла проверку")
                state = .failed
                return
            }
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
