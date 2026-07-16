//
//  StatsInfoSheets.swift
//  RadarMap
//
//  Расшифровки Итогов: как считается рейтинг, из чего складывается экономия,
//  детали достижений. Открываются тапом по карточкам — цифрам можно доверять,
//  только когда понятно, откуда они берутся.
//

import SwiftUI

// MARK: - Как считается рейтинг

struct RatingInfoSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    scaleSection
                    componentsSection
                    tipsSection
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Рейтинг вождения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: 16) {
            if let rating = env.trip.rating {
                RatingRing(rating: rating)
                    .frame(width: 84, height: 84)
            } else {
                Image(systemName: "gauge.with.needle")
                    .font(.rounded(30))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 84, height: 84)
                    .background(Theme.accent.opacity(0.10), in: Circle())
            }
            VStack(alignment: .leading, spacing: 4) {
                if let rating = env.trip.rating {
                    Text(DrivingScore.level(for: rating))
                        .font(.rounded(17, .bold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Text("Средний балл поездок за 30 дней. Длинные поездки весят больше коротких.")
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
    }

    private var scaleSection: some View {
        infoCard(title: "Шкала") {
            scaleRow(Theme.success, "90–100", String(localized: "Идеальный стиль"))
            scaleRow(Theme.success.opacity(0.75), "75–89", String(localized: "Аккуратный водитель"))
            scaleRow(Theme.radar, "60–74", String(localized: "Уверенный, но с риском"))
            scaleRow(Theme.danger, "0–59", String(localized: "Рискованный стиль"))
        }
    }

    private func scaleRow(_ color: Color, _ range: String, _ name: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(range)
                .font(.rounded(14, .bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 64, alignment: .leading)
            Text(name)
                .font(.rounded(14))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
    }

    private var componentsSection: some View {
        infoCard(title: "Из чего складывается") {
            componentRow(icon: "camera.metering.center.weighted", tint: Theme.accent,
                         title: String(localized: "Скорость у камер"),
                         text: String(localized: "Каждый проезд камеры с известным лимитом: берём минимальную скорость в 80 м перед камерой — разгон после проезда не считается. Штрафные ступени снижают балл сильнее всего."))
            componentRow(icon: "waveform.path.ecg", tint: Theme.intelligent,
                         title: String(localized: "Плавность езды"),
                         text: String(localized: "Резкие разгоны и торможения по треку поездки снижают балл."))
        }
    }

    private func componentRow(icon: String, tint: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.rounded(15, .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rounded(14, .semibold)).foregroundStyle(Theme.textPrimary)
                Text(text).font(.rounded(12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var tipsSection: some View {
        infoCard(title: "Как поднять") {
            tipRow(String(localized: "Проезжайте камеры не выше лимита — уже +6 км/ч попадает в штрафную ступень."))
            tipRow(String(localized: "Разгоняйтесь и тормозите плавно."))
            tipRow(String(localized: "Балл записывается за каждую поездку — смотрите его в истории."))
        }
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.rounded(13))
                .foregroundStyle(Theme.success)
                .padding(.top, 2)
            Text(text)
                .font(.rounded(13))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Как считаем экономию

struct SavingsInfoSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    fineTable
                    method
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Экономия на штрафах")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        let lifetime = env.trip.lifetime
        return VStack(spacing: 12) {
            Text("≈ \(Formatting.money(lifetime.savedFinesSum))")
                .font(.rounded(34, .heavy))
                .foregroundStyle(Theme.success)
            HStack(spacing: 0) {
                headerMetric(Formatting.money(env.trip.monthSaved), String(localized: "за 30 дней"))
                divider
                headerMetric("\(lifetime.camerasInLimit)", String(localized: "камер в лимите"))
                divider
                headerMetric("\(lifetime.trips)", String(localized: "поездок всего"))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(Theme.success.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
            .stroke(Theme.success.opacity(0.25), lineWidth: 1))
    }

    private func headerMetric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.rounded(15, .bold)).foregroundStyle(Theme.textPrimary)
            Text(label).font(.rounded(11)).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(Theme.success.opacity(0.2)).frame(width: 1, height: 30)
    }

    private var fineTable: some View {
        infoCard(title: "Штрафы за превышение — ст. 128-3 КоАО") {
            fineRow("+6…20 км/ч", brv: 1)
            fineRow("+21…40 км/ч", brv: 5)
            fineRow(String(localized: "свыше +40 км/ч"), brv: 9)
            Text("Первые ~\(Int(FineSchedule.toleranceKmh)) км/ч сверх лимита камеры обычно не штрафуют. Суммы — первая фиксация, повторные нарушения заметно дороже.")
                .font(.rounded(11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private func fineRow(_ range: String, brv: Double) -> some View {
        HStack {
            Text(range)
                .font(.rounded(14, .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(brv == 1 ? String(localized: "1 БРВ") : String(format: String(localized: "%lld БРВ"), Int(brv)))
                .font(.rounded(12, .medium))
                .foregroundStyle(Theme.textTertiary)
            Text(Formatting.money(brv * FineSchedule.brv))
                .font(.rounded(14, .bold).monospacedDigit())
                .foregroundStyle(Theme.danger)
                .frame(width: 130, alignment: .trailing)
        }
    }

    private var method: some View {
        infoCard(title: "Как считаем") {
            Text("Каждая камера с известным лимитом, пройденная без штрафной скорости, — несостоявшийся минимальный штраф в 1 БРВ. Складываем такие проезды. Это оценка, а не гарантия: повторность и допуски конкретных камер мы знать не можем.")
                .font(.rounded(13))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Деталь достижения

struct AchievementInfoSheet: View {
    let badge: Achievement
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                if badge.earned {
                    Circle().fill(Theme.accent.gradient)
                        .shadow(color: Theme.accent.opacity(0.5), radius: 12)
                } else {
                    Circle().fill(Theme.surface)
                    Circle()
                        .trim(from: 0, to: badge.fraction)
                        .stroke(Theme.accent.opacity(0.6),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(2)
                }
                Image(systemName: badge.icon)
                    .font(.rounded(30, .semibold))
                    .foregroundStyle(badge.earned ? Theme.background : Theme.textTertiary)
            }
            .frame(width: 84, height: 84)
            .padding(.top, 26)

            Text(badge.title)
                .font(.rounded(19, .bold))
                .foregroundStyle(Theme.textPrimary)

            Text(badge.detail)
                .font(.rounded(13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            if badge.earned {
                Label("Получено!", systemImage: "checkmark.seal.fill")
                    .font(.rounded(14, .bold))
                    .foregroundStyle(Theme.success)
                    .padding(.top, 2)
            } else {
                VStack(spacing: 6) {
                    ProgressView(value: badge.fraction)
                        .tint(Theme.accent)
                        .padding(.horizontal, 40)
                    Text(String(format: String(localized: "%@ из %@"),
                                Self.count(badge.progress), Self.count(badge.target)))
                        .font(.rounded(12, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.background)
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
    }

    private static func count(_ value: Double) -> String {
        value >= 100 ? "\(Int(value.rounded()))"
            : value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", locale: .current, value)
    }
}

// MARK: - Общий каркас карточки

@ViewBuilder
private func infoCard(title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Text(title)
            .font(.rounded(14, .semibold))
            .foregroundStyle(Theme.textSecondary)
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
}
