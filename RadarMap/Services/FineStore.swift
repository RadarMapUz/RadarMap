//
//  FineStore.swift
//  RadarMap
//
//  Пришедшие штрафы на диске (этап 17): Documents/received_fines.json. Только
//  телефон — сюда ничего не приходит из сети и отсюда ничего не уходит;
//  госномера в файле нет (ReceivedFine его не хранит).
//
//  Правила те же, что у истории поездок (сценарий S9, 20.10): файл, который
//  есть, но не читается (процесс подняли до первой разблокировки), — не
//  «пусто»: поверх него не пишем, пока не прочтём. Битый штраф выбрасывается
//  поштучно (LossyArray), а файл с ним откладывается рядом копией.
//  Внесённое до чтения не теряется: при чтении оно ложится поверх диска.
//
//  Решения (сверка, сроки, напоминание) — не здесь: AppEnvironment+Fines.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class FineStore {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    private(set) var fines: [ReceivedFine] = []
    /// Файл прочитан (или его нет). До этого на диск не пишем.
    @ObservationIgnored private(set) var isLoaded = false
    /// Внесённое или правленное до чтения файла — id, которые главнее диска.
    @ObservationIgnored private var editedBeforeLoad: Set<UUID> = []
    @ObservationIgnored private var removedBeforeLoad: Set<UUID> = []
    @ObservationIgnored private var loading = false
    #if DEBUG
    /// Демо для снимков экрана: в память, не на диск.
    @ObservationIgnored private(set) var isDemo = false
    #endif

    init() {
        Task { await load() }
    }

    func fine(_ id: UUID) -> ReceivedFine? {
        fines.first { $0.id == id }
    }

    /// Новый штраф или правка — по id.
    func upsert(_ fine: ReceivedFine) {
        if let index = fines.firstIndex(where: { $0.id == fine.id }) {
            fines[index] = fine
        } else {
            fines.append(fine)
        }
        if !isLoaded { editedBeforeLoad.insert(fine.id) }
        persist()
    }

    func remove(_ id: UUID) {
        fines.removeAll { $0.id == id }
        if !isLoaded {
            editedBeforeLoad.remove(id)
            removedBeforeLoad.insert(id)
        }
        persist()
    }

    /// Экран штрафов открыт — файл, не прочитанный на старте, читаем сейчас.
    func reloadIfNeeded() {
        guard !isLoaded else { return }
        Task { await load() }
    }

    // MARK: - Диск

    nonisolated private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("received_fines.json")
    }

    private func load() async {
        guard !isLoaded, !loading else { return }
        loading = true
        defer { loading = false }
        let result = await Self.read()
        var disk: [ReceivedFine] = []
        switch result {
        case .missing:
            break
        case .loaded(let lossy):
            disk = lossy.elements
            if lossy.dropped > 0 {
                Log.trips.fault("штрафы: битых записей \(lossy.dropped, privacy: .public): \(lossy.firstError ?? "", privacy: .public)")
                // Копия рядом: выброшенное ещё можно вернуть руками.
                guard JSONFile.setAside(Self.url, copy: true, log: Log.trips) else { return }
            }
        case .corrupt:
            guard JSONFile.setAside(Self.url, log: Log.trips) else { return }
        case .unreadable:
            // Не читается — не загружено: следующий заход на экран попробует снова.
            return
        }
        #if DEBUG
        if isDemo { isLoaded = true; return }
        #endif
        // Внесённое до чтения — поверх прочитанного.
        let local = fines.filter { editedBeforeLoad.contains($0.id) }
        var merged = disk.filter { !removedBeforeLoad.contains($0.id) && !editedBeforeLoad.contains($0.id) }
        merged.append(contentsOf: local)
        fines = merged
        isLoaded = true
        let hadLocal = !editedBeforeLoad.isEmpty || !removedBeforeLoad.isEmpty
        editedBeforeLoad = []
        removedBeforeLoad = []
        if hadLocal { persist() }
    }

    @concurrent private nonisolated static func read() async -> JSONFile.LoadResult<LossyArray<ReceivedFine>> {
        JSONFile.loadChecked(LossyArray<ReceivedFine>.self, from: url, log: Log.trips)
    }

    private func persist() {
        #if DEBUG
        if isDemo { return }
        #endif
        guard isLoaded else {
            Log.trips.notice("штрафы не записаны: файл ещё не прочитан — допишем после чтения")
            return
        }
        JSONFile.saveOrdered(fines, to: Self.url, log: Log.trips, wait: false)
    }

    #if DEBUG
    /// Снимки экрана (`-demoFines`): готовые штрафы в памяти, диск не трогаем.
    func seedDemo(_ demo: [ReceivedFine]) {
        isDemo = true
        isLoaded = true
        fines = demo
    }
    #endif
}
