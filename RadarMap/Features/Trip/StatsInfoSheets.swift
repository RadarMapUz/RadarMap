//
//  StatsInfoSheets.swift
//  RadarMap
//
//  Расшифровки Итогов: из чего складывается сумма возможных штрафов и детали
//  достижений. Открываются тапом по карточкам — цифрам можно доверять, только
//  когда понятно, откуда они берутся.
//
//  Разбор рейтинга здесь больше не живёт: он вырос из расшифровки в отдельный
//  экран со своим стеком — RatingDetailSheet.
//
//  Шиты получают ТУ ЖЕ сводку, которую показала карточка, и подпись её окна.
//  Раньше они читали собственные агрегаты с зашитыми 30 днями: в шапке было
//  «85 за неделю», по тапу открывалось «82 за 30 дней» — пользователь нажимал
//  на цифру и получал другую.
//

import SwiftUI

// MARK: - Как считаем экономию

struct SavingsInfoSheet: View {
    let summary: PeriodSummary
    let period: StatsPeriod
    /// Окно, за которое показана сумма: по нему считаются камеры-источники.
    var interval: DateInterval = DateInterval(start: .distantPast, end: Date())
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// Камеры-источники: считаются один раз на открытие, не в body.
    @State private var sources: [FineSource] = []

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
        .task {
            sources = RatingBreakdown.fineSources(records: env.trip.history, in: interval)
        }
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
    /// Данные из .task, не из body: полный перебор истории со всеми проездами
    /// на каждый пересчёт вьюхи — ровно то, от чего ушёл RatingDetailSheet.
    @ViewBuilder private var sourcesSection: some View {
        if !sources.isEmpty {
            infoCard(title: String(localized: "Откуда сумма")) {
                ForEach(sources.prefix(AppConfig.fineSourcesVisibleRows)) { source in
                    HStack(spacing: 10) {
                        Image(systemName: "camera.metering.center.weighted")
                            .font(.rounded(15, .bold))
                            .foregroundStyle(Theme.danger)
                            .frame(width: 28, height: 28)
                            .background(Theme.danger.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.location)
                                .font(.rounded(15, .semibold))
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
                            .font(.rounded(15))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer(minLength: 0)
                        Text(Formatting.money(rest.reduce(0) { $0 + $1.sum }))
                            .font(.rounded(15, .semibold).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }

    private var fineTable: some View {
        infoCard(title: String(localized: "Штрафы за превышение — ст. 128-3 КоАО")) {
            fineRow(String(localized: "+6…20 км/ч"), brv: 1)
            fineRow(String(localized: "+21…40 км/ч"), brv: 5)
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
                .font(.rounded(15, .medium))
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
                .font(.rounded(15))
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
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var shareSubject: ShareSubjectBox?

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
                .font(.rounded(15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            if badge.earned {
                Label("Получено!", systemImage: "checkmark.seal.fill")
                    .font(.rounded(14, .bold))
                    .foregroundStyle(Theme.success)
                    .padding(.top, 2)
                // Делиться можно только взятой планкой: «осталось 170 км»
                // никому не интересно, а полоса прогресса наружу читается
                // как жалоба, а не как достижение.
                Button {
                    shareSubject = ShareSubjectBox(
                        subject: .achievement(badge, lifetime: env.trip.lifetime))
                } label: {
                    Label("Поделиться", systemImage: "square.and.arrow.up")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .padding(.top, 4)
            } else {
                VStack(spacing: 6) {
                    ProgressView(value: badge.fraction)
                        .tint(Theme.accent)
                        .padding(.horizontal, 40)
                    Text(String(format: String(localized: "%@ из %@"),
                                Self.count(badge.progress), Self.count(badge.target)))
                        .font(.rounded(15, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.background)
        .sheet(item: $shareSubject) { box in
            SharePreviewSheet(subject: box.subject)
        }
        .presentationDetents([.height(320), .medium])
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

// MARK: - Как считаем охват предупреждений

/// Расшифровка карточки «Предупреждения».
///
/// Цифра, которой приложение оценивает само себя, обязана объяснять свой
/// метод — иначе это не измерение, а самореклама. Здесь честно сказано и про
/// знаменатель, и про то, чего метрика НЕ умеет.
struct AlertRecallInfoSheet: View {
    let tally: AlertRecall.Tally
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    numbers
                    method
                    limits
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Предупреждения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var numbers: some View {
        VStack(spacing: 10) {
            row(String(localized: "камер проехали"), "\(tally.passed)", Theme.textPrimary)
            row(String(localized: "названо заранее"), "\(tally.warned)", Theme.success)
            row(String(localized: "названо вплотную"), "\(tally.late)", Theme.warning)
            row(String(localized: "без предупреждения"), "\(tally.silent)", Theme.danger)
            row(String(localized: "предупреждений впустую"), "\(tally.unused)", Theme.textTertiary)
        }
        .statCard()
    }

    private func row(_ title: String, _ value: String, _ tint: Color) -> some View {
        HStack {
            Text(title)
                .font(.rounded(15, .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.rounded(17, .heavy).monospacedDigit())
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private var method: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(String(localized: "Как считаем"))
            Text("«Проехали» — камера, мимо которой вы прошли вплотную: ближе 40 метров от неё. Это география, а не наше решение — поэтому цифру нельзя подкрутить, ослабив собственные фильтры.")
                .font(.rounded(15))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("«Названо заранее» — предупреждение прозвучало дальше 80 метров, то есть ещё было время отпустить газ. Если оно прозвучало ближе, мы считаем это отдельно: формально сказали, а по делу — нет.")
                .font(.rounded(15))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("«Впустую» — сказали о камере, мимо которой вы так и не проехали. Само по себе это не ошибка: вы могли свернуть. Но если таких много, значит приложение пугает зря.")
                .font(.rounded(15))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .statCard()
    }

    private var limits: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(String(localized: "Чего эта цифра не знает"))
            Text("Почему именно приложение промолчало, счётчик не разбирает: причину пришлось бы спрашивать у самой ответственной части кода, и ради счётчика её переписывать нельзя. «Свои» камеры, о которых мы молчим намеренно, тоже попадают в молчание — вы разрешили эту тишину сами.")
                .font(.rounded(15))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Наружу уходят только эти суммы. Ни координат камер, ни времени проездов в отчёт не попадает.")
                .font(.rounded(11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .statCard()
    }
}
