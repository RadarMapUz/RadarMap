//
//  Components.swift
//  RadarMap
//
//  Переиспользуемые элементы тёмного интерфейса.
//

import SwiftUI
import UIKit

/// «Стеклянная» карточка — базовый контейнер интерфейса (нативный Liquid Glass).
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.cornerLarge
    @ViewBuilder var content: Content

    var body: some View {
        content
            .backport.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            // Световая кромка сверху — единый премиальный язык стекла в приложении.
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }
}

/// Единый контейнер карточки статистики: одинаковые отступы, радиус и фон.
/// Раньше каждый блок Итогов задавал их сам и они расходились на пару пунктов.
extension View {
    func statCard(padding: CGFloat = 16, radius: CGFloat = Theme.cornerLarge) -> some View {
        self.padding(padding)
            .background(Theme.surface,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Заголовок секции: подпись слева, необязательный акцент справа. Один размер и
/// цвет на все секции — «Километры по дням», «Достижения», список поездок.
struct SectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// Разделитель «дальше — пожизненные цифры»: подпись в разрыве линии. Нужен,
/// чтобы было видно, где кончается власть фильтра периода.
struct LabeledDivider: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            line
            Text(title)
                .font(.rounded(11, .semibold))
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
            line
        }
        .padding(.top, 8)
    }

    private var line: some View {
        Rectangle().fill(Theme.stroke).frame(height: 1)
    }
}

/// Круглая кнопка-контрол поверх карты (мой геопоиск, слои и т.п.).
struct CircleControl: View {
    let systemName: String
    var tint: Color = Theme.textPrimary
    var size: CGFloat = 46
    /// Что читает VoiceOver (иконка без текста сама по себе нема).
    var accessibilityLabel: LocalizedStringKey = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.rounded(size > 48 ? 19 : 17, .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .backport.glassEffect(.interactive(isEnabled: true), in: .circle)
                // Тонкая световая кромка сверху — стекло ловит свет, как у системных кнопок.
                .overlay(Circle().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)],
                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .accessibilityLabel(Text(accessibilityLabel))
        }
        .buttonStyle(PressableStyle())
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }
}

/// Премиальный отклик: кнопка мягко пружинит под пальцем.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
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

/// Красное свечение по краям экрана: превышение у камеры. Видно периферийным
/// зрением — на телефон смотреть не нужно. Один слой с пульсом, тапы пропускает.
struct OverspeedVignette: View {
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 44, style: .continuous)
            .strokeBorder(Theme.danger.opacity(pulse ? 0.55 : 0.25), lineWidth: 22)
            .blur(radius: 24)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .transition(.opacity)
            .accessibilityHidden(true)   // VoiceOver уже читает алерт приближения
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
    /// false — кольцо сразу заполнено (для ImageRenderer: onAppear там не приходит).
    var animated: Bool = true
    @State private var shown = false

    init(rating: Int, compact: Bool = false, animated: Bool = true) {
        self.rating = rating
        self.compact = compact
        self.animated = animated
        _shown = State(initialValue: !animated)
    }

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
            guard animated else { return }
            withAnimation(.spring(duration: 0.9, bounce: 0.15).delay(0.25)) { shown = true }
        }
    }
}

// MARK: - Шэр картинки

/// ShareLink внутри вложенного sheet (Итоги → деталка) на iOS молча не
/// презентуется — шэрим через UIActivityViewController, он работает всегда.
struct ShareImagePayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [image],
                                                  applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in dismiss() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
