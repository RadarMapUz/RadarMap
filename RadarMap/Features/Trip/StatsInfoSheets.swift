//
//  StatsInfoSheets.swift
//  RadarMap
//
//  Расшифровки Итогов: как считается рейтинг, из чего складываются штрафы,
//  детали достижений. Открываются тапом по карточкам — цифрам можно доверять,
//  только когда понятно, откуда они берутся.
//
//  Шиты получают ТУ ЖЕ сводку, которую показала карточка, и подпись её окна.
//  Раньше они читали собственные агрегаты с зашитыми 30 днями: в шапке было
//  «85 за неделю», по тапу открывалось «82 за 30 дней» — пользователь нажимал
//  на цифру и получал другую.
//

import SwiftUI
import Charts

// MARK: - Как считается рейтинг

struct RatingInfoSheet: View {
    let summary: PeriodSummary
    let period: StatsPeriod
    /// Окно, за которое показан рейтинг: по нему считается разложение.
    var interval: DateInterval = DateInterval(start: .distantPast, end: Date())
    var onOpenTrip: ((Double) -> Void)? = nil
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    breakdownSection
                    trendSection
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
            if let rating = summary.rating {
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
                if let rating = summary.rating {
                    Text(DrivingScore.level(for: rating))
                        .font(.rounded(17, .bold))
                        .foregroundStyle(Theme.textPrimary)
                }
                // Окно называем явно: это ровно та цифра, по которой тапнули.
                Text(String(format: String(localized: "Средний балл поездок %@. Длинные поездки весят больше коротких."),
                            period.caption))
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let previous = summary.previousRating {
                    Text(String(format: String(localized: "Прошлый период: %lld"), previous))
                        .font(.rounded(11, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .statCard()
    }

    // MARK: Из чего сложился ВАШ рейтинг

    /// Разложение недобора по поездкам: сумма строк ровно равна 100 − рейтинг,
    /// поэтому блок можно проверить сложением. Раньше шит объяснял методику и
    /// молчал о том, что именно съело баллы.
    @ViewBuilder private var breakdownSection: some View {
        let items = RatingBreakdown.contributions(records: env.trip.history,
                                                  days: env.trip.days, in: interval)
        if let rating = summary.rating, !items.isEmpty {
            infoCard(title: String(localized: "Из чего сложился ваш рейтинг")) {
                HStack(spacing: 6) {
                    Text("100")
                        .font(.rounded(15, .heavy).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                    Text("−\(Int((100 - Double(rating)).rounded()))")
                        .font(.rounded(15, .heavy).monospacedDigit())
                        .foregroundStyle(Theme.danger)
                    Text("=")
                        .font(.rounded(15, .medium))
                        .foregroundStyle(Theme.textTertiary)
                    Text("\(rating)")
                        .font(.rounded(17, .heavy).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 2)

                // Крупные вклады показываем строками, мелочь сворачиваем: список
                // из двадцати строк по −0,1 балла ничего не объясняет.
                let shown = Array(items.prefix(AppConfig.breakdownVisibleRows))
                    .filter { $0.points >= 0.5 }
                ForEach(shown) { item in
                    contributionRow(item)
                }
                let restCount = items.count - shown.count
                let restPoints = items.dropFirst(shown.count).reduce(0) { $0 + $1.points }
                if restCount > 0, restPoints > 0 {
                    HStack {
                        Text(String(format: String(localized: "Остальные поездки: %lld"), restCount))
                            .font(.rounded(12))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer(minLength: 0)
                        Text(pointsText(restPoints))
                            .font(.rounded(13, .semibold).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                if let next = DrivingScore.nextLevel(for: rating) {
                    Text(String(format: String(localized: "До уровня «%1$@» — %2$lld балла"),
                                next.name, next.threshold - rating))
                        .font(.rounded(11, .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 2)
                }
                // Честная оговорка: часть поездок в рейтинг вообще не входит.
                let unrated = RatingBreakdown.unratedTrips(records: env.trip.history, in: interval)
                if unrated > 0 {
                    Text(String(format: String(localized: "Ещё %lld поездок без известных лимитов и трека — в рейтинг они не вошли"),
                                unrated))
                        .font(.rounded(11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func contributionRow(_ item: RatingContribution) -> some View {
        Button {
            guard item.isTrip, let onOpenTrip else { return }
            dismiss()
            onOpenTrip(item.id)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.date.formatted(date: .abbreviated, time: item.isTrip ? .shortened : .omitted))
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(Formatting.distance(item.distanceMeters)) · \(String(format: String(localized: "балл %lld"), item.score))")
                        .font(.rounded(11))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)
                Text(pointsText(item.points))
                    .font(.rounded(15, .heavy).monospacedDigit())
                    .foregroundStyle(item.points >= 1 ? Theme.danger : Theme.textSecondary)
                if item.isTrip, onOpenTrip != nil {
                    Image(systemName: "chevron.right")
                        .font(.rounded(11, .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isTrip || onOpenTrip == nil)
        .accessibilityElement(children: .combine)
    }

    private func pointsText(_ points: Double) -> String {
        points < 0.05 ? "0" : "−" + String(format: "%.1f", locale: .current, points)
    }

    // MARK: Динамика

    /// Стабильный стиль или одна поездка утянула среднее — по дням окна.
    @ViewBuilder private var trendSection: some View {
        let points = RatingBreakdown.dailyRatings(days: env.trip.days, in: interval)
        if points.count >= 2 {
            infoCard(title: String(localized: "Рейтинг по дням")) {
                Chart(points, id: \.day) { item in
                    LineMark(x: .value("День", item.day, unit: .day),
                             y: .value("Рейтинг", item.rating))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Theme.accent)
                    PointMark(x: .value("День", item.day, unit: .day),
                              y: .value("Рейтинг", item.rating))
                        .foregroundStyle(TripHistorySection.scoreColor(item.rating))
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) { _ in
                        AxisValueLabel().font(.rounded(9)).foregroundStyle(Theme.textTertiary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                            .font(.rounded(9)).foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(height: 92)
            }
        }
    }

    private var scaleSection: some View {
        infoCard(title: String(localized: "Шкала")) {
            scaleRow(Theme.success, "90–100", String(localized: "Идеальный стиль"))
            scaleRow(Theme.success.opacity(0.75), "75–89", String(localized: "Аккуратный водитель"))
            scaleRow(Theme.warning, "60–74", String(localized: "Уверенный, но с риском"))
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
        infoCard(title: String(localized: "Из чего складывается")) {
            componentRow(icon: "camera.metering.center.weighted", tint: Theme.accent,
                         title: String(localized: "Скорость у камер"),
                         text: String(localized: "Каждый проезд камеры с известным лимитом: берём минимальную скорость в 80 м перед камерой — разгон после проезда не считается. Штрафные ступени снижают балл сильнее всего."))
            componentRow(icon: "waveform.path.ecg", tint: Theme.Types.intelligent,
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
        infoCard(title: String(localized: "Как поднять")) {
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
    let summary: PeriodSummary
    let period: StatsPeriod
    /// Окно, за которое показана сумма: по нему считаются камеры-источники.
    var interval: DateInterval = DateInterval(start: .distantPast, end: Date())
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    sourcesSection
                    fineTable
                    method
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Возможные штрафы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        // Ровно те цифры, что на карточке: то же окно, тот же расчёт.
        let ok = summary.overPasses == 0
        return VStack(spacing: 12) {
            Text(period.caption)
                .font(.rounded(11, .medium))
                .foregroundStyle(Theme.textTertiary)
            Text(ok ? String(localized: "0 штрафов")
                    : String(format: String(localized: "риск ≈ %@"),
                             Formatting.money(summary.fineRisk)))
                .font(.rounded(34, .heavy))
                .foregroundStyle(ok ? Theme.success : Theme.danger)
            HStack(spacing: 0) {
                headerMetric("\(summary.cleanPasses)", String(localized: "в лимите"))
                divider
                headerMetric("\(summary.overPasses)", String(localized: "превышений"))
                divider
                headerMetric("\(summary.trips)", String(localized: "поездок"))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background((ok ? Theme.success : Theme.danger).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
            .stroke((ok ? Theme.success : Theme.danger).opacity(0.25), lineWidth: 1))
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

    /// Откуда взялась сумма: камеры от дорогих к дешёвым. Сумма строк равна
    /// общему риску за то же окно — блок можно проверить сложением.
    @ViewBuilder private var sourcesSection: some View {
        let sources = RatingBreakdown.fineSources(records: env.trip.history, in: interval)
        if !sources.isEmpty {
            infoCard(title: String(localized: "Откуда сумма")) {
                ForEach(sources.prefix(AppConfig.fineSourcesVisibleRows)) { source in
                    HStack(spacing: 10) {
                        Image(systemName: "camera.metering.center.weighted")
                            .font(.rounded(12, .bold))
                            .foregroundStyle(Theme.danger)
                            .frame(width: 28, height: 28)
                            .background(Theme.danger.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.location)
                                .font(.rounded(13, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text(String(format: String(localized: "штрафуемых проездов: %lld"),
                                        source.times))
                                .font(.rounded(11))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: 8)
                        Text(Formatting.money(source.sum))
                            .font(.rounded(14, .bold).monospacedDigit())
                            .foregroundStyle(Theme.danger)
                    }
                    .accessibilityElement(children: .combine)
                }
                let rest = sources.dropFirst(AppConfig.fineSourcesVisibleRows)
                if !rest.isEmpty {
                    HStack {
                        Text(String(format: String(localized: "Остальные камеры: %lld"), rest.count))
                            .font(.rounded(12))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer(minLength: 0)
                        Text(Formatting.money(rest.reduce(0) { $0 + $1.sum }))
                            .font(.rounded(13, .semibold).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }

    private var fineTable: some View {
        infoCard(title: String(localized: "Штрафы за превышение — ст. 128-3 КоАО")) {
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
        infoCard(title: String(localized: "Как считаем")) {
            Text("Берём каждый проезд камеры, у которой известен лимит дороги, и сравниваем с ним скорость в точке фиксации. Попал в штрафную ступень — прибавляем её сумму к риску. Проезды камер без известного лимита не считаем нарушением: выдумывать превышение мы не вправе.")
                .font(.rounded(13))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Это оценка, а не выписанные штрафы: повторность нарушений и допуски конкретных камер нам неизвестны.")
                .font(.rounded(11))
                .foregroundStyle(Theme.textTertiary)
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
private func infoCard(title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        SectionHeader(title)
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .statCard()
}
