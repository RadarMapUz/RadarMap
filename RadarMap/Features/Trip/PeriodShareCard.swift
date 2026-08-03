//
//  PeriodShareCard.swift
//  RadarMap
//
//  «Моя неделя за рулём» — шеринг-карточка периода: карта, главные цифры и
//  зона риска. Зона риска — самое вирусное: «где я рискую» интереснее голых
//  километров. Единственная карточка уровня статистики (карточка одной поездки
//  — TripShareCard в деталке).
//

import SwiftUI

struct PeriodShareCard: View {
    let summary: PeriodSummary
    let periodTitle: String
    var mapImage: UIImage? = nil

    var body: some View {
        ShareCardShell(subtitle: periodTitle) {
            if let mapImage {
                Image(uiImage: mapImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1))
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
            }

            Spacer()

            // Герой: километры + дельта к прошлому периоду + кольцо рейтинга.
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Formatting.distance(summary.distance))
                            .font(.system(size: 52, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                        if let delta = summary.distanceDeltaPercent {
                            Label("\(abs(delta))%",
                                  systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(delta >= 0 ? Theme.accent : .white.opacity(0.55))
                        }
                    }
                }
                Spacer(minLength: 0)
                if let rating = summary.rating {
                    RatingRing(rating: rating, animated: false)
                        .frame(width: 92, height: 92)
                }
            }
            .padding(.horizontal, 32)

            // Зона риска ИЛИ чистый период — честно, как на экране.
            Group {
                if summary.overPasses > 0, let place = summary.topOverLocation {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 17, weight: .bold))
                        Text(String(format: String(localized: "Зона риска: %@"), place))
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Theme.danger.opacity(0.12), in: Capsule())
                } else if summary.cleanPasses > 0 {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 17, weight: .bold))
                        Text("Ни одного превышения у камер")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(Theme.success)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Theme.success.opacity(0.12), in: Capsule())
                }
            }
            .padding(.top, 16)

            Spacer()

            HStack(spacing: 0) {
                ShareMetric(value: "\(summary.trips)",
                            label: String(localized: "поездок"),
                            icon: "car.fill", tint: Theme.accent)
                ShareMetricDivider()
                ShareMetric(value: "\(summary.cameras)",
                            label: String(localized: "камер"),
                            icon: "camera.fill", tint: Theme.camera)
                ShareMetricDivider()
                ShareMetric(value: Formatting.duration(summary.movingDuration),
                            label: String(localized: "за рулём"),
                            icon: "clock.fill", tint: Theme.intelligent)
            }
            .shareMetricsTile()
            .padding(.bottom, 4)
        }
    }
}
