//
//  CloudSyncSection.swift
//  RadarMap
//
//  «Хранить поездки: только на iPhone / в iCloud» (27.F) — в «Истории
//  поездок», рядом с экспортом и удалением: это решение о тех же данных.
//  И одноразовое предложение в «Итогах»: включать молча нельзя — это
//  история человека, и куда её класть, решает он.
//

import SwiftUI

struct CloudSyncSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmsOff = false

    var body: some View {
        let cloud = env.cloud
        Section {
            Picker(selection: Binding(get: { cloud.mode ?? .local }, set: choose)) {
                Label("Только на iPhone", systemImage: "iphone").tag(CloudSyncMode.local)
                Label("В iCloud", systemImage: "icloud").tag(CloudSyncMode.iCloud)
            } label: {
                Text("Хранить поездки")
            }
            .pickerStyle(.inline)
            CloudStatusRow(status: cloud.status, remoteWiped: cloud.remoteWiped)
            if cloud.isEnabled {
                Button {
                    cloud.syncNow()
                } label: {
                    Label("Сохранить сейчас", systemImage: "arrow.triangle.2.circlepath.icloud")
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            SettingsExplainer([
                "Поездки с треками, места, журнал заправок, штрафы и профиль машины шифруются ключом вашего Apple ID. Ни мы, ни наш сервер их не видим.",
                "Новый iPhone с тем же Apple ID получит историю сам — она сложится с тем, что уже есть на телефоне.",
                "В поездке iCloud молчит: связь нужна предупреждениям о камерах. Сохранение — после остановки.",
                "Близкие переносятся без ссылок: на новом телефоне ссылку им нужно отправить заново.",
                "«Удалить всю историю» стирает и копию в iCloud.",
            ])
        } header: {
            Text("Хранить поездки")
        } footer: {
            Text("В iCloud история переживёт смену телефона. Настройки приложения — тоже.")
        }
        .confirmationDialog("Перестать хранить в iCloud?", isPresented: $confirmsOff, titleVisibility: .visible) {
            Button("Оставить копию в iCloud") { cloud.setMode(.local) }
            Button("Удалить копию из iCloud", role: .destructive) { cloud.turnOffAndDeleteCloudCopy() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("На iPhone всё останется как есть.")
        }
    }

    private func choose(_ mode: CloudSyncMode) {
        if mode == .local, env.cloud.isEnabled {
            confirmsOff = true
        } else {
            env.cloud.setMode(mode)
        }
    }
}

/// Строка состояния — честно, что происходит и что сделать человеку.
struct CloudStatusRow: View {
    let status: CloudStatus
    var remoteWiped = false

    var body: some View {
        let line = remoteWiped && status == .off ? CloudStatus.remoteWiped.line : status.line
        Label {
            Text(line.text)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: line.symbol)
                .foregroundStyle(line.tint)
        }
        .accessibilityElement(children: .combine)
    }
}

extension CloudStatus {
    struct Line {
        let symbol: String
        let text: String
        let tint: Color
    }

    var line: Line {
        switch self {
        case .off:
            return Line(symbol: "iphone", text: String(localized: "Поездки хранятся только на этом iPhone"),
                        tint: Theme.textTertiary)
        case .checking:
            return Line(symbol: "icloud", text: String(localized: "Проверяем iCloud…"), tint: Theme.accent)
        case .noAccount:
            return Line(symbol: "icloud.slash",
                        text: String(localized: "iCloud выключен. Войдите в Apple ID и включите iCloud для RadarMap в Настройках iPhone — пока поездки хранятся на телефоне."),
                        tint: Theme.warning)
        case .restricted:
            return Line(symbol: "icloud.slash",
                        text: String(localized: "iCloud ограничен на этом iPhone (Экранное время или профиль) — поездки хранятся на телефоне."),
                        tint: Theme.warning)
        case .temporarilyUnavailable:
            return Line(symbol: "icloud.slash", text: String(localized: "iCloud временно недоступен — повторим позже."),
                        tint: Theme.warning)
        case .notProvisioned:
            return Line(symbol: "icloud.slash",
                        text: String(localized: "В этой версии iCloud ещё не подключён — поездки хранятся на телефоне."),
                        tint: Theme.warning)
        case .waitingForTrip:
            return Line(symbol: "car.fill", text: String(localized: "Идёт поездка — сохраним после остановки."),
                        tint: Theme.textTertiary)
        case .syncing(let sent):
            let text = sent > 0
                ? String(localized: "Сохраняем в iCloud… отправлено: \(sent)")
                : String(localized: "Сохраняем в iCloud…")
            return Line(symbol: "arrow.triangle.2.circlepath.icloud", text: text, tint: Theme.accent)
        case .synced(let trips, let at):
            var text = String(localized: "В iCloud:") + " " + String(localized: "\(trips) поездок")
            if let at { text += " · " + at.formatted(date: .abbreviated, time: .shortened) }
            return Line(symbol: "checkmark.icloud.fill", text: text, tint: Theme.success)
        case .offline(let pending):
            let text = pending > 0
                ? String(localized: "Нет сети. Ждут отправки: \(pending)")
                : String(localized: "Нет сети — сохраним, когда появится.")
            return Line(symbol: "icloud.slash", text: text, tint: Theme.warning)
        case .quota:
            return Line(symbol: "exclamationmark.icloud.fill",
                        text: String(localized: "В iCloud закончилось место — освободите хранилище в Настройках iPhone."),
                        tint: Theme.danger)
        case .remoteWiped:
            return Line(symbol: "exclamationmark.icloud.fill",
                        text: String(localized: "Копию в iCloud удалили на другом устройстве, хранение выключено. Включите снова, чтобы сохранить поездки этого iPhone."),
                        tint: Theme.warning)
        case .failed:
            return Line(symbol: "exclamationmark.icloud.fill",
                        text: String(localized: "Не удалось сохранить в iCloud — повторим позже."),
                        tint: Theme.warning)
        }
    }
}

/// Одноразовое предложение в «Итогах»: «Сохранять поездки в iCloud?».
struct CloudOfferCard: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Сохранять поездки в iCloud?", systemImage: "icloud.fill")
                .font(.rounded(17, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Чтобы не потерять историю при смене телефона. Поездки шифруются ключом вашего Apple ID — нам они не видны.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(title: "Сохранять в iCloud") { env.cloud.answerOffer(accept: true) }
            SecondaryButton(title: "Только на iPhone") { env.cloud.answerOffer(accept: false) }
        }
        .statCard(padding: 14, radius: Theme.cornerMedium)
    }
}
