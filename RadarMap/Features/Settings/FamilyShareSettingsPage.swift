//
//  FamilyShareSettingsPage.swift
//  RadarMap
//
//  Настройки → Поездка → «Близкие видят прибытие» (12б.6): кому, отправить
//  ссылку, выключить, удалить. Ссылку отправляет сам водитель — один раз и
//  ещё раз после смены токена (раз в 30 дней).
//

import SwiftUI

struct FamilyShareSettingsPage: View {
    @Environment(AppEnvironment.self) private var env
    @State private var name = ""

    var body: some View {
        let family = env.family
        Form {
            if let link = family.link {
                Section {
                    TextField("Кому, например «Мама»", text: Binding(
                        get: { link.name }, set: { family.rename($0) }))
                    ShareLink(item: link.url(base: AppConfig.syncBaseURL),
                              message: Text("Здесь видно, когда я буду дома")) {
                        Label(link.needsResend ? "Отправить новую ссылку" : "Отправить ссылку",
                              systemImage: "square.and.arrow.up")
                    }
                    .simultaneousGesture(TapGesture().onEnded { family.markSent() })
                    if link.needsResend {
                        Text("Ссылка обновилась — старая больше не показывает поездки. Отправьте новую.")
                            .font(.footnote)
                            .foregroundStyle(Theme.warning)
                    }
                    Toggle("Показывать поездки домой", isOn: Binding(
                        get: { link.enabled }, set: { family.setEnabled($0) }))
                    Button("Удалить ссылку", role: .destructive) { family.remove() }
                } footer: {
                    Text("Видно только время прибытия домой и «в пути / дома» — без карты и адреса.")
                }
            } else {
                Section {
                    TextField("Кому, например «Мама»", text: $name)
                    Button("Создать ссылку") {
                        family.create(name: name.isEmpty ? String(localized: "Близкий") : name)
                    }
                } footer: {
                    Text("Одна постоянная ссылка: по дороге домой близкий видит, когда вы будете, в остальное время — «сейчас не в пути».")
                }
            }
            Section {
                SettingsExplainer([
                    "Поездку домой приложение узнаёт по вашему распорядку, как подсказку «Домой»: в магазин и к друзьям ссылка молчит.",
                    "На сервер уходят только время прибытия и «в пути / дома» — ни точки, ни маршрута, ни телефона. Хранится в памяти сервера и гаснет само.",
                    "Раз в 30 дней ссылка меняется: так у сервера не копится постоянный идентификатор. Новую нужно отправить ещё раз.",
                    "В поездке — «Сейчас видят: Мама» и пауза одним касанием.",
                ])
            }
        }
        .settingsPage("Близкие видят прибытие")
    }
}

/// «Сейчас видят: Мама» с паузой — в поездке, пока ссылка живая.
struct FamilyLiveChip: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if env.family.isLive, let link = env.family.link {
            HStack(spacing: 8) {
                Image(systemName: "eye.fill")
                    .font(.rounded(12, .bold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(String(format: String(localized: "Сейчас видят: %@"), link.name))
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    env.family.pause()
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.rounded(12, .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(Theme.background, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Пауза на эту поездку"))
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .liftedBackground(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.edgePanel, lineWidth: 1))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
