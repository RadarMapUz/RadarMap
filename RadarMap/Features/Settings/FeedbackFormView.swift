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

    private enum SendState: Equatable { case idle, sending, sent, failed }
    @State private var message = ""
    @State private var contact = ""
    @State private var state: SendState = .idle
    @FocusState private var messageFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if state == .sent {
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
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

        if state == .failed {
            Label("Не удалось отправить — проверьте сеть.", systemImage: "wifi.slash")
                .font(.rounded(13))
                .foregroundStyle(Theme.danger)
        }

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

    private var sentCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.rounded(44, .bold))
                .foregroundStyle(Theme.success)
                .shadow(color: Theme.success.opacity(0.5), radius: 12)
            Text("Спасибо! Мы читаем каждое сообщение.")
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
            let ok = await env.feedback.sendMessage(message, contact: contact)
            withAnimation(.spring(duration: 0.35)) {
                state = ok ? .sent : .failed
            }
            guard ok else { return }
            try? await Task.sleep(for: .seconds(1.6))
            dismiss()
        }
    }
}
