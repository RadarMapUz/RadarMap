//
//  FineEntrySheet+Sections.swift
//  RadarMap
//
//  Разделы формы штрафа: вставка текста, когда и где, сверка с поездкой,
//  постановление. Поле, найденное разбором без уверенности, помечено
//  «проверьте» — пометка снимается, как только человек его поправит.
//

import SwiftUI

extension FineEntrySheet {

    // MARK: - Вставить текст

    var pasteSection: some View {
        Section {
            TextEditor(text: $pasted)
                .font(.rounded(14))
                .frame(minHeight: 96)
                .overlay(alignment: .topLeading) {
                    if pasted.isEmpty {
                        Text("Вставьте сюда текст СМС или уведомления о штрафе")
                            .font(.rounded(14))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
            // Системная кнопка вставки: текст берётся по нажатию, без вопроса
            // «разрешить вставку» и без чтения буфера в фоне.
            PasteButton(payloadType: String.self) { strings in
                Task { @MainActor in
                    pasted = strings.first ?? ""
                    parse()
                }
            }
            .buttonBorderShape(.capsule)
            Button {
                parse()
            } label: {
                Label("Разобрать текст", systemImage: "text.viewfinder")
            }
            .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let parseNote { noteView(parseNote) }
        } header: {
            Text("Текст уведомления")
        } footer: {
            Text("Текст разбирается на телефоне и не сохраняется: номер машины и имя из него никуда не попадут.")
        }
    }

    @ViewBuilder
    private func noteView(_ note: ParseNote) -> some View {
        switch note {
        case .notFine:
            Label("Не похоже на уведомление о штрафе — заполните поля вручную", systemImage: "questionmark.circle")
                .font(.rounded(13))
                .foregroundStyle(Theme.warning)
        case .nothing:
            Label("Не распознали ни одного поля — заполните вручную", systemImage: "questionmark.circle")
                .font(.rounded(13))
                .foregroundStyle(Theme.warning)
        case .found(let fields, let unsure):
            VStack(alignment: .leading, spacing: 6) {
                Label(String(format: String(localized: "Нашли: %@"), Self.names(fields)),
                      systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.success)
                if !unsure.isEmpty {
                    Label(String(format: String(localized: "Проверьте: %@"), Self.names(unsure)),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                }
            }
            .font(.rounded(13))
        }
    }

    static func names(_ fields: [FineDraft.Name]) -> String {
        fields.map { name -> String in
            switch name {
            case .date: String(localized: "дата")
            case .time: String(localized: "время")
            case .issued: String(localized: "дата постановления")
            case .due: String(localized: "срок оплаты")
            case .amount: String(localized: "сумма")
            case .speed: String(localized: "скорость")
            case .limit: String(localized: "ограничение")
            case .resolution: String(localized: "номер постановления")
            case .place: String(localized: "место")
            }
        }.joined(separator: ", ")
    }

    // MARK: - Когда и где

    var whenSection: some View {
        Section {
            if form.day != nil {
                DatePicker(selection: dayBinding, in: ...Date(), displayedComponents: .date) {
                    fieldLabel(String(localized: "Дата нарушения"), .date)
                }
                Toggle(isOn: Binding(get: { form.timeKnown }, set: {
                    form.timeKnown = $0
                    form.unsure.remove(.time)
                })) {
                    fieldLabel(String(localized: "Время известно"), .time)
                }
                if form.timeKnown {
                    DatePicker(selection: timeBinding, displayedComponents: .hourAndMinute) {
                        fieldLabel(String(localized: "Время"), .time)
                    }
                }
            } else {
                // Дня по умолчанию нет: «сегодня», подставленное молча, —
                // выдуманное поле. Дату ставит человек.
                Button {
                    form.day = Calendar.current.startOfDay(for: Date())
                } label: {
                    Label("Указать дату нарушения", systemImage: "calendar")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel(String(localized: "Место"), .place)
                    .font(.rounded(12))
                TextField("Как в уведомлении: улица, перекрёсток", text: text(\.place, .place), axis: .vertical)
            }
        } header: {
            Text("Когда и где")
        }
    }

    private var dayBinding: Binding<Date> {
        Binding(get: { form.day ?? Date() }, set: {
            form.day = Calendar.current.startOfDay(for: $0)
            form.unsure.remove(.date)
        })
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: form.hour, minute: form.minute, second: 0, of: Date()) ?? Date()
        }, set: {
            form.hour = Calendar.current.component(.hour, from: $0)
            form.minute = Calendar.current.component(.minute, from: $0)
            form.unsure.remove(.time)
        })
    }

    // MARK: - Постановление

    var detailsSection: some View {
        Section {
            numberRow(String(localized: "Скорость, км/ч"), \.speed, .speed)
            numberRow(String(localized: "Ограничение, км/ч"), \.limit, .limit)
            numberRow(String(localized: "Сумма, сум"), \.amount, .amount)
            LabeledContent {
                TextField("не указан", text: text(\.resolution, .resolution))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            } label: {
                fieldLabel(String(localized: "Номер"), .resolution)
            }
            optionalDate(String(localized: "Дата постановления"), \.issued, .issued)
            optionalDate(String(localized: "Срок оплаты"), \.due, .due)
        } header: {
            Text("Постановление")
        } footer: {
            Text("Пустое поле — в постановлении его нет. Срок оплаты не указан — посчитаем ориентир от даты постановления.")
        }
    }

    private func numberRow(_ title: String, _ path: WritableKeyPath<FineForm, String>,
                           _ name: FineDraft.Name) -> some View {
        LabeledContent {
            TextField("не указано", text: text(path, name))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        } label: {
            fieldLabel(title, name)
        }
    }

    @ViewBuilder
    private func optionalDate(_ title: String, _ path: WritableKeyPath<FineForm, Date?>,
                              _ name: FineDraft.Name) -> some View {
        if form[keyPath: path] != nil {
            HStack {
                DatePicker(selection: Binding(get: { form[keyPath: path] ?? Date() }, set: {
                    form[keyPath: path] = $0
                    form.unsure.remove(name)
                }), displayedComponents: .date) {
                    fieldLabel(title, name)
                }
                Button {
                    form[keyPath: path] = nil
                    form.unsure.remove(name)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textTertiary)
                        .tapTarget()
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Убрать дату"))
            }
        } else {
            Button {
                form[keyPath: path] = form.day ?? Calendar.current.startOfDay(for: Date())
            } label: {
                LabeledContent(title) { Text("не указан").foregroundStyle(Theme.textTertiary) }
            }
            .foregroundStyle(Theme.textPrimary)
        }
    }

    // MARK: - Помощники

    /// Подпись поля; найденное разбором без уверенности — «проверьте».
    func fieldLabel(_ title: String, _ name: FineDraft.Name) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if form.unsure.contains(name) {
                Label("проверьте", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.rounded(11, .semibold))
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    /// Привязка поля, которая снимает «проверьте», когда поле правит человек
    /// (подстановка разбора идёт мимо неё и пометку не снимает).
    private func text(_ path: WritableKeyPath<FineForm, String>, _ name: FineDraft.Name) -> Binding<String> {
        Binding(get: { form[keyPath: path] }, set: {
            // Сумму группируем по разрядам прямо при вводе.
            form[keyPath: path] = name == .amount ? FineForm.groupedDigits($0) : $0
            form.unsure.remove(name)
        })
    }
}
