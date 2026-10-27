//
//  MaintenancePage.swift
//  RadarMap
//
//  Настройки → Поездка → Машина → «Обслуживание» (18.2). Пробег сверху (в
//  первый раз — вопрос «сколько сейчас на приборке»), ниже пункты: работы по
//  машине и документы, у каждого — полоса остатка, состояние и «Сделано
//  сегодня», когда срок близко. Тап по пункту — лист с интервалом и датами.
//  Числа и сроки считает Maintenance; экран только показывает.
//

import SwiftUI
import UserNotifications

struct MaintenancePage: View {
    @Environment(AppEnvironment.self) private var env
    @State private var editing: MaintenanceKind?
    @State private var editsOdometer = false
    /// Пробег, который вводят в первый раз прямо на странице.
    @State private var firstOdometer: Double?

    var body: some View {
        let service = env.maintenance
        let states = service.states()
        let machine = states.filter { !$0.kind.isDocument }
        let documents = states.filter(\.kind.isDocument)
        ScrollViewReader { proxy in
        Form {
            if let odometer = service.odometerKm {
                odometerSection(odometer, added: service.odometerAddedKm ?? 0)
            } else {
                firstRunSection
            }
            if !machine.isEmpty {
                Section {
                    ForEach(machine) { MaintenanceRow(state: $0) { editing = $0 } }
                } header: {
                    Text("Машина")
                }
                .id("machine")
            }
            if !documents.isEmpty {
                Section {
                    ForEach(documents) { MaintenanceRow(state: $0) { editing = $0 } }
                } header: {
                    Text("Документы и проверки")
                }
                .id("documents")
            }
            let disabled = service.disabledKinds
            if !disabled.isEmpty {
                Section {
                    ForEach(disabled) { kind in
                        Button {
                            service.setEnabled(kind, true)
                        } label: {
                            Label {
                                Text(kind.title).foregroundStyle(Theme.textPrimary)
                            } icon: {
                                Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
                            }
                        }
                        .accessibilityLabel(Text(String(format: String(localized: "Отслеживать: %@"), kind.title)))
                    }
                } header: {
                    Text("Не отслеживаются")
                } footer: {
                    Text("Нажмите, чтобы добавить в список.")
                }
            }
            remindersSection
                .id("reminders")
        }
        #if DEBUG
        .onAppear { debugLaunch(proxy) }
        #endif
        }
        .settingsPage("Обслуживание")
        .sheet(item: $editing) { kind in
            MaintenanceEditSheet(kind: kind, record: service.book.record(kind))
        }
        .sheet(isPresented: $editsOdometer) {
            OdometerSheet(current: service.odometerKm)
        }
        .onAppear { env.usage.noteScreen("maintenance") }
    }

    #if DEBUG
    /// Снимки без касаний: `-maintenanceScroll machine|documents|reminders`,
    /// `-maintenanceEdit <oil|osago|…>` — открыть лист пункта, `-maintenanceOdometer`.
    private func debugLaunch(_ proxy: ScrollViewProxy) {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-maintenanceScroll"), i + 1 < args.count {
            let target = args[i + 1]
            Task {
                await Task.pause(seconds: 1)
                proxy.scrollTo(target, anchor: .top)
            }
        }
        if let i = args.firstIndex(of: "-maintenanceEdit"), i + 1 < args.count,
           let kind = MaintenanceKind(rawValue: args[i + 1]) {
            Task {
                await Task.pause(seconds: 1)
                editing = kind
            }
        }
        if args.contains("-maintenanceOdometer") {
            Task {
                await Task.pause(seconds: 1)
                editsOdometer = true
            }
        }
    }
    #endif

    // MARK: - Пробег

    @ViewBuilder private var firstRunSection: some View {
        Section {
            FieldRow(String(localized: "Пробег на приборке, км")) {
                NumberField(placeholder: "85 000", decimals: false, optional: firstOdometer) {
                    firstOdometer = $0
                }
                .accessibilityLabel(Text("Пробег на приборке, в километрах"))
            }
        } header: {
            Text("Сколько сейчас на одометре?")
        } footer: {
            Text("Один раз с приборной панели — дальше пробег прибавляется сам, по вашим поездкам.")
        }
        // Кнопка — своей секцией без фона: в одной секции с полем карточка
        // поля оставалась без нижнего скругления.
        Section {
            let ready = (firstOdometer ?? 0) > 0
            PrimaryButton(title: "Сохранить пробег") {
                if let km = firstOdometer, km > 0 { env.maintenance.setOdometer(km: km) }
            }
            .disabled(!ready)
            .opacity(ready ? 1 : 0.45)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private func odometerSection(_ odometer: Double, added: Double) -> some View {
        Section {
            Button {
                editsOdometer = true
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        // Тем же шрифтом, что и число: системный кегль рос на
                        // крупном шрифте вдвое, а число — по шкале приложения.
                        Text("Пробег")
                            .font(.rounded(17))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 8)
                        Text(Formatting.distance(odometer * 1000))
                            .font(.numeral(20, .bold).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                    }
                    if added >= 1 {
                        Text(String(format: String(localized: "%@ — по поездкам после ввода"),
                                    Formatting.distance(added * 1000)))
                            .font(.rounded(13))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tapTarget()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(String(format: String(localized: "Пробег %@"), SpokenUnits.distance(odometer * 1000))))
            .accessibilityHint(Text("Изменить пробег"))
        } footer: {
            Text("Сверьте с приборкой раз в несколько месяцев: GPS считает чуть иначе.")
        }
    }

    // MARK: - Напоминания

    private var remindersSection: some View {
        Section {
            Toggle("Напоминать", isOn: Binding(
                get: { env.settings.maintenanceReminders },
                set: { env.setMaintenanceReminders($0) }))
            if env.notifications.authorizationStatus == .denied, env.settings.maintenanceReminders {
                Label("Уведомления выключены в настройках iPhone.", systemImage: "bell.slash")
                    .foregroundStyle(Theme.warning)
            }
            SettingsExplainer([
                "Пробег — введённый вами плюс километры поездок после ввода. Поездки до ввода не считаются: они уже на приборке.",
                "Срок — что наступит раньше: пробег или дата. «Скоро» — за 500 км или 14 дней.",
                "Напоминание — одно на «скоро» и одно на «пора». Не в дороге: после стоянки днём или в 9:00.",
                "Всё хранится только на телефоне.",
            ])
        } footer: {
            Text("Не в поездке: после стоянки или в 9:00.")
        }
    }
}

// MARK: - Строка пункта

/// Пункт: значок, название, состояние, полоса остатка и срок словами.
/// Тап — лист правки; «Сделано сегодня» — прямо в строке, когда срок близко.
struct MaintenanceRow: View {
    @Environment(AppEnvironment.self) private var env
    let state: Maintenance.State
    let onEdit: (MaintenanceKind) -> Void

    var body: some View {
        let color = MaintenanceText.color(state.status)
        VStack(alignment: .leading, spacing: 8) {
            Button { onEdit(state.kind) } label: {
                HStack(alignment: .top, spacing: 12) {
                    IconBadge(symbol: state.kind.symbol,
                              tint: state.status == .unknown ? Theme.accent : color, size: 34)
                    VStack(alignment: .leading, spacing: 6) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                title
                                Spacer(minLength: 0)
                                MaintenanceChip(state: state)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                title
                                MaintenanceChip(state: state)
                            }
                        }
                        if let progress = state.progress {
                            // Полоса ОСТАТКА: пустеет к сроку.
                            ProgressView(value: 1 - progress)
                                .tint(color)
                                .accessibilityHidden(true)
                        }
                        Text(MaintenanceText.detail(state))
                            .font(.rounded(13))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(MaintenanceText.spoken(state)))
            .accessibilityHint(Text("Изменить срок и интервал"))

            if state.status.needsAttention,
               Maintenance.canMarkDone(state.kind, record: env.maintenance.book.record(state.kind)) {
                Button {
                    env.maintenance.markDone(state.kind)
                } label: {
                    // HStack, а не Label: в строке формы Label уводит текст на
                    // колонку иконок списка — глиф и подпись разъезжались.
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(doneTitle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(.leading, 46)
                .accessibilityLabel(Text(String(format: String(localized: "%1$@: %2$@"),
                                                state.kind.title, doneTitle)))
            }
        }
        .padding(.vertical, 4)
    }

    private var title: some View {
        Text(state.kind.title)
            .font(.rounded(16, .semibold))
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var doneTitle: String {
        state.kind.isDocument ? String(localized: "Продлено сегодня") : String(localized: "Сделано сегодня")
    }
}

/// Подпись состояния: цвет и глиф — по общему правилу (`Theme.Level`).
struct MaintenanceChip: View {
    let state: Maintenance.State

    var body: some View {
        let color = MaintenanceText.color(state.status)
        HStack(spacing: 4) {
            if let symbol = Theme.symbol(MaintenanceText.level(state.status)) {
                Image(systemName: symbol)
            }
            Text(MaintenanceText.status(state))
        }
        .font(.rounded(12, .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.quietFill, in: Capsule())
        .fixedSize()
    }
}
