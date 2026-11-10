//
//  TrafficLegendViews.swift
//  RadarMap
//
//  Понятность пробок (33H): лист по касанию линии,
//  чип балла города в колонке и лист «Пробки» по касанию чипа. Цвета — из
//  TrafficPalette (те же числа, что у стиля движка), образец линии рисуется
//  так же, как на карте: кайма, тело и наконечник по ходу.
//

import SwiftUI

// MARK: - Образец линии

/// Короткая линия уровня, как на карте: тёмная кайма, тело, наконечник.
struct TrafficSwatch: View {
    var level: Int
    var usual = false
    var arrow = false
    var width: CGFloat = 26
    var thickness: CGFloat = 5

    var body: some View {
        let pair = usual ? TrafficPalette.usual(TrafficPalette.level(level)) : TrafficPalette.level(level)
        let colour = Theme.adaptive(pair.day, pair.night)
        let line = usual ? thickness * CGFloat(TrafficPalette.usualWidthShare) : thickness
        ZStack {
            Capsule()
                .fill(Theme.adaptive(TrafficPalette.casing.day, TrafficPalette.casing.night).opacity(0.35))
                .frame(width: width + 1.2, height: line + 1.2)
            Capsule()
                .fill(colour)
                .frame(width: width, height: line)
            if arrow {
                TrafficArrowShape()
                    .fill(Theme.adaptive(TrafficPalette.arrow(on: pair.day, daylight: true).fill,
                                         TrafficPalette.arrow(on: pair.night, daylight: false).fill))
                    .overlay(TrafficArrowShape().stroke(Theme.adaptive(TrafficPalette.casing.day,
                                                                       TrafficPalette.casing.night),
                                                        lineWidth: 0.8))
                    .frame(width: line * CGFloat(EngineMapStyle.trafficArrowScale),
                           height: line * CGFloat(EngineMapStyle.trafficArrowScale))
            }
        }
        .frame(width: width + 2, height: max(line * CGFloat(EngineMapStyle.trafficArrowScale), line + 2))
        .accessibilityHidden(true)
    }
}

/// Наконечник «по ходу» — та же форма, что растр карты (trafficChevronIcon).
struct TrafficArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.1))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.9, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.9))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Легенда

/// Легенда листа «Пробки» (касание чипа балла; с 28.10 — её единственное
/// место, из панели «Карта» она ушла): четыре уровня, указатель направления
/// и «светлее — обычно в это время». Кегли — те же, что у остального листа
/// (15 подпись, 13 пояснение), а не 12 панели, под которую она рисовалась.
struct TrafficLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    item(1, Text("Свободно"))
                    item(2, Text("Медленно"))
                }
                GridRow {
                    item(3, Text("Пробка"))
                    item(4, Text("Стоят"))
                }
            }
            row(TrafficSwatch(level: 3, arrow: true), Text("Направление движения"))
            // Образец «обычно» — зелёный: с 33H2 это почти весь слой.
            row(TrafficSwatch(level: 1, usual: true), Text("Светлее и тоньше — обычно в это время"))
        }
        .accessibilityElement(children: .combine)
    }

    private func item(_ level: Int, _ title: Text) -> some View {
        HStack(spacing: 8) {
            TrafficSwatch(level: level)
            title
                .font(.rounded(15))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
    }

    private func row(_ swatch: TrafficSwatch, _ title: Text) -> some View {
        HStack(spacing: 8) {
            swatch
            title
                .font(.rounded(13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Лист по касанию линии

struct TrafficTapSheet: View {
    let tap: TrafficTap

    var body: some View {
        // Общий короткий лист над картой (MapShortSheet): заголовок по
        // центру, «Готово», высота по содержимому.
        MapShortSheet(title: "Пробки") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    TrafficSwatch(level: tap.level, usual: tap.usual, arrow: true, width: 34, thickness: 7)
                    Text(title)
                        .font(.rounded(20, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(details)
                    .font(.rounded(17))
                    .foregroundStyle(Theme.textPrimary)
                Text(tap.usual ? "По прошлым неделям и модели дороги — не данные сейчас"
                               : "По данным водителей за последние 15 минут")
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        if tap.usual {
            switch tap.level {
            case 1: return String(localized: "Обычно в это время свободно")
            case 2: return String(localized: "Обычно в это время медленно")
            default: return String(localized: "Обычно в это время пробка")
            }
        }
        switch tap.level {
        case 1: return String(localized: "Свободно")
        case 2: return String(localized: "Медленно")
        case 3: return String(localized: "Пробка")
        default: return String(localized: "Стоят")
        }
    }

    /// «2,4 км · 12 км/ч · +7 мин»; у «обычно» — «обычно 25 км/ч».
    private var details: String {
        let kmh = Int(tap.kmh.rounded())
        var parts = [Formatting.distance(tap.length),
                     tap.usual ? String(format: String(localized: "обычно %lld км/ч"), kmh)
                               : String(format: String(localized: "%lld км/ч"), kmh)]
        if let delay = tap.shownDelay { parts.append(Formatting.unbreakable("+" + Formatting.duration(delay))) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Балл города

/// Чип балла в колонке справа: число и кольцо цвета уровня; по «обычно» —
/// кольцо пунктиром (это не данные сейчас).
struct TrafficScoreChip: View {
    let score: TrafficCityScore.Score
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: "\(score.value)")
                .font(.denseNumeral(17, .bold))
                .foregroundStyle(Theme.textPrimary)
                .controlCircle()
                .overlay {
                    let pair = TrafficPalette.level(score.level)
                    Circle()
                        .inset(by: 2.5)
                        .stroke(Theme.adaptive(pair.day, pair.night),
                                style: StrokeStyle(lineWidth: 3.5, dash: score.usual ? [4, 3] : []))
                }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text(String(format: String(localized: "Балл пробок: %lld из 10"), score.value)))
    }
}

/// Лист «Пробки»: балл города и легенда.
struct TrafficLegendSheet: View {
    let score: TrafficCityScore.Score?

    var body: some View {
        MapShortSheet(title: "Пробки") {
            VStack(alignment: .leading, spacing: 16) {
                if let score {
                    HStack(spacing: 14) {
                        TrafficScoreChip(score: score) {}
                            .allowsHitTesting(false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Балл города")
                                .font(.rounded(15, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(score.usual ? "Обычно в это время" : "По данным водителей сейчас")
                                .font(.rounded(13))
                                .foregroundStyle(Theme.textSecondary)
                            Text("0 — свободно, 10 — город стоит")
                                .font(.rounded(13))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                TrafficLegend()
            }
        }
    }
}
