//
//  CommuteProfileStore.swift
//  RadarMap
//
//  Где живут профиль дороги по участкам (CommuteProfile) и журнал поездок
//  для «дороги» (CommuteLedger): Application Support/Commute, вне резервной
//  копии — это дом, работа и распорядок дня, их не должно быть ни на
//  сервере, ни в чужой копии телефона. Пересобирается сам из новых поездок,
//  поэтому терять его не страшно.
//
//  Свёртка поездки и запись — вне главного потока (@concurrent): проекция
//  трека на линию варианта — тысячи точек на сотни вершин.
//

import CoreLocation
import Foundation
import os

@MainActor
@Observable
final class CommuteProfileStore {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    private(set) var book = CommuteProfile.Book()
    private(set) var ledger: [CommuteLedger.Entry] = []
    /// Файлы прочитаны: до этого писать нельзя (запись затёрла бы диск пустым).
    @ObservationIgnored private var isLoaded = false
    /// Свёртки по порядку: вторая поездка ждёт, пока первая ляжет в книгу.
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Файлы прочитаны — журнал пора учесть в «дороге» (AppEnvironment).
    @ObservationIgnored var onLoaded: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onLoaded,
                                               "CommuteProfileStore.onLoaded") }
    }

    init() {
        Task { await load() }
    }

    // MARK: - Поездка

    /// Свернуть поездку дом↔работа в профиль. Вызывать только для поездок
    /// направления (решает вызывающий по Commute.trips).
    func ingest(_ track: [CommuteProfile.TimedPoint], record: TripRecord,
                direction: Commute.Direction, limits: LimitIndex?) {
        let stops = (record.stops ?? []).map {
            $0.from.timeIntervalSince1970...max($0.from.timeIntervalSince1970, $0.to.timeIntervalSince1970)
        }
        let previous = pending
        pending = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if !self.isLoaded { await self.load() }
            let book = await Self.folded(self.book, track: track, direction: direction,
                                         tripID: record.id, departure: record.startedAt,
                                         arrival: record.endedAt, stops: stops, limits: limits)
            // Пока сворачивали, выученное стёрли (clear) — не воскрешать.
            guard !Task.isCancelled else { return }
            self.book = book
            await Self.save(book, to: Self.profileURL)
            let rows = book[direction].reduce(0) { $0 + $1.rows.count }
            Log.trips.info("профиль дороги: \(direction.rawValue, privacy: .public), вариантов \(book[direction].count, privacy: .public), строк \(rows, privacy: .public)")
        }
    }

    @concurrent
    private static func folded(_ book: CommuteProfile.Book, track: [CommuteProfile.TimedPoint],
                               direction: Commute.Direction, tripID: Double,
                               departure: Date, arrival: Date,
                               stops: [ClosedRange<Double>], limits: LimitIndex?) async -> CommuteProfile.Book {
        CommuteProfile.fold(track, into: book, direction: direction, tripID: tripID,
                            departure: departure, arrival: arrival, stops: stops,
                            limitAt: limits.map { index in { index.limit(near: $0) } },
                            now: Date())
    }

    // MARK: - Журнал

    /// Журнал после изменившейся истории (финиш, склейка, правка).
    func updateLedger(with history: [TripRecord]) {
        guard isLoaded else { return }
        let next = CommuteLedger.updated(ledger, with: history, now: Date())
        guard next != ledger else { return }
        ledger = next
        Task { await Self.save(next, to: Self.ledgerURL) }
    }

    /// Выключили «Время дороги на работу» — выученное стирается целиком.
    func clear() {
        pending?.cancel()
        book = CommuteProfile.Book()
        ledger = []
        for url in [Self.profileURL, Self.ledgerURL] where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                Log.trips.error("профиль дороги не стёрт: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Диск

    private func load() async {
        guard !isLoaded else { return }
        let (book, ledger) = await Self.read()
        if let book { self.book = book }
        if let ledger { self.ledger = ledger }
        isLoaded = true
        onLoaded?()
    }

    @concurrent
    private static func read() async -> (CommuteProfile.Book?, [CommuteLedger.Entry]?) {
        (JSONFile.load(CommuteProfile.Book.self, from: profileURL, log: Log.trips),
         JSONFile.load([CommuteLedger.Entry].self, from: ledgerURL, log: Log.trips))
    }

    @concurrent
    private static func save<T: Encodable & Sendable>(_ value: T, to url: URL) async {
        prepareDirectory()
        _ = JSONFile.save(value, to: url, log: Log.trips)
    }

    nonisolated private static let directory: URL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Commute", isDirectory: true)
    nonisolated private static let profileURL = directory.appendingPathComponent("profiles.json")
    nonisolated private static let ledgerURL = directory.appendingPathComponent("ledger.json")

    /// Папка — вне резервной копии: один флаг закрывает оба файла.
    nonisolated private static func prepareDirectory() {
        var url = directory
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            Log.trips.error("папка профиля дороги: \(error.localizedDescription, privacy: .public)")
        }
    }
}
