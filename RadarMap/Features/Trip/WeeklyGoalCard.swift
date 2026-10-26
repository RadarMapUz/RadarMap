//
//  WeeklyGoalCard.swift
//  RadarMap
//
//  «Цель недели: без превышений у камер» (31E, п. 5). Всё посчитано в
//  WeeklyGoal (по дневным итогам, вне main вместе с экраном) — карточка
//  только рисует: состояние недели, семь дней точками и серию недель.
//

import SwiftUI

struct WeeklyGoalCard: View {
    let goal: WeeklyGoal

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(symbol: "target", tint: tint, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Цель недели — без превышений у камер")
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(stateText)
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                ForEach(Array(goal.marks.enumerated()), id: \.offset) { index, mark in
                    VStack(spacing: 4) {
                        Circle()
                            .fill(fill(mark))
                            .overlay(Circle().stroke(Theme.stroke, lineWidth: mark == .future ? 1 : 0))
                            .frame(width: 14, height: 14)
                        Text(Self.weekdays[index % Self.weekdays.count])
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
            if goal.streak > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(Theme.Icon.streak)
                    Text(String(localized: "Серия: \(goal.streak) недель подряд"))
                        .foregroundStyle(Theme.textSecondary)
                }
                .font(.rounded(13, .semibold))
            }
        }
        .statCard()
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch goal.state {
        case .waiting:  return Theme.accent
        case .onTrack:  return Theme.success
        case .missed:   return Theme.danger
        }
    }

    private var stateText: String {
        switch goal.state {
        case .waiting:
            return String(localized: "На этой неделе у камер ещё не проезжали")
        case .onTrack(let passes):
            return String(localized: "Пока ни одного: \(passes) проездов камер в лимите")
        case .missed(let over):
            return String(format: String(localized: "Сорвана — превышений: %lld. Новая попытка со следующей недели"),
                          over)
        }
    }

    private func fill(_ mark: WeeklyGoal.Mark) -> Color {
        switch mark {
        case .clean:  return Theme.success
        case .over:   return Theme.danger
        case .none:   return Theme.textTertiary.opacity(0.35)
        case .future: return .clear
        }
    }

    /// Буквы дней — по календарю пользователя (первый день недели) и языку
    /// приложения, а не системы.
    static var weekdays: [String] {
        var calendar = Calendar.current
        calendar.locale = NumberFormat.locale
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }
}
