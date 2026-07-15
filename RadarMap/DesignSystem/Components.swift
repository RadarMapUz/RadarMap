//
//  Components.swift
//  RadarMap
//
//  Переиспользуемые элементы тёмного интерфейса.
//

import SwiftUI

/// Тёмная «стеклянная» карточка — базовый контейнер интерфейса.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.cornerLarge
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

/// Круглая кнопка-контрол поверх карты (мой геопоиск, слои и т.п.).
struct CircleControl: View {
    let systemName: String
    var tint: Color = Theme.textPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.rounded(17, .semibold))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
        }
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }
}

/// Основная акцентная кнопка (CTA).
struct PrimaryButton: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.rounded(17, .semibold))
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(tint, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        }
    }
}

/// Чип-легенда типа камеры.
struct LegendChip: View {
    let color: Color
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.rounded(10, .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(color, in: Circle())
            Text(text)
                .font(.rounded(12, .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Каскадное появление секций экрана: прозрачность + сдвиг, задержка по индексу.
/// Одноразовая анимация — после появления GPU не нагружает.
struct EntranceModifier: ViewModifier {
    let index: Int
    let appeared: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(.spring(duration: 0.5, bounce: 0.18).delay(Double(index) * 0.07),
                       value: appeared)
    }
}

extension View {
    func entrance(_ index: Int, _ appeared: Bool) -> some View {
        modifier(EntranceModifier(index: index, appeared: appeared))
    }
}

/// Кольцо рейтинга вождения 0–100: цвет по зоне, заполняется один раз при появлении.
struct RatingRing: View {
    let rating: Int
    var compact: Bool = false
    @State private var shown = false

    private var color: Color {
        switch DrivingScore.tier(for: rating) {
        case 2: return Theme.success
        case 1: return Theme.radar
        default: return Theme.danger
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.stroke.opacity(0.7), lineWidth: compact ? 5 : 7)
            Circle()
                .trim(from: 0, to: shown ? Double(rating) / 100 : 0)
                .stroke(color.gradient,
                        style: StrokeStyle(lineWidth: compact ? 5 : 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.5), radius: compact ? 3 : 5)
            VStack(spacing: 0) {
                Text("\(rating)")
                    .font(.rounded(compact ? 20 : 30, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                if !compact {
                    Text("рейтинг")
                        .font(.rounded(10, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.9, bounce: 0.15).delay(0.25)) { shown = true }
        }
    }
}
