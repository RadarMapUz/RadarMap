//
//  EnergyJournalStore.swift
//  RadarMap
//
//  Журнал заправок и зарядок на диске (21.6): Documents/energy_journal.json.
//  Только телефон — сюда ничего не приходит из сети и отсюда ничего не
//  уходит, кроме «Экспорта всех поездок», который человек отправляет сам.
//
//  Правила — те же, что у пришедших штрафов (FineStore, сценарий S9):
//  файл, который есть, но не читается (процесс поднят до первой
//  разблокировки), — не «пусто»: поверх него не пишем, пока не прочтём.
//  Нет файла — пустой журнал (так у всех до 21.6). Битая запись
//  выбрасывается поштучно, а файл с ней откладывается рядом копией.
//  Внесённое до чтения ложится поверх диска.
//
//  Решения (цена профиля, правдоподобие) — не здесь: EnergyJournal и
//  AppEnvironment+EnergyJournal.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class EnergyJournalStore {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    private(set) var entries: [JournalEntry] = []
    /// Файл прочитан (или его нет). До этого на диск не пишем.
    @ObservationIgnored private(set) var isLoaded = false
    @ObservationIgnored private var editedBeforeLoad: Set<UUID> = []
    @ObservationIgnored private var removedBeforeLoad: Set<UUID> = []
    /// «Удалить всю историю» до чтения файла: прочитанное — выбросить.
    @ObservationIgnored private var erasedBeforeLoad = false
    @ObservationIgnored private var loading = false
    /// Файл прочитан — вешает AppEnvironment (перенос «Машины и расходов»).
    @ObservationIgnored var onLoaded: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onLoaded,
                                               "EnergyJournalStore.onLoaded") }
    }
    #if DEBUG
    /// Демо для снимков экрана: в память, не на диск.
    @ObservationIgnored private(set) var isDemo = false
    #endif

    init() {
        Task { await load() }
    }

    /// Новая запись или правка — по id.
    func upsert(_ entry: JournalEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        if !isLoaded { editedBeforeLoad.insert(entry.id) }
        persist()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if !isLoaded {
            editedBeforeLoad.remove(id)
            removedBeforeLoad.insert(id)
        }
        persist()
    }

    /// Всё стереть («Удалить всю историю»): и память, и файл.
    func eraseAll() {
        entries = []
        editedBeforeLoad = []
        removedBeforeLoad = []
        #if DEBUG
        if isDemo { return }
        #endif
        guard isLoaded else {
            // Файл ещё не прочитан — прочитанное потом выбросим, а файл сотрём.
            erasedBeforeLoad = true
            return
        }
        JSONFile.removeOrdered(at: Self.url, log: Log.trips)
    }

    /// Экран журнала открыт — файл, не прочитанный на старте, читаем сейчас.
    func reloadIfNeeded() {
        guard !isLoaded else { return }
        Task { await load() }
    }

    // MARK: - Диск

    nonisolated static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("energy_journal.json")
    }

    /// Что прочитано с диска: нет файла — пусто, а не ошибка (миграция до 21.6).
    /// nil — читать нельзя (не прочитан или отложен не удался): не загружено.
    nonisolated static func disk(from result: JSONFile.LoadResult<LossyArray<JournalEntry>>,
                                 url: URL, log: Logger) -> [JournalEntry]? {
        switch result {
        case .missing:
            return []
        case .loaded(let lossy):
            if lossy.dropped > 0 {
                log.fault("журнал заправок: битых записей \(lossy.dropped, privacy: .public): \(lossy.firstError ?? "", privacy: .public)")
                // Копия рядом: выброшенное ещё можно вернуть руками.
                guard JSONFile.setAside(url, copy: true, log: log) else { return nil }
            }
            return lossy.elements
        case .corrupt:
            return JSONFile.setAside(url, log: log) ? [] : nil
        case .unreadable:
            // Не читается — не загружено: следующий заход на экран попробует снова.
            return nil
        }
    }

    private func load() async {
        guard !isLoaded, !loading else { return }
        loading = true
        defer { loading = false }
        guard var disk = Self.disk(from: await Self.read(), url: Self.url, log: Log.trips) else { return }
        #if DEBUG
        if isDemo { isLoaded = true; return }
        #endif
        if erasedBeforeLoad { disk = [] }
        let local = entries.filter { editedBeforeLoad.contains($0.id) }
        var merged = disk.filter { !removedBeforeLoad.contains($0.id) && !editedBeforeLoad.contains($0.id) }
        merged.append(contentsOf: local)
        entries = merged
        isLoaded = true
        defer { onLoaded?() }
        let hadLocal = erasedBeforeLoad || !editedBeforeLoad.isEmpty || !removedBeforeLoad.isEmpty
        editedBeforeLoad = []
        removedBeforeLoad = []
        if erasedBeforeLoad, entries.isEmpty {
            erasedBeforeLoad = false
            JSONFile.removeOrdered(at: Self.url, log: Log.trips)
            return
        }
        erasedBeforeLoad = false
        if hadLocal { persist() }
    }

    @concurrent private nonisolated static func read() async -> JSONFile.LoadResult<LossyArray<JournalEntry>> {
        JSONFile.loadChecked(LossyArray<JournalEntry>.self, from: url, log: Log.trips)
    }

    private func persist() {
        #if DEBUG
        if isDemo { return }
        #endif
        guard isLoaded else {
            Log.trips.notice("журнал заправок не записан: файл ещё не прочитан — допишем после чтения")
            return
        }
        JSONFile.saveOrdered(entries, to: Self.url, log: Log.trips, wait: false)
    }

    #if DEBUG
    /// Снимки экрана (`-demoJournal`): готовые записи в памяти, диск не трогаем.
    func seedDemo(_ demo: [JournalEntry]) {
        isDemo = true
        isLoaded = true
        entries = demo
    }
    #endif
}
