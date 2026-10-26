//
//  FeedbackFormView.swift
//  RadarMap
//
//  «Написать разработчику»: свободное сообщение + необязательный контакт.
//  Каждое сообщение читается вручную — это главный канал беты и прода.
//

import SwiftUI

struct FeedbackFormView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private enum SendState: Equatable { case idle, sending, sent, queued }
    @State private var message = ""
    @State private var contact = ""
    @State private var state: SendState = .idle
    @State private var confirmsDiscard = false
    @FocusState private var messageFocused: Bool

    /// Есть набранный и ещё не отправленный текст — его нельзя терять молча.
    private var hasDraft: Bool {
        state == .idle && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if state == .sent || state == .queued {
                        sentCard
                    } else {
                        editor
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Написать разработчику")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // «Закрыть» и смахивание вниз выбрасывали набранное сообщение
                // без вопроса — а это часто пять минут описания бага. С текстом
                // лист закрывается только через подтверждение.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        if hasDraft { confirmsDiscard = true } else { dismiss() }
                    }
                }
            }
            .confirmationDialog("Удалить сообщение?", isPresented: $confirmsDiscard,
                                titleVisibility: .visible) {
                Button("Удалить", role: .destructive) { dismiss() }
                Button("Продолжить писать", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(hasDraft)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private var editor: some View {
        Text("Нашли ошибку или есть идея? Мы читаем каждое сообщение.")
            .font(.rounded(14))
            .foregroundStyle(Theme.textSecondary)

        TextEditor(text: $message)
            .font(.rounded(15))
            .foregroundStyle(Theme.textPrimary)
            .scrollContentBackground(.hidden)
            .focused($messageFocused)
            .frame(minHeight: 140)
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .overlay(alignment: .topLeading) {
                if message.isEmpty {
                    Text("Опишите проблему или идею…")
                        .font(.rounded(15))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 20)
                        .padding(.leading, 17)
                        .allowsHitTesting(false)
                }
            }

        TextField("Контакт для ответа (необязательно)", text: $contact)
            .font(.rounded(15))
            .foregroundStyle(Theme.textPrimary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))

        if state == .sending {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Отправляем…")
                    .font(.rounded(14, .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            PrimaryButton(title: "Отправить", systemImage: "paperplane.fill") { send() }
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
        }
    }

    /// Честный итог: «отправлено» либо «сохранено в очередь» — не врём про сеть.
    private var sentCard: some View {
        let queued = state == .queued
        return VStack(spacing: 12) {
            Image(systemName: queued ? "tray.full.fill" : "checkmark.circle.fill")
                .font(.rounded(44, .bold))
                .foregroundStyle(queued ? Theme.accent : Theme.success)
                .shadow(color: (queued ? Theme.accent : Theme.success).opacity(0.5), radius: 12)
            Text(queued ? String(localized: "Спасибо! Отправим, когда появится связь.")
                        : String(localized: "Спасибо! Мы читаем каждое сообщение."))
                .font(.rounded(16, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func send() {
        messageFocused = false
        state = .sending
        Task {
            // Очередь не теряет сообщение: нет связи → уйдёт при следующем запуске.
            let outcome = await env.feedback.sendMessage(message, contact: contact)
            withMotion(Motion.standard) {
                state = outcome == .queued ? .queued : .sent
            }
            await Task.pause(seconds: 1.6)
            dismiss()
        }
    }
}
