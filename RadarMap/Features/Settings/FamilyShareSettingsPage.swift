//
//  FamilyShareSettingsPage.swift
//  RadarMap
//
//  Настройки → Поездка → «Близкие видят прибытие» (12б.6, 22.1): список
//  близких со статусом и режимом, «Добавить близкого», имя водителя для них,
//  «Пауза до завтра». Ссылку отправляет сам водитель — со страницы человека
//  (FamilyRecipientPage).
//

import SwiftUI

struct FamilyShareSettingsPage: View {
    @Environment(AppEnvironment.self) private var env
    @State private var adding = false
    @State private var newName = ""
    /// Только что добавленный — сразу на его страницу: там «Отправить ссылку».
    @State private var opened: UUID?

    var body: some View {
        let family = env.family
        let circle = family.circle
        let paused = circle.isPaused(now: Date())
        Form {
            Section {
                if circle.recipients.isEmpty {
                    Text("Добавьте того, кто ждёт вас дома: по ссылке видно, когда вы будете, — и звонить вам за рулём не придётся.")
                        .font(.rounded(15))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(circle.recipients) { recipient in
                    NavigationLink {
                        FamilyRecipientPage(id: recipient.id)
                    } label: {
                        FamilyRecipientRow(recipient: recipient, isLive: family.liveIDs.contains(recipient.id),
                                           isPaused: paused)
                    }
                    .swipeActions {
                        Button("Убрать", role: .destructive) { family.remove(recipient.id) }
                    }
                    // Свайп VoiceOver не делает — то же действием ротора.
                    .accessibilityAction(named: Text("Убрать")) { family.remove(recipient.id) }
                }
                if circle.canAdd {
                    Button {
                        newName = ""
                        adding = true
                    } label: {
                        Label("Добавить близкого", systemImage: "person.badge.plus")
                    }
                }
            } header: {
                Text("Кто видит")
            } footer: {
                if circle.canAdd {
                    Text("У каждого своя ссылка: убрали одного — остальные работают.")
                } else {
                    Text("Уже пятеро — больше нельзя.")
                }
            }

            Section {
                TextField("Водитель", text: Binding(get: { circle.driverName },
                                                    set: { family.setDriverName($0) }))
                    .textInputAutocapitalization(.words)
                    .accessibilityLabel(Text("Как вас назовут близким"))
            } header: {
                Text("Как вас назовут близким")
            } footer: {
                Text("На странице и в сообщениях: «Азиз едет домой». Пусто — «Водитель».")
            }

            if !circle.recipients.isEmpty {
                Section {
                    if paused {
                        Button("Снять паузу") { family.resumeSharing() }
                    } else {
                        Button("Пауза до завтра") { family.pauseUntilTomorrow() }
                    }
                } footer: {
                    if paused {
                        Text("До завтра поездок не видит никто.")
                    } else {
                        Text("Сегодня — никому, с завтрашнего дня — как обычно.")
                    }
                }
            }

            Section {
                SettingsExplainer([
                    "«Когда еду домой» — поездку домой приложение узнаёт по цели маршрута, по вашему распорядку (как подсказку «Домой») или по кнопке «Еду домой» в поездке. В смене таксиста — по цели и кнопке.",
                    "Близкий видит только время и «в пути / задерживается / дома» — ни карты, ни точки, ни маршрута, ни скорости.",
                    "На сервер уходят время, статус и ваше имя для близких. Хранятся в памяти сервера, пока идёт поездка, и гаснут сами.",
                    "Ссылка постоянная. Ушла не тому — «Сменить ссылку» у этого человека: остальные не заметят.",
                    "В поездке — «Видят: Мама» и пауза одним касанием. «Я пассажир» — не видит никто.",
                ])
            }
        }
        .settingsPage("Близкие видят прибытие")
        .navigationDestination(item: $opened) { FamilyRecipientPage(id: $0) }
        .alert("Кто ждёт вас дома?", isPresented: $adding) {
            TextField("Например, «Мама»", text: $newName)
            Button("Добавить") { opened = family.add(name: newName) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Имя видно только вам.")
        }
        #if DEBUG
        .onAppear {
            family.showDemoLive()
            // Скриншот-хук `-familyOpenFirst N`: сразу страница N-го близкого.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-familyOpenFirst"), opened == nil {
                let n = i + 1 < args.count ? Int(args[i + 1]) ?? 0 : 0
                opened = circle.recipients.indices.contains(n) ? circle.recipients[n].id : nil
            }
        }
        #endif
    }

    /// Справа в «Поездке»: кто видит, «пауза до завтра», «выключено» или «нет».
    static func summary(_ circle: FamilyCircle, now: Date = Date()) -> String {
        guard !circle.recipients.isEmpty else { return String(localized: "нет") }
        if circle.isPaused(now: now) { return String(localized: "пауза до завтра") }
        let names = circle.recipients.filter(\.enabled).map(\.name)
        return names.isEmpty ? String(localized: "выключено") : names.joined(separator: ", ")
    }
}

/// Строка близкого: смайлик (или первая буква), имя, режим и что сейчас.
struct FamilyRecipientRow: View {
    let recipient: FamilyRecipient
    let isLive: Bool
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 12) {
            FamilyAvatar(recipient: recipient)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipient.name)
                    .font(.rounded(16, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(statusText)
                    .font(.rounded(13))
                    .foregroundStyle(statusTint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        let mode = recipient.mode.title
        if !recipient.enabled { return String(localized: "Выключено") }
        if recipient.linkSentAt == nil { return String(localized: "Ссылка ещё не отправлена") }
        if isPaused { return String(format: String(localized: "%@ · пауза до завтра"), mode) }
        if isLive { return String(format: String(localized: "%@ · видит сейчас"), mode) }
        return mode
    }

    private var statusTint: Color {
        if recipient.enabled, recipient.linkSentAt == nil { return Theme.warning }
        if recipient.enabled, isLive, !isPaused { return Theme.success }
        return Theme.textSecondary
    }
}

/// Кружок со смайликом близкого; без смайлика — первая буква имени.
struct FamilyAvatar: View {
    let recipient: FamilyRecipient
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(Theme.accent.opacity(0.14))
            if recipient.emoji.isEmpty {
                Text(verbatim: String(recipient.name.prefix(1)).uppercased())
                    .font(.rounded(size * 0.45, .bold))
                    .foregroundStyle(Theme.accent)
            } else {
                Text(verbatim: recipient.emoji)
                    .font(.system(size: size * 0.55))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension FamilyRecipient.Mode {
    var title: String {
        switch self {
        case .home: String(localized: "Когда еду домой")
        case .everyTrip: String(localized: "Каждая поездка")
        }
    }
}
