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

// MARK: - Карточка «Мои итоги» для шеринга (рендерится в 1080×1350)

struct StatsShareCard: View {
    let trip: TripStats
    /// Карта последней поездки (район + трек) — шеринг информативнее сухих цифр.
    var mapImage: UIImage? = nil

    var body: some View {
        ShareCardShell(subtitle: String(localized: "Мои итоги")) {
            Spacer()

            if let mapImage {
                Image(uiImage: mapImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
            }

            if let rating = trip.rating {
                RatingRing(rating: rating, animated: false)
                    .frame(width: mapImage == nil ? 170 : 120,
                           height: mapImage == nil ? 170 : 120)
                Text(DrivingScore.level(for: rating))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 16)
                if trip.lifetime.cleanStreak >= 2 {
                    Label(String(format: String(localized: "чистая серия: %lld подряд"),
                                 trip.lifetime.cleanStreak),
                          systemImage: "flame.fill")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.radar)
                        .padding(.top, 6)
                }
            }

            // Хвастаемся честным: «0 штрафов за 30 дней» звучит сильнее выдуманной суммы.
            if case let month = TripHistory.month30(trip.history), month.clean + month.over > 0 {
                VStack(spacing: 4) {
                    Text("Штрафы за 30 дней")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(month.over == 0 ? String(localized: "0 штрафов")
                                         : String(format: String(localized: "риск ≈ %@"),
                                                  Formatting.money(month.risk)))
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(month.over == 0 ? Theme.success : Theme.danger)
                }
                .padding(.top, 26)
            }

            Spacer()

            HStack(spacing: 0) {
                ShareMetric(value: Formatting.distance(trip.weekSummary?.distance ?? 0),
                            label: String(localized: "за 7 дней"))
                ShareMetricDivider()
                ShareMetric(value: "\(trip.weekSummary?.cameras ?? 0)", label: String(localized: "камер"))
                ShareMetricDivider()
                ShareMetric(value: "\(trip.lifetime.trips)", label: String(localized: "поездок всего"))
            }
            .shareMetricsRow()
        }
    }
}
