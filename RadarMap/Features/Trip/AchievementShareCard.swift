//
//  AchievementShareCard.swift
//  RadarMap
//
//  «1 000 км» / «5 чистых подряд» — карточка достижения.
//
//  Километрами и рейтингом делятся редко, а вот взятой планкой — охотно:
//  это про человека, а не про цифру. Карточка живёт на общем каркасе
//  (ShareCardShell), поэтому шапка, футер и оба формата у неё те же, что у
//  поездки и периода, — три темы, один визуальный язык.
//
//  Делиться можно только ВЗЯТЫМ достижением: картинка «осталось 170 км»
//  никому не интересна, а полоса прогресса наружу выглядит как жалоба.
//

import SwiftUI

struct AchievementShareCard: View {
    let badge: Achievement
    /// Пожизненные цифры под достижением: они и есть его контекст.
    let lifetime: LifetimeStats
    var format: ShareFormat = .feed

    var body: some View {
        ShareCardShell(subtitle: String(localized: "Достижение"), format: format) {
            Spacer(minLength: 24)

            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.16))
                    .frame(width: 210, height: 210)
                Circle()
                    .fill(Theme.accent.gradient)
                    .frame(width: 150, height: 150)
                    .shadow(color: Theme.accent.opacity(0.55), radius: 26)
                Image(systemName: badge.icon)
                    .font(.system(size: 66, weight: .semibold))
                    .foregroundStyle(Theme.background)
            }

            Text(badge.title)
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.top, 24)
                .padding(.horizontal, 32)

            Text("Достижение получено")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .padding(.top, 6)

            Spacer(minLength: 20)

            HStack(spacing: 0) {
                ShareMetric(value: Formatting.distance(lifetime.distanceMeters),
                            label: String(localized: "всего"),
                            icon: "point.topleft.down.to.point.bottomright.curvepath",
                            tint: Theme.success)
                ShareMetricDivider()
                ShareMetric(value: "\(lifetime.camerasInLimit)",
                            label: String(localized: "камер в лимите"),
                            icon: "checkmark.shield.fill", tint: Theme.accent)
                ShareMetricDivider()
                ShareMetric(value: "\(lifetime.bestStreak)",
                            label: String(localized: "лучшая серия"),
                            icon: "flame.fill", tint: Theme.warning)
            }
            .shareMetricsTile()
            .padding(.bottom, 4)
        }
    }
}
