//
//  TileReleaseStore.swift
//  RadarMap
//
//  Подписанный корень выпуска тайлов и корзины его индекса — с сервера, с
//  диска и из памяти. Сеть и диск для `TileRelease`; правила — там.
//
//  Порядок доверия тот же, что у всего, что применяется без спроса
//  (ARCHITECTURE.md, правило 19): корень проверяется подписью при КАЖДОМ
//  чтении, в том числе с диска, корзина — sha256 из корня при каждом чтении.
//  Любая неисправность — отказ: без корня карта на новом стиле не грузит ни
//  одного тайла, и это правильный отказ (пустая карта честнее подделанной).
//
//  Офлайн: корень и уже виденные корзины лежат в Application Support и
//  переживают перезапуск — поездка без связи продолжает рисоваться из кэша
//  движка, а сторож по-прежнему может сверить каждый тайл.
//

import CryptoKit
import Foundation
import os

actor TileReleaseStore {

    nonisolated static let shared = TileReleaseStore()

    /// Текущий проверенный корень. Читается синхронно сторожем движка, поэтому
    /// копия живёт и под замком, а не только внутри актора.
    nonisolated static var current: TileRelease? { currentLock.withLock { $0 } }
    private nonisolated static let currentLock = OSAllocatedUnfairLock(initialState: TileRelease?.none)

    private let base: URL
    private let session: URLSession
    private var buckets: [String: TileDigestIndex] = [:]
    private var recent: [String] = []
    private var inflight: [String: Task<TileDigestIndex?, Never>] = [:]
    private var refreshed: Date?

    init(base: URL = AppConfig.syncBaseURL) {
        self.base = base
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = AppConfig.tileReleaseRequestTimeout
        session = URLSession(configuration: configuration)
    }

    // MARK: - Корень

    /// Корень выпуска: свежий с сервера не чаще раза в `tileReleaseRefresh`,
    /// иначе — проверенный с диска. nil — ни того, ни другого.
    @discardableResult
    func prepare() async -> TileRelease? {
        if let current = Self.current, let refreshed,
           Date().timeIntervalSince(refreshed) < AppConfig.tileReleaseRefresh {
            return current
        }
        if Self.current == nil, let cached = Self.readRoot() { adopt(cached) }
        let url = URL(string: "\(TileRelease.root(base))/\(AppConfig.tileReleaseRootName)")!
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let release = Self.verify(data) else {
                Log.network.error("корень выпуска тайлов не прошёл проверку — остаёмся на прежнем")
                return Self.current
            }
            refreshed = Date()
            if release != Self.current {
                adopt(release)
                Self.writeRoot(data)
                Log.network.info("выпуск тайлов v\(release.version, privacy: .public) принят")
            }
        } catch {
            Log.network.error("корень выпуска тайлов не пришёл: \(error.localizedDescription, privacy: .public)")
        }
        return Self.current
    }

    /// Корень с диска — синхронно, до первого стиля. Без этого карта на
    /// каждом открытии грузила стиль дважды (прежний, потом новый — с
    /// миганием). Проверка подписи та же, что у сети; становится текущим,
    /// только если текущего ещё нет, — сеть позже сменит его по правилам.
    nonisolated static func restoredFromDisk() -> TileRelease? {
        if let current { return current }
        guard let cached = readRoot() else { return nil }
        currentLock.withLock { if $0 == nil { $0 = cached } }
        return current
    }

    private func adopt(_ release: TileRelease) {
        if Self.current?.version != release.version {
            buckets.removeAll()
            recent.removeAll()
        }
        Self.currentLock.withLock { $0 = release }
    }

    /// Конверт → проверенный корень. Подпись — до разбора JSON (SignedPayload).
    nonisolated static func verify(_ data: Data) -> TileRelease? {
        // Битый конверт — nil: сетевой путь пишет «не прошёл проверку» сам, а битый файл на диске — просто нет корня.
        guard let envelope = try? JSONDecoder().decode(SignedPayload<TileRelease>.self, from: data),
              let release = envelope.verified(), !release.sets.isEmpty else { return nil }
        return release
    }

    // MARK: - Корзины

    /// Индекс корзины тайла, проверенный по корню. nil — корзины нет в корне
    /// (тайла нет вовсе) либо её не удалось получить целой.
    func bucket(for tile: TileRelease.Tile) async -> (exists: Bool, index: TileDigestIndex?) {
        guard let release = Self.current, release.version == tile.version,
              let (name, digest) = release.bucketDigest(for: tile) else { return (false, nil) }
        let key = "\(tile.set)/\(name)"
        if let index = buckets[key] {
            touch(key)
            return (true, index)
        }
        if let running = inflight[key] { return (true, await running.value) }
        let task = Task { [base, session] () -> TileDigestIndex? in
            if let data = Self.readBucket(version: release.version, key: key),
               let index = Self.parse(data, digest: digest) {
                return index
            }
            let url = release.bucketURL(base: base, set: tile.set, name: name)
            // Сбой сети и сбой проверки — одна строка журнала ниже, по ключу корзины.
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let index = Self.parse(data, digest: digest) else {
                Log.network.error("корзина \(key, privacy: .public) не прошла проверку")
                return nil
            }
            Self.writeBucket(data, version: release.version, key: key)
            return index
        }
        inflight[key] = task
        let index = await task.value
        inflight[key] = nil
        if let index, Self.current?.version == release.version {
            buckets[key] = index
            touch(key)
        }
        return (true, index)
    }

    private func touch(_ key: String) {
        recent.removeAll { $0 == key }
        recent.append(key)
        while recent.count > AppConfig.tileReleaseBucketsInMemory {
            buckets[recent.removeFirst()] = nil
        }
    }

    /// Байты корзины → индекс, только если sha256 совпал с корнем.
    nonisolated static func parse(_ data: Data, digest: String) -> TileDigestIndex? {
        guard hex(SHA256.hash(data: data)) == digest.lowercased() else { return nil }
        return TileDigestIndex(serialized: data)
    }

    nonisolated static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Освободить корзины по просьбе системы (MemoryPressure): они соберутся
    /// заново с диска, не с сети.
    func releaseMemory() {
        buckets.removeAll()
        recent.removeAll()
    }

    // MARK: - Диск

    private nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TileRelease", isDirectory: true)
        // Не создалась — запись корзины/корня упадёт следом и попадёт в журнал там.
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private nonisolated static func readRoot() -> TileRelease? {
        // Файла нет — первый запуск, не ошибка; битый отсеет подпись в verify.
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("root.json")) else { return nil }
        return verify(data)
    }

    private nonisolated static func writeRoot(_ data: Data) {
        do {
            try data.write(to: directory.appendingPathComponent("root.json"), options: .atomic)
        } catch {
            Log.network.error("корень выпуска не сохранился: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func bucketFile(version: Int, key: String) -> URL {
        directory.appendingPathComponent("\(version)", isDirectory: true)
            .appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".bin")
    }

    private nonisolated static func readBucket(version: Int, key: String) -> Data? {
        // Файла нет — промах кэша: корзину скачают и проверят.
        try? Data(contentsOf: bucketFile(version: version, key: key))
    }

    private nonisolated static func writeBucket(_ data: Data, version: Int, key: String) {
        let file = bucketFile(version: version, key: key)
        do {
            // Прежние выпуски на диске не нужны: корень один, и их корзины
            // уже никогда не совпадут с ним.
            let folder = file.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: folder.path) {
                let root = folder.deletingLastPathComponent()
                // Каталога ещё нет — чистить нечего.
                for old in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
                where Int(old) != nil && old != "\(version)" {
                    // Чистка старья: не удалилось — уберётся при следующем выпуске, корзины текущего не задевает.
                    try? FileManager.default.removeItem(at: root.appendingPathComponent(old))
                }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try data.write(to: file, options: .atomic)
        } catch {
            Log.network.error("корзина не сохранилась: \(error.localizedDescription, privacy: .public)")
        }
    }
}
