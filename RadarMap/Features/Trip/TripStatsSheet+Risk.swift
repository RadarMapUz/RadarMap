//
//  TripStatsSheet+Risk.swift
//  RadarMap
//
//  Итоги: возможные штрафы и напоминание про ожидающие.
//

import SwiftUI
import Charts
import MapKit
import CoreLocation

extension TripStatsSheet {

    // MARK: - Топливо за период (12б.3)

    /// Сколько стоила дорога за период — рядом с деньгами штрафов. Только
    /// когда расход и цена заданы; период, начавшийся до последней правки
    /// цены, посчитан по нынешней — подпись говорит об этом.
    @ViewBuilder
    func fuelRow(summary: PeriodSummary) -> some View {
        if summary.distance > 0, let cost = env.settings.fuelCost(meters: summary.distance) {
            let start = period.interval(containing: anchor).start
            let current = FuelCost.isAtCurrentPrice(endedAt: start, profile: env.settings.fuelProfile)
            HStack(spacing: 12) {
                IconBadge(symbol: "fuelpump.fill", tint: Theme.Icon.money, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: String(localized: "Топливо ~%@"), Formatting.money(cost)))
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(current
                         ? String(format: String(localized: "%@ · по нынешней цене"), Formatting.distance(summary.distance))
                         : Formatting.distance(summary.distance))
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .statCard(padding: 14, radius: Theme.cornerMedium)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Зона риска (тап — карта с фокусом на камере)

    /// Второй блок сверху: главный вопрос после «как я езжу» — «сколько это
    /// стоит и где». Сумма всегда в одну строку (раньше «риск ≈ 4,4 млн сум»
    /// ломался на две), (i) о ступенях штрафа — отдельной кнопкой в углу, чтобы
    /// основной тап остался за картой.
    @ViewBuilder
    func riskCard(summary: PeriodSummary) -> some View {
        // Карточка — только когда есть о чём судить: хоть один проезд с
        // известным лимитом. Все без лимита — об этом скажет вывод героя.
        if summary.cleanPasses + summary.overPasses > 0 {
            let ok = summary.overPasses == 0
            ZStack(alignment: .topTrailing) {
                Button {
                    if ok {
                        showFinesInfo = true
                    } else {
                        // Список проездов с суммами и пометкой «не пришёл»;
                        // карта каждого проезда — внутри, тапом по строке.
                        showFines = true
                    }
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        // Красный — у значка, сумма — обычным текстом. Красные
                        // «1,3 млн сум» кеглем 28 были самым громким на экране,
                        // громче рейтинга, и Итоги читались как авария даже у
                        // аккуратного водителя. Риск по-прежнему виден сразу:
                        // значок состояния и число превышений.
                        Image(systemName: ok ? "checkmark.shield.fill"
                                             : "exclamationmark.triangle.fill")
                            .font(.rounded(18, .bold))
                            .foregroundStyle(ok ? Theme.success : Theme.danger)
                            .frame(width: 40, height: 40)
                            .background((ok ? Theme.success : Theme.danger).opacity(0.12),
                                        in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ok ? String(localized: "Зона риска")
                                    : String(localized: "Возможные штрафы"))
                                .font(.rounded(13, .medium))
                                .foregroundStyle(Theme.textSecondary)
                            Text(ok ? String(localized: "0 штрафов")
                                    : Formatting.money(summary.fineRisk))
                                .font(.rounded(26, .heavy))
                                .foregroundStyle(ok ? Theme.success : Theme.textPrimary)
                                .contentTransition(.numericText())
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)
                            Text(passesLine(summary, ok: ok))
                                .font(.rounded(13))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !ok {
                                // Что за проезды и «не пришёл» — на своём экране.
                                // Ссылка — цветом ссылки, как везде в приложении.
                                HStack(spacing: 4) {
                                    Text("Разобрать проезды")
                                    Image(systemName: "chevron.right")
                                        .font(.rounded(11, .bold))
                                }
                                .font(.rounded(14, .semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.top, 2)
                            }
                        }
                        Spacer(minLength: 0)
                        if ok {
                            Image(systemName: "chevron.right")
                                .font(.rounded(15, .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .statCard()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Вложенные кнопки в SwiftUI ненадёжны — (i) висит рядом с
                // основной кнопкой, а не внутри её label.
                if !ok {
                    Button {
                        showFinesInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.rounded(15))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Как считаются штрафы"))
                }
            }
        }
    }

    /// «Ждут ответа: N» — зависшие денежные ожидания старше месяца, по всей
    /// истории, а не окну периода: зависший штраф остаётся зависшим, в каком
    /// периоде на него ни смотри. Тап открывает штрафы того периода, где лежит
    /// самый старый, — иначе кнопка вела бы в окно, где их не видно.
    @ViewBuilder func pendingNudgeRow(_ screen: ItogiScreen) -> some View {
        if screen.pendingCount > 0, let oldest = screen.pendingOldest {
            let nudge = (count: screen.pendingCount, oldest: oldest)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withMotion(Motion.standard) {
                    period = .month
                    anchor = nudge.oldest
                }
                showFines = true
            } label: {
                HStack(spacing: 12) {
                    IconBadge(symbol: "envelope.open.badge.clock", tint: Theme.warning, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: String(localized: "Ждут ответа: %lld"),
                                    nudge.count))
                            .font(.rounded(14, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Отметьте: штраф пришёл или нет")
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.rounded(15, .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .statCard(padding: 12, radius: Theme.cornerMedium)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// «Проездов камер: 6 · с превышением: 2» — два счётчика с подписью (6.2).
    /// Проезды — ВСЕ, то же число, что в «Деталях»: раньше здесь считались
    /// только проезды с известным лимитом, и под одним словом на экране стояли
    /// два разных числа. «Штрафуемых превышений нет», а не «все в лимите»: у части
    /// камер лимит может быть неизвестен, а балл снимает и ниже ступени
    /// штрафа. Форма после двоеточия от числа не зависит.
    func passesLine(_ summary: PeriodSummary, ok: Bool) -> String {
        if ok {
            return String(format: String(localized: "Проездов камер: %lld — штрафуемых превышений нет"),
                          summary.cameras)
        }
        return String(format: String(localized: "Проездов камер: %1$lld · с превышением: %2$lld"),
                      summary.cameras, summary.overPasses)
    }
}
