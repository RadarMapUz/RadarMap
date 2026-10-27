//
//  FamilyRecipientPage.swift
//  RadarMap
//
//  Один близкий (22.1): имя и смайлик, режим («Когда еду домой» / «Каждая
//  поездка» — с предупреждением), «Отправить ссылку», выключатель, «Сменить
//  ссылку», «Убрать». Ссылку отправляет сам водитель через лист «Поделиться»:
//  «отправлено» — только по ответу листа.
//

import SwiftUI

struct FamilyRecipientPage: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var sharePayload: ActivityTextPayload?
    @State private var serverUnavailable = false
    @State private var confirmChange = false
    @State private var confirmRemove = false

    /// Смайлики на выбор — тот, кто ждёт, а не «контакт».
    static let emojis = ["👩‍🦳", "👨‍🦳", "👩", "👨", "👧", "👦", "👵", "👴", "❤️", "🏠"]

    var body: some View {
        if let recipient = env.family.recipient(id) {
            form(recipient)
        } else {
            // Убрали (с этой же страницы или свайпом) — назад.
            Color.clear.onAppear { dismiss() }
        }
    }

    private func form(_ recipient: FamilyRecipient) -> some View {
        let family = env.family
        return Form {
            Section {
                TextField("Имя, например «Мама»", text: Binding(
                    get: { recipient.name }, set: { family.rename(id, to: $0) }))
                    .textInputAutocapitalization(.words)
                emojiRow(recipient)
            } footer: {
                Text("Имя и смайлик видны только вам.")
            }

            Section {
                Picker("Когда видит", selection: Binding(
                    get: { recipient.mode }, set: { family.setMode(id, $0) })) {
                    ForEach(FamilyRecipient.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if recipient.mode == .everyTrip {
                    Label {
                        Text(String(format: String(localized: "%@ будет видеть каждую вашу поездку — на работу, в магазин, к друзьям: время прибытия и «в пути / на месте». Карта и адреса не видны."),
                                    recipient.name))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.rounded(14, .medium))
                    .foregroundStyle(Theme.warning)
                }
            } header: {
                Text("Когда видит")
            } footer: {
                if recipient.mode == .home {
                    Text("Когда цель маршрута — Дом, дорога узнана как «домой» или вы нажали «Еду домой».")
                } else {
                    Text("Для родителей начинающего водителя.")
                }
            }

            Section {
                // Лист «Поделиться» с ответом, а не ShareLink: двойное касание
                // VoiceOver нажимает кнопку, и «отправлено» — только когда
                // ссылку правда отправили. Сервер без страницы — ссылку не
                // отдаём: близкий открыл бы ошибку.
                Button {
                    Task { await share(recipient) }
                } label: {
                    Label("Отправить ссылку", systemImage: "square.and.arrow.up")
                }
                if let sent = recipient.linkSentAt {
                    Text(String(format: String(localized: "Ссылка отправлена %@"),
                                sent.formatted(.dateTime.day().month(.wide).locale(NumberFormat.locale))))
                        .font(.rounded(14))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Ссылка ещё не отправлена — пока ничего не видно.")
                        .font(.rounded(14, .medium))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Показывать поездки", isOn: Binding(
                    get: { recipient.enabled }, set: { family.setEnabled(id, $0) }))
            } footer: {
                Text("В любой мессенджер; в ссылке — подписка на сообщения в Telegram.")
            }

            Section {
                Button("Сменить ссылку") { confirmChange = true }
                Button("Убрать", role: .destructive) { confirmRemove = true }
            } footer: {
                Text("Сменить — если ссылка ушла не тому: старая перестанет работать.")
            }
        }
        .settingsPage()
        .navigationTitle(Text(verbatim: recipient.title))
        .sheet(item: $sharePayload) { payload in
            ActivityTextSheet(text: payload.text) { sent in
                if sent { family.markSent(id) }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Ссылка пока не работает", isPresented: $serverUnavailable) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text("Сервер ещё не обновлён — близкий открыл бы ошибку. Попробуйте позже.")
        }
        .confirmationDialog("Сменить ссылку?", isPresented: $confirmChange, titleVisibility: .visible) {
            Button("Сменить ссылку", role: .destructive) { family.changeLink(id) }
        } message: {
            Text("Старая ссылка перестанет работать — новую нужно будет отправить.")
        }
        .confirmationDialog(Text(String(format: String(localized: "Убрать «%@»?"), recipient.name)),
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Убрать", role: .destructive) { family.remove(id) }
        } message: {
            Text("Ссылка погаснет. Остальные близкие продолжат видеть.")
        }
    }

    private func emojiRow(_ recipient: FamilyRecipient) -> some View {
        // Выбранный — в кадре: восьмой смайлик на узком экране уходил за край.
        ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Self.emojis, id: \.self) { emoji in
                    let selected = recipient.emoji == emoji
                    Button {
                        // Тот же смайлик ещё раз — снять.
                        env.family.setEmoji(id, selected ? "" : emoji)
                    } label: {
                        Text(verbatim: emoji)
                            .font(.system(size: 26))
                            .frame(width: 44, height: 44)
                            .background(selected ? Theme.quietFill : Color.clear, in: Circle())
                            .overlay(Circle().strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .id(emoji)
                }
            }
            .padding(.vertical, 2)
        }
        .onAppear {
            if !recipient.emoji.isEmpty { proxy.scrollTo(recipient.emoji, anchor: .center) }
        }
        }
    }

    private func share(_ recipient: FamilyRecipient) async {
        guard await env.etaShare.ensureServerSupport() else {
            serverUnavailable = true
            return
        }
        sharePayload = ActivityTextPayload(text: FamilyShare.shareMessage(
            for: recipient, base: AppConfig.syncBaseURL, bot: env.etaShare.telegramBot))
    }
}
