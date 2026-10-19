//
//  BackupSection.swift
//  RadarMap
//
//  «Мои данные» в настройках: сохранить копию и восстановить из файла.
//
//  Экран сознательно скучный. Это не функция, которой пользуются, — это
//  страховка, и всё, что ей нужно, это две понятные кнопки и честный ответ.
//  Единственное украшение здесь уместное — цифра «сколько записей»: человек
//  должен видеть, что именно он сохраняет, прежде чем поверить файлу.
//
//  Импорт всегда ОБЪЕДИНЯЕТ (правила — в TripBackupMerge) и потому не имеет
//  разрушительного исхода: нет состояния, в котором «восстановил и потерял».
//  Поэтому и подтверждения перед импортом нет — оно защищало бы от того, чего
//  не может случиться, и лишь заставляло бы читать текст.
//

import os
import SwiftUI
import UniformTypeIdentifiers

struct BackupSection: View {
    @Environment(AppEnvironment.self) private var env

    @State private var exporting = false
    @State private var document: BackupDocument?
    @State private var importing = false
    @State private var report: String?
    @State private var failure: String?

    var body: some View {
        Section {
            Group {
                Button {
                    document = BackupDocument(backup: env.makeBackup())
                    exporting = true
                } label: {
                    row(title: String(localized: "Сохранить копию"), symbol: "square.and.arrow.up")
                }

                Button {
                    importing = true
                } label: {
                    row(title: String(localized: "Восстановить из файла"), symbol: "square.and.arrow.down")
                }
            }
            // Пока история не прочитана (сразу после разблокировки), копия
            // вышла бы пустой, а слияние — поверх пустоты (ревью S9).
            .disabled(!env.trip.isLoaded || !env.trip.isLifetimeTrusted)
        } header: {
            Text("Мои данные")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("История поездок хранится только на этом телефоне и никуда не отправляется. Копия — единственный способ перенести её на новый телефон или вернуть после сброса.")
                if let report {
                    Label(report, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .fileExporter(isPresented: $exporting, document: document,
                      contentType: .json, defaultFilename: Self.filename) { result in
            switch result {
            case .success:
                report = String(localized: "Копия сохранена")
                failure = nil
            case .failure(let error):
                // Отмена в системном окне приходит сюда же ошибкой — не пугаем.
                Log.app.error("копия не сохранилась: \(error.localizedDescription, privacy: .public)")
                failure = nil
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): restore(from: url)
            case .failure(let error):
                Log.app.error("файл не выбран: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Имя с датой: в «Файлах» рядом лежат копии за разные дни, и без даты их
    /// не различить.
    private static var filename: String {
        "RadarMap " + Date().formatted(.iso8601.year().month().day()
            .dateSeparator(.dash))
    }

    private func row(title: String, symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.rounded(12, .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func restore(from url: URL) {
        report = nil
        failure = nil
        // Файл выбран в чужом контейнере («Файлы», iCloud) — доступ к нему
        // выдаётся на время и его надо явно взять и вернуть.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let backup = try JSONDecoder().decode(TripBackup.self, from: Data(contentsOf: url))
            guard backup.isReadable else {
                failure = String(localized: "Это не копия RadarMap или она из более новой версии")
                return
            }
            guard !backup.isEmpty else {
                failure = String(localized: "В копии нет данных")
                return
            }
            let added = env.restore(from: backup)
            report = added.trips > 0 || added.days > 0
                ? String(format: String(localized: "Добавлено поездок: %1$lld, дней: %2$lld"),
                         added.trips, added.days)
                : String(localized: "Всё из копии уже есть на телефоне")
        } catch {
            Log.app.error("копия не прочиталась: \(error.localizedDescription, privacy: .public)")
            failure = String(localized: "Файл не читается")
        }
    }
}

/// Обёртка для системного окна сохранения. Кодирование — здесь, чтобы вью не
/// держала готовые байты дольше, чем нужно окну.
struct BackupDocument: FileDocument {
    static let readableContentTypes = [UTType.json]

    let backup: TripBackup

    init(backup: TripBackup) { self.backup = backup }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        backup = try JSONDecoder().decode(TripBackup.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        // Читаемый отступ намеренно: копию открывают в «Файлах» и заглядывают
        // внутрь — сплошная строка на мегабайт выглядит как мусор.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(backup))
    }
}
