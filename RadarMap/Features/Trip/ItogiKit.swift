//
//  ItogiKit.swift
//  RadarMap
//
//  Мелкие общие детали «Итогов» (аудит 05.11, вариант A): облик трёх
//  состояний проезда, точка легенды, полоса из трёх фактов и столбики дней.
//  Раньше легенду рисовали три файла по-своему (10, 11 pt, свой кружок), а
//  «чисто / с превышением» знали только два состояния из трёх.
//

import SwiftUI

// MARK: - Облик состояния проезда

extension PassVerdict {
    /// Цвет — через `Theme.role`: одно правило с HUD и CarPlay.
    var level: Theme.Level {
        switch self {
        case .clean:   return .normal
        case .edge:    return .attention
        case .over:    return .alarm
        case .unknown: return .neutral
        }
    }

    var tint: Color { self == .unknown ? Theme.textTertiary : Theme.role(level) }

    /// Глиф — второй носитель состояния (Theme.symbol): круг — «на грани»,
    /// треугольник — штраф, у нормы — галочка в строках, где её ждут.
    var symbol: String {
        switch self {
        case .clean:   return "checkmark.circle.fill"
        case .edge:    return Theme.symbol(.attention) ?? "exclamationmark.circle.fill"
        case .over:    return Theme.symbol(.alarm) ?? "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Слово для легенд и чипов.
    var word: String {
        switch self {
        case .clean:   return String(localized: "в лимите")
        case .edge:    return String(localized: "на грани")
        case .over:    return String(localized: "превышение")
        case .unknown: return String(localized: "лимит неизвестен")
        }
    }
}

// MARK: - Легенда

/// Точка легенды — одна на все графики и карты раздела.
struct ItogiLegendDot: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
                .font(.rounded(12))
                .foregroundStyle(Theme.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Легенда трёх состояний: только те, что есть на картинке.
struct ItogiVerdictLegend: View {
    var states: [PassVerdict] = [.clean, .edge, .over]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(states, id: \.self) { state in
                ItogiLegendDot(color: state.tint, title: state.word)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Три факта

/// Полоса «142 км · 9 поездок · 3 ч 40 за рулём» под рейтингом: факты
/// периода одним рядом и одним кеглем — ни один не спорит с рейтингом.
struct ItogiFactStrip: View {
    struct Fact: Identifiable {
        let id: String
        let value: String
        let caption: String
        var note: String? = nil
        var noteTint: Color = Theme.textSecondary
    }

    let facts: [Fact]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                if index > 0 {
                    Rectangle().fill(Theme.stroke).frame(width: 1).padding(.vertical, 2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.value)
                        .font(.numeral(19, .heavy).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(fact.caption)
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = fact.note {
                        Text(note)
                            .font(.rounded(12, .semibold))
                            .foregroundStyle(fact.noteTint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, index == 0 ? 0 : 10)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
