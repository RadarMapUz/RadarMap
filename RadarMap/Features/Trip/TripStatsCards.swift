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
                    Circle().fill(Theme.accent)
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

            // Две строки всегда: «Лимитда 50 камера» переносилось, соседи нет,
            // и нижняя граница ряда получалась рваной.
            Text(badge.title)
                .font(.rounded(10, .medium))
                .foregroundStyle(badge.earned ? Theme.textPrimary : Theme.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(height: 26, alignment: .top)
        }
        .frame(width: 82)
    }
}

// MARK: - Полоса KPI

/// Четыре цифры одной строкой вместо сетки 2×2 из разноцветных плиток.
/// Сетка занимала полэкрана и красила каждую цифру в свой цвет — цвет
/// переставал что-либо значить. Здесь цветом отмечено только состояние
/// (зона риска, рейтинг), а справочные числа спокойные.
struct KPIStrip: View {
    let summary: PeriodSummary
    /// «5 из 7» — считает экран: строке нужны период и якорь, а карточке нет.
    let activeDaysText: String

    var body: some View {
        HStack(spacing: 0) {
            // Именно ПРОЕЗДЫ: одна камера, пройденная дважды, — это два.
            // Легенда карты считает уникальные точки — слово должно отличаться.
            StatStripCell(value: "\(summary.cameras)", label: LocalizedStringKey(Formatting.passesLabel(summary.cameras)),
                          icon: "camera.fill", tint: Theme.Icon.camera)
            StatStripDivider()
            StatStripCell(value: activeDaysText, label: "дней за рулём", icon: "calendar",
                          tint: Theme.Icon.time)
            StatStripDivider()
            StatStripCell(value: "\(Int(summary.averageSpeedKmh))", label: "средняя, км/ч",
                          icon: "gauge.with.dots.needle.33percent", tint: Theme.Icon.speed)
            StatStripDivider()
            StatStripCell(value: "\(Int(summary.maxSpeedKmh))", label: "максимум, км/ч",
                          icon: "gauge.with.dots.needle.100percent", tint: Theme.Icon.speed)
        }
        .statCard(padding: 14)
    }

}

/// Ячейка полосы статистики: иконка, крупная цифра, подпись. Общая для
/// KPI периода и пожизненной полосы — цифры на них обязаны выглядеть одинаково.
struct StatStripCell: View {
    let value: String
    let label: LocalizedStringKey
    let icon: String
    /// Цвет знака — по смыслу (Theme.Icon); сама цифра остаётся спокойной:
    /// цветом в Итогах говорит только состояние, а знак лишь помогает найти.
    var tint: Color = Theme.accent

    var body: some View {
        VStack(spacing: 5) {
            IconBadge(symbol: icon, tint: tint, size: 26)
            // Число — главное: не переносится и сжимается не ниже 0.8. Ниже
            // оно перестаёт читаться с расстояния вытянутой руки, а ради этого
            // плитку и смотрят. Не влезает — режем подпись, а не число.
            Text(value)
                .font(.numeral(21, .heavy).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            // Высота подписи фиксирована под две строки: иначе «лучшая серия»
            // переносится, «поездок» нет, и нижняя граница ряда получается
            // рваной — именно это и было видно на узбекском.
            Text(label)
                .font(.rounded(10, .medium))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(height: 26, alignment: .top)
        }
        // Воздух по бокам входит в идеальную ширину ячейки: без него
        // ViewThatFits считал, что четыре колонки «влезают», и подписи
        // «limitdagi kamera» и «eng yaxshi seriya» стояли вплотную.
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(value), ") + Text(label))
    }
}

struct StatStripDivider: View {
    var body: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 42)
    }
}

// MARK: - Когда рискуете

/// Превышения по времени суток. «Где» уже отвечает карта, а «когда» до этого
/// не отвечал никто — хотя вечерний час пик и пустая ночная дорога дают
/// совершенно разные привычки.
struct RiskHoursCard: View {
    let summary: PeriodSummary

    var body: some View {
        if summary.overPasses >= AppConfig.insightMinOverForHours,
           let peak = summary.peakBlock {
            let blocks = summary.overByBlock
            let top = max(blocks.max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: String(localized: "Когда рискуете")) {
                    Text(peak.title)
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.danger)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, count in
                        bar(count: count, peak: top, isPeak: index == peak.index,
                            hour: index * 4)
                    }
                }
            }
            .statCard()
        }
    }

    private func bar(count: Int, peak: Int, isPeak: Bool, hour: Int) -> some View {
        VStack(spacing: 6) {
            Text(count > 0 ? "\(count)" : " ")
                .font(.rounded(10, .bold).monospacedDigit())
                .foregroundStyle(isPeak ? Theme.danger : Theme.textTertiary)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isPeak ? Theme.danger : Theme.accent.opacity(0.35))
                // Пустой блок оставляет тонкую риску: полоса читается как шкала
                // суток, а не как случайный набор столбиков.
                .frame(height: max(3, 52 * Double(count) / Double(peak)))
            Text(String(format: "%02d", hour))
                .font(.rounded(10, .medium).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(format: String(localized: "С %1$02d до %2$02d часов: превышений %3$lld"),
                                        hour, (hour + 4) % 24, count)))
    }
}

// MARK: - Охват предупреждений

/// «О скольких камерах приложение успело сказать» — единственная цифра, по
/// которой вопрос «умно ли работает алгоритм» решается не спором.
///
/// Показывается человеку намеренно, а не прячется в телеметрию. Антирадар —
/// это обещание, и обещание положено проверять: если охват просел, владелец
/// телефона узнаёт об этом тогда же, когда и мы, а не из отзыва в App Store.
/// Тон при этом ровный — карточка сообщает результат, а не хвалит себя.
struct AlertRecallCard: View {
    let tally: AlertRecall.Tally
    var onExplain: () -> Void = {}

    var body: some View {
        // Знаменатель — камеры НАШЕЙ дороги: верная тишина о камере встречной
        // стороны или поперечной улицы (гейт доказал) промахом не считается.
        if let recall = tally.recall, tally.ours >= AppConfig.recallMinPassesToShow {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: String(localized: "Предупреждения")) {
                    Button(action: onExplain) {
                        // Голый значок — ~18 pt мишени; растим область касания,
                        // не глиф.
                        Image(systemName: "info.circle")
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .tapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Как считаем охват"))
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int((recall * 100).rounded()))%")
                        .font(.numeral(34, .heavy).monospacedDigit())
                        .foregroundStyle(recall >= AppConfig.recallGoodShare
                                         ? Theme.success : Theme.warning)
                    Text(String(format: String(localized: "камер названо заранее — %1$lld из %2$lld"),
                                tally.warned, tally.ours))
                        .font(.rounded(15))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                bar(recall: recall)
                // Осечки перечисляем поимённо и без смягчений: строка «о двух
                // промолчал» — это и есть то, ради чего карточка существует.
                // Ноль осечек не печатаем вовсе — хвастаться нечем.
                if tally.late > 0 {
                    footnote(String(format: String(localized:
                        "о %lld сказал уже вплотную — среагировать было негде"), tally.late),
                        tint: Theme.warning)
                }
                if tally.silent > 0 {
                    footnote(String(format: String(localized: "о %lld промолчал"), tally.silent),
                             tint: Theme.danger)
                }
                if tally.unused > 0 {
                    // Интерполяция, не String(format:): только так каталог
                    // выбирает форму числа («1 предупреждение», 6.11).
                    footnote(String(localized:
                        "\(tally.unused) предупреждений — о камерах, мимо которых вы не проехали"),
                             tint: Theme.textTertiary)
                }
            }
            .statCard()
        }
    }

    /// Полоса: названо заранее / вплотную / молчание. Доли те же, что в цифрах
    /// выше, — второй источник правды тут завёлся бы мгновенно.
    private func bar(recall: Double) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let total = Double(max(tally.ours, 1))
            HStack(spacing: 2) {
                segment(Theme.success, width * Double(tally.warned) / total)
                segment(Theme.warning, width * Double(tally.late) / total)
                segment(Theme.danger, width * Double(tally.silent) / total)
            }
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(format: String(localized:
            "Названо заранее %1$lld, вплотную %2$lld, без предупреждения %3$lld"),
            tally.warned, tally.late, tally.silent)))
    }

    @ViewBuilder private func segment(_ color: Color, _ width: Double) -> some View {
        if width > 0 {
            Capsule().fill(color).frame(width: max(2, width))
        }
    }

    private func footnote(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.rounded(11, .medium))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
