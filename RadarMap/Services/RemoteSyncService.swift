//
//  RemoteSyncService.swift
//  RadarMap
//
//  OTA-обновление базы камер: раз в сутки (или вручную из настроек) сравниваем
//  версию на сервере с локальной; при новой версии скачиваем, валидируем и
//  атомарно подменяем базу. Без сети приложение работает на локальной копии.
//

import CryptoKit
import Foundation
import Observation
import os

@MainActor
@Observable
final class RemoteSyncService {

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
    enum SyncState: Equatable {
        case idle, checking, downloading, upToDate
        case updated(count: Int)
        case failed
    }

    /// Почему не обновилось — для строки в настройках: «нет сети» и «подпись
    /// не сошлась» требуют от человека разного.
    nonisolated enum Failure: Equatable {
        case network, server, signature, rejected, storage

        var message: String {
            switch self {
            case .network: String(localized: "Ошибка сети")
            case .server: String(localized: "Сервер базы не ответил")
            case .signature: String(localized: "Подпись базы не прошла проверку")
            case .rejected: String(localized: "Обновление базы отклонено проверкой")
            case .storage: String(localized: "Базу не удалось сохранить на телефоне")
            }
        }

        var symbol: String {
            switch self {
            case .network: "wifi.slash"
            case .server: "server.rack"
            case .signature, .rejected: "exclamationmark.shield"
            case .storage: "externaldrive.badge.exclamationmark"
            }
        }
    }

    private(set) var state: SyncState = .idle
    private(set) var failure: Failure?

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
        /// sha256 опубликованного файла (sign_db.sh): по нему видно, что
        /// скачали не тот файл (кэш, недовыкладка, прокси), а не плохую базу.
        let sha256: String?
    }

    /// `force` — кнопка «Проверить» в настройках: отказ, запомненный раньше,
    /// её не останавливает.
    func check(force: Bool = false) async {
        guard state != .checking && state != .downloading else { return }
        state = .checking
        failure = nil
        do {
            let manifest = try await api.get("version.json", as: Manifest.self)

            guard manifest.version > store.dbVersion else {
                Storage.set(Date(), for: .lastSyncCheck)
                state = .upToDate
                return
            }
            // Этот самый файл уже скачивали и отвергли (подпись, разбор):
            // мегабайт заново на каждой активации ничего не изменит (S23).
            // Ключ — сборка, версия И подпись: перевыпуск под тем же номером,
            // новая сборка или настоящая N+1 после чужого манифеста с N+1 —
            // новая попытка (ревью S23).
            let key = Self.rejectionKey(version: manifest.version, sig: manifest.sig, build: Self.build)
            if !force, Storage.string(.rejectedDB) == key {
                Storage.set(Date(), for: .lastSyncCheck)
                failure = .rejected
                state = .failed
                return
            }

            state = .downloading
            let payload = try await api.getData("cameras.json")
            // Байты не те, что опубликованы (устаревший кэш, файл ещё
            // выкладывается, прокси) — это сбой доставки, а не плохая база:
            // отказ не запоминаем, попробуем в следующий срок (ревью S23).
            if let expected = manifest.sha256?.lowercased(), await Self.sha256(payload) != expected {
                Log.network.error("синк базы: sha256 скачанного не совпал с манифестом — не та выкладка")
                Storage.set(Date(), for: .lastSyncCheck)
                failure = .server
                state = .failed
                return
            }
            // Подпись обязательна: неподписанная/подменённая база не применяется
            // (защита от MITM на HTTP и от компрометации сервера).
            guard OTASignature.isValid(data: payload, signatureB64: manifest.sig) else {
                Log.network.error("синк базы: подпись не сошлась — обновление отклонено")
                reject(key)
                failure = .signature
                state = .failed
                return
            }
            let count: Int
            do throws(RemoteDBError) {
                count = try await store.applyRemote(data: payload, version: manifest.version)
            } catch {
                Log.network.error("синк базы: не применена — \(String(describing: error), privacy: .public)")
                if error.isPayloadDefect {
                    // Подписанная, но негодная (разбор, мало камер) — этот файл
                    // не качать заново.
                    reject(key)
                    failure = .rejected
                } else {
                    // Не записалась (место) — база ни при чём: попробуем в
                    // следующий срок, а кнопка — хоть сейчас.
                    Storage.set(Date(), for: .lastSyncCheck)
                    failure = .storage
                }
                state = .failed
                return
            }

            Storage.remove(.rejectedDB)
            Storage.set(Date(), for: .lastSyncCheck)
            state = .updated(count: count)
        } catch {
            Log.network.error("синк базы: \(error.localizedDescription, privacy: .public)")
            failure = Self.failure(for: error)
            state = .failed
        }
    }

    private func reject(_ key: String) {
        Storage.set(key, for: .rejectedDB)
        Storage.set(Date(), for: .lastSyncCheck)
    }

    @concurrent
    private static func sha256(_ data: Data) async -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func rejectionKey(version: Int, sig: String?, build: String) -> String {
        "\(build)|\(version)|\(sig ?? "-")"
    }

    /// Сбой до скачивания базы: сеть или сервер (статус, кривой version.json).
    nonisolated static func failure(for error: Error) -> Failure {
        switch error {
        case APIClient.Failure.badStatus, is DecodingError: .server
        default: .network
        }
    }

    /// Версия и сборка: номер сборки в App Store Connect может повториться
    /// при новой версии.
    private static var build: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "0")(\(info?["CFBundleVersion"] as? String ?? "0"))"
    }
}
