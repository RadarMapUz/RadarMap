//
//  TripStatsCards.swift
//  RadarMap
//
//  Бейдж достижения и шеринг-карточка «Мои итоги» — вспомогательные вью
//  экрана Итогов, вынесены из основного файла.
//

import SwiftUI
import UIKit

// MARK: - Бейдж достижения

/// Полученный — залит акцентом; будущий — серый с кольцом прогресса, видно, сколько осталось.
struct AchievementBadge: View {
    let badge: Achievement

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                if badge.earned {
                    Circle().fill(Theme.accent.gradient)
                        .shadow(color: Theme.accent.opacity(0.45), radius: 6)
                } else {
                    Circle().fill(Theme.surface)
                    Circle()
                        .trim(from: 0, to: badge.fraction)
                        .stroke(Theme.accent.opacity(0.55),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(1.5)
                }
                Image(systemName: badge.icon)
                    .font(.rounded(19, .semibold))
                    .foregroundStyle(badge.earned ? Theme.background : Theme.textTertiary)
            }
            .frame(width: 56, height: 56)

            Text(badge.title)
                .font(.rounded(10, .medium))
                .foregroundStyle(badge.earned ? Theme.textPrimary : Theme.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(width: 82)
    }
}
