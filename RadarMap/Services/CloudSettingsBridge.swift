//
//  CloudSettingsBridge.swift
//  RadarMap
//
//  Настройки ↔ NSUbiquitousKeyValueStore (27.F). Решения — CloudSettingsSync
//  (чисто), список — AppSettings.cloudSettingKinds. Работает, только пока
//  включено «Хранить поездки: в iCloud».
//
//  Без прав на хранилище (профиль без iCloud) NSUbiquitousKeyValueStore
//  ничего не синхронизирует и не падает — настройки просто остаются на
//  телефоне.
//
//  Своя правка ловится по UserDefaults.didChangeNotification и сверяется с
//  отправленным не чаще раза в несколько секунд: уведомление приходит на
//  любую запись в UserDefaults, а сверка — тридцать чтений.
//

import Foundation
import os

@MainActor
final class CloudSettingsBridge {
    nonisolated deinit {}

    private let settings: AppSettings
    private var observers: [NSObjectProtocol] = []
    private var pushScheduled = false
    private var applying = false
    private(set) var isRunning = false
    private var store: NSUbiquitousKeyValueStore { .default }

    init(settings: AppSettings) {
        self.settings = settings
    }

    private var pushed: [String: CloudSettingValue] {
        get { Storage.decoded([String: CloudSettingValue].self, for: .cloudSettingsPushed) ?? [:] }
        set { Storage.encode(newValue, for: .cloudSettingsPushed) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                            object: NSUbiquitousKeyValueStore.default, queue: .main) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            MainActor.assumeIsolated { self?.received(keys: keys, reason: reason) }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.localChanged() }
        })
        if !store.synchronize() {
            Log.cloud.notice("настройки iCloud: хранилище не синхронизировалось (нет прав или iCloud выключен)")
        }
        initialMerge()
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        isRunning = false
    }

    /// «Удалить копию из iCloud»: свои ключи из хранилища — прочь.
    func removeCloudCopy() {
        for key in AppSettings.cloudSettingKinds.keys {
            store.removeObject(forKey: CloudSettingsSync.prefix + key)
        }
        Storage.remove(.cloudSettingsPushed)
        if !store.synchronize() {
            Log.cloud.notice("настройки iCloud: удаление отправится позже")
        }
    }

    // MARK: - Сверка

    private func remoteSnapshot() -> [String: CloudSettingValue] {
        var result: [String: CloudSettingValue] = [:]
        for (key, kind) in AppSettings.cloudSettingKinds {
            if let value = CloudSettingsSync.value(from: store.object(forKey: CloudSettingsSync.prefix + key), kind: kind) {
                result[key] = value
            }
        }
        return result
    }

    private func initialMerge() {
        let local = settings.cloudSettingsSnapshot()
        if pushed.isEmpty {
            let plan = CloudSettingsSync.initial(local: local, remote: remoteSnapshot())
            apply(plan.apply)
            write(plan.push)
            var sent = remoteSnapshot()
            sent.merge(plan.push) { _, new in new }
            pushed = sent
        } else {
            // Уже включалось: пришедшее за время простоя — сверху, своё — следом.
            apply(CloudSettingsSync.toApply(remote: remoteSnapshot(), local: local)
                .filter { pushed[$0.key] != $0.value })
            pushLocal()
        }
    }

    private func received(keys: [String], reason: Int?) {
        guard isRunning else { return }
        if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
            Log.cloud.error("настройки iCloud: превышена квота хранилища")
            return
        }
        let remote = remoteSnapshot().filter { keys.contains(CloudSettingsSync.prefix + $0.key) }
        guard !remote.isEmpty else { return }
        apply(CloudSettingsSync.toApply(remote: remote, local: settings.cloudSettingsSnapshot()))
        var sent = pushed
        sent.merge(remote) { _, new in new }
        pushed = sent
    }

    private func apply(_ values: [String: CloudSettingValue]) {
        guard !values.isEmpty else { return }
        applying = true
        defer { applying = false }
        settings.applyCloudSettings(values)
        Log.cloud.info("настройки из iCloud: \(values.count, privacy: .public)")
    }

    private func localChanged() {
        guard isRunning, !applying, !pushScheduled else { return }
        pushScheduled = true
        Task { @MainActor [weak self] in
            await Task.pause(seconds: 3)
            self?.pushScheduled = false
            self?.pushLocal()
        }
    }

    private func pushLocal() {
        guard isRunning else { return }
        let changes = CloudSettingsSync.toPush(local: settings.cloudSettingsSnapshot(), pushed: pushed)
        guard !changes.isEmpty else { return }
        write(changes)
        var sent = pushed
        sent.merge(changes) { _, new in new }
        pushed = sent
    }

    private func write(_ values: [String: CloudSettingValue]) {
        for (key, value) in values {
            store.set(CloudSettingsSync.object(value), forKey: CloudSettingsSync.prefix + key)
        }
    }
}
