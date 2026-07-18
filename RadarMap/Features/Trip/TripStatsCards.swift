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
            if let mapImage {
                Image(uiImage: mapImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1))
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
            }

            Spacer()

            // Герой: кольцо рейтинга слева, титул и серия — справа. Плотная
            // горизонтальная группа вместо болтающегося по центру столбика.
            if let rating = trip.rating {
                HStack(spacing: 24) {
                    RatingRing(rating: rating, animated: false)
                        .frame(width: 132, height: 132)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Рейтинг водителя")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                            .textCase(.uppercase)
                            .kerning(1.1)
                        Text(DrivingScore.level(for: rating))
                            .font(.system(size: 27, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                        if trip.lifetime.cleanStreak >= 2 {
                            Label(String(format: String(localized: "%lld чистых подряд"),
                                         trip.lifetime.cleanStreak),
                                  systemImage: "flame.fill")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.radar)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 32)
            }

            // Хвастаемся честным: «0 штрафов за 30 дней» звучит сильнее выдуманной суммы.
            if case let month = TripHistory.month30(trip.history), month.clean + month.over > 0 {
                HStack(spacing: 10) {
                    Image(systemName: month.over == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 18, weight: .bold))
                    Text(month.over == 0 ? String(localized: "0 штрафов за 30 дней")
                                         : String(format: String(localized: "риск ≈ %@"),
                                                  Formatting.money(month.risk)))
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(month.over == 0 ? Theme.success : Theme.danger)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background((month.over == 0 ? Theme.success : Theme.danger).opacity(0.12),
                            in: Capsule())
                .padding(.top, 18)
            }

            Spacer()

            HStack(spacing: 0) {
                ShareMetric(value: Formatting.distance(trip.weekSummary?.distance ?? 0),
                            label: String(localized: "за 7 дней"),
                            icon: "point.topleft.down.to.point.bottomright.curvepath",
                            tint: Theme.success)
                ShareMetricDivider()
                ShareMetric(value: "\(trip.weekSummary?.cameras ?? 0)",
                            label: String(localized: "камер"),
                            icon: "camera.fill", tint: Theme.camera)
                ShareMetricDivider()
                ShareMetric(value: "\(trip.lifetime.trips)",
                            label: String(localized: "поездок всего"),
                            icon: "car.fill", tint: Theme.accent)
            }
            .shareMetricsTile()
            .padding(.bottom, 4)
        }
    }
}
