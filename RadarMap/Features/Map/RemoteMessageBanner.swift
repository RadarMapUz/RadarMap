//
//  RemoteMessageBanner.swift
//  RadarMap
//
//  Видимая половина «пульта»: объявление с сервера или просьба обновиться.
//  Появляется редко и по делу — работы на сервере, погашенная функция,
//  неподдерживаемая версия.
//
//  Закрывается тапом и больше не показывается для ЭТОГО текста: плашка,
//  которую нельзя убрать, за рулём читается как поломка приложения. Новое
//  объявление придёт с новым заголовком и покажется снова.
//

import SwiftUI

struct RemoteMessageBanner: View {
    @Environment(AppEnvironment.self) private var env
    /// Заголовок закрытого объявления. Живёт в памяти сцены, а не в Storage:
    /// объявления недолгие, а лишний ключ в настройках — навсегда.
    @State private var dismissedTitle: String?

    var body: some View {
        if let message = env.config.banner, message.title != dismissedTitle {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .font(.system(size: 18, weight: .semibold))
                VStack(alignment: .leading, spacing: 3) {
                    Text(message.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let body = message.body, !body.isEmpty {
                        Text(body)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerMedium)
                    .stroke(Theme.warning.opacity(0.35), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.2)) { dismissedTitle = message.title }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Закрыть объявление"))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
