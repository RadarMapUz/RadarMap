//
//  TripHistorySettingsPage.swift
//  RadarMap
//
//  Настройки → Поездка → «История поездок» (15.3): выгрузить всё одним
//  архивом и стереть всё одним действием. Здесь же встанут «Хранить
//  историю» (15.2) и iCloud (15.4).
//
//  Подтверждение удаления — EraseHistorySheet (15.6), тот же лист, что
//  у «Очистить историю» в «Итогах».
//
//  Выгрузка — архив во временной папке: он живёт ровно до закрытия окна
//  «Поделиться», дальше в нём вся история человека, лежащая без дела.
//

import SwiftUI
import os

struct TripHistorySettingsPage: View {
    @Environment(AppEnvironment.self) private var env

    @State private var exporting = false
    @State private var share: ShareFilePayload?
    /// Папка выгрузки — удаляется, когда окно «Поделиться» закрыто.
    @State private var exportFolder: URL?
    @State private var exportFailed = false
    @State private var confirmsErase = false
    @State private var erased = false

    var body: some View {
        let trip = env.trip
        // Пока история не прочитана (сразу после разблокировки), выгрузка
        // вышла бы пустой, а удаление — мимо диска (ревью S9).
        let ready = trip.isLoaded && trip.isLifetimeTrusted
        let canExport = ready && !exporting && trip.storedTripCount > 0
        Form {
            Section {
                LabeledContent("Поездок на телефоне") {
                    Text(Formatting.decimal(Double(trip.storedTripCount), digits: 0))
                }
                Button {
                    export()
                } label: {
                    HStack {
                        // Цвет задан явно — значит, и «недоступно» тоже явно.
                        Label("Экспорт всех поездок", systemImage: "square.and.arrow.up")
                            .foregroundStyle(canExport ? Theme.textPrimary : Theme.textTertiary)
                        Spacer()
                        if exporting { ProgressView() }
                    }
                }
                .disabled(!canExport)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Архив ZIP: таблица trips.csv — строка на поездку — и треки GPX тех поездок, у которых трек ещё хранится. Дом и работа в них не подписаны. Отдельно — commute_forecast.csv, точность прогноза дороги на работу: по нему поездки дом↔работа узнаются.")
                    if exportFailed {
                        Label("Архив не собрался — попробуйте ещё раз", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button(role: .destructive) {
                    confirmsErase = true
                } label: {
                    // Значок — тем же красным, что и текст: системный красит
                    // его акцентом, и строка читалась наполовину синей.
                    Label("Удалить всю историю", systemImage: "trash")
                        .foregroundStyle(Theme.danger)
                }
                .disabled(!ready)
            } footer: {
                if erased {
                    Label("История удалена", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                } else {
                    Text("Поездки и всё, что из них посчитано. Настройки остаются.")
                }
            }
        }
        .settingsPage("История поездок")
        .sheet(item: $share, onDismiss: removeExport) { payload in
            ActivityFileSheet(url: payload.url)
                .presentationDetents([.medium, .large])
        }
        // Списки «Удалится» / «Останется» листом (15.6): системное
        // подтверждение с тем же перечнем было узким облачком-абзацем.
        .sheet(isPresented: $confirmsErase) {
            EraseHistorySheet { erased = true }
        }
        #if DEBUG
        // Снимки без касаний: `-settingsPage history -confirmErase` —
        // подтверждение, `-exportHistory` — выгрузка до окна «Поделиться».
        .task {
            let args = ProcessInfo.processInfo.arguments
            guard args.contains("-confirmErase") || args.contains("-exportHistory") else { return }
            await Task.pause(seconds: 1)
            if args.contains("-confirmErase") { confirmsErase = true } else { export() }
        }
        #endif
    }

    private func export() {
        exporting = true
        exportFailed = false
        erased = false
        Task {
            defer { exporting = false }
            // Месяцы, не прочитанные на старте, — тоже: выгрузка обещает всё.
            await env.trip.loadAllMonths()
            do {
                let archive = try await TripExport.makeArchive(env.trip.history,
                                                               forecasts: env.commuteProfiles.accuracy,
                                                               now: Date(),
                                                               timeZone: .current)
                exportFolder = archive.folder
                share = ShareFilePayload(url: archive.file)
            } catch {
                // Причина — в журнале (TripExport); человеку — что делать.
                exportFailed = true
            }
        }
    }

    private func removeExport() {
        guard let folder = exportFolder else { return }
        exportFolder = nil
        Task.detached(priority: .utility) { TripExport.remove(folder) }
    }
}
