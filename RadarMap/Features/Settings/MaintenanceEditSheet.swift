//
//  MaintenanceEditSheet.swift
//  RadarMap
//
//  Лист пункта обслуживания (18.2): «Сделано сегодня» одной кнопкой, когда
//  делали в последний раз, свой интервал, «действует до» у документа и
//  «не отслеживать». Правки — черновиком: применяются по «Сохранить», чтобы
//  напоминания пересчитывались один раз, а не на каждую цифру.
//

import SwiftUI

struct MaintenanceEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let kind: MaintenanceKind
    @State private var draft: MaintenanceRecord

    init(kind: MaintenanceKind, record: MaintenanceRecord) {
        self.kind = kind
        _draft = State(initialValue: record)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Название — заголовком в самой форме: в строке навигации между
                // «Отмена» и «Сохранить» «Масло двигателя» резалось до
                // «Масло двигат…», а узбекские названия длиннее.
                Section {
                    if Maintenance.canMarkDone(kind, record: draft) {
                        PrimaryButton(title: doneTitle, systemImage: "checkmark.circle.fill") {
                            env.maintenance.markDone(kind)
                            dismiss()
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    HStack(spacing: 12) {
                        IconBadge(symbol: kind.symbol, size: 40)
                        Text(kind.title)
                            .font(.rounded(22, .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }
                    .textCase(nil)
                    .padding(.bottom, 8)
                } footer: {
                    if Maintenance.canMarkDone(kind, record: draft) {
                        Text(doneFooter)
                    }
                }
                if kind.isDocument {
                    documentSections
                } else {
                    serviceSections
                }
                Section {
                    Toggle("Отслеживать", isOn: Binding(
                        get: { draft.enabled ?? kind.enabledByDefault },
                        set: { draft.enabled = $0 }))
                } footer: {
                    Text("Выключенный пункт не показывается и не напоминает.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Заголовок — в форме (см. выше); строка навигации — только кнопки.
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        env.maintenance.update(kind, record: draft)
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Работа по пробегу и времени

    @ViewBuilder private var serviceSections: some View {
        Section {
            FieldRow(String(localized: "Пробег, км")) {
                NumberField(placeholder: "—", decimals: false, optional: draft.doneKm) {
                    draft.doneKm = $0.map { max(0, $0) }
                }
                .accessibilityLabel(Text("Пробег при последней замене, в километрах"))
            }
            OptionalDateRow(title: "Дата", date: $draft.doneAt, fallback: Date(), range: ...Date())
        } header: {
            Text("Последний раз")
        } footer: {
            Text("Не помните точно — укажите примерно: срок посчитается от этого.")
        }
        Section {
            FieldRow(String(localized: "Каждые, км")) {
                NumberField(placeholder: kind.defaultIntervalKm.map { Self.number($0) } ?? "—", decimals: false,
                            optional: draft.intervalKm) {
                    draft.intervalKm = $0.map { max(0, min($0, 500_000)) }
                }
                .accessibilityLabel(Text("Интервал, в километрах"))
            }
            FieldRow(String(localized: "Каждые, мес.")) {
                NumberField(placeholder: kind.defaultIntervalMonths.map { Self.number(Double($0)) } ?? "—",
                            decimals: false, optional: draft.intervalMonths.map { Double($0) }) {
                    draft.intervalMonths = $0.map { Int(max(0, min($0, 240))) }
                }
                .accessibilityLabel(Text("Интервал, в месяцах"))
            }
        } header: {
            Text("Интервал")
        } footer: {
            Text(intervalFooter)
        }
    }

    // MARK: - Документ

    @ViewBuilder private var documentSections: some View {
        Section {
            OptionalDateRow(title: "Действует до", date: $draft.dueDate,
                            fallback: Calendar.current.date(byAdding: .month,
                                                            value: Maintenance.effectiveMonths(kind, draft) ?? 12,
                                                            to: Date()) ?? Date(),
                            range: nil)
        } footer: {
            Text("Последний день действия — из полиса, талона или самого документа.")
        }
        Section {
            FieldRow(String(localized: "Продлевать на, мес.")) {
                NumberField(placeholder: kind.defaultIntervalMonths.map { Self.number(Double($0)) } ?? "—",
                            decimals: false, optional: draft.intervalMonths.map { Double($0) }) {
                    draft.intervalMonths = $0.map { Int(max(0, min($0, 240))) }
                }
                .accessibilityLabel(Text("На сколько месяцев продлевают, в месяцах"))
            }
        } footer: {
            Text("Для «Продлено сегодня»: новый срок — сегодня плюс столько месяцев.")
        }
    }

    // MARK: - Тексты

    private var doneTitle: LocalizedStringKey {
        if kind.isDocument { return "Продлено сегодня" }
        return "Сделано сегодня"
    }

    private var doneFooter: String {
        if kind.isDocument {
            guard let months = Maintenance.effectiveMonths(kind, draft),
                  let until = Calendar.current.date(byAdding: .month, value: months, to: Date()) else { return "" }
            return String(format: String(localized: "Новый срок — до %@"), MaintenanceText.date(until))
        }
        guard let odometer = env.maintenance.odometerKm else {
            return String(localized: "Сегодняшняя дата. Введите пробег на странице — и срок посчитается и по километрам.")
        }
        return String(format: String(localized: "Пробег %@, сегодняшняя дата."), Formatting.distance(odometer * 1000))
    }

    private var intervalFooter: String {
        let km = kind.defaultIntervalKm.map { Formatting.distance($0 * 1000) }
        let months = kind.defaultIntervalMonths.map { String(format: String(localized: "%lld мес."), $0) }
        let usual = [km, months].compactMap { $0 }.joined(separator: String(localized: " или "))
        return String(format: String(localized: "Пусто — как обычно (%@). Ноль — не учитывать."),
                      usual.isEmpty ? "—" : usual)
    }

    private static func number(_ value: Double) -> String {
        NumberField.display(value, decimals: false)
    }
}

/// Дата, которой может не быть: «Указать» ставит подсказку, «Убрать» — снимает.
private struct OptionalDateRow: View {
    let title: LocalizedStringKey
    @Binding var date: Date?
    let fallback: Date
    let range: PartialRangeThrough<Date>?

    var body: some View {
        if let value = date {
            let binding = Binding(get: { value }, set: { date = $0 })
            if let range {
                DatePicker(title, selection: binding, in: range, displayedComponents: .date)
            } else {
                DatePicker(title, selection: binding, displayedComponents: .date)
            }
            Button("Убрать дату", role: .destructive) { date = nil }
        } else {
            Button {
                date = fallback
            } label: {
                LabeledContent(title) {
                    Text("Указать").foregroundStyle(Theme.accent)
                }
                .foregroundStyle(Theme.textPrimary)
            }
        }
    }
}

/// Пробег с приборки — правка (сверить раз в несколько месяцев).
struct OdometerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var km: Double?

    init(current: Double?) {
        _km = State(initialValue: current.map { $0.rounded() })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FieldRow(String(localized: "Пробег на приборке, км")) {
                        NumberField(placeholder: "85 000", decimals: false, optional: km) { km = $0 }
                            .accessibilityLabel(Text("Пробег на приборке, в километрах"))
                    }
                } footer: {
                    Text("Сроки по пробегу считаются от него: что меняли при 80 000 км, так и останется.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Пробег")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        if let km, km > 0 { env.maintenance.setOdometer(km: km) }
                        dismiss()
                    }
                    .disabled((km ?? 0) <= 0)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
