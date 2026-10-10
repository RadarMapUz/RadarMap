//
//  CursorStylePicker.swift
//  RadarMap
//
//  Выбор значка «я»: ряд плиток, на каждой — живой курсор на кусочке дороги.
//
//  Плитка показывает тот же MeCursor, что поедет по карте, а не картинку
//  «примерно такого вида»: выбирают глазами, и обещание на плитке обязано
//  совпадать с тем, что будет на дороге. Выбранный значок чуть «трогается с
//  места» — подаётся вперёд и подрастает: это ответ на касание, а не
//  украшение, и при «Уменьшении движения» он применяется без анимации
//  (withMotion/motionAnimation).
//

import SwiftUI

struct CursorStylePicker: View {
    @Binding var selection: CursorStyle

    var body: some View {
        HStack(spacing: 10) {
            ForEach(CursorStyle.allCases) { style in
                CursorStyleTile(style: style, isSelected: style == selection) {
                    withMotion(.spring(response: 0.35, dampingFraction: 0.6)) {
                        selection = style
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Одна плитка: дорога, курсор на ней, подпись. Вся плитка — кнопка: мишень
/// заведомо больше 44 pt по обеим сторонам.
private struct CursorStyleTile: View {
    let style: CursorStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                        .fill(Theme.background)
                    road
                    MeCursor(style: style)
                        .frame(width: 30, height: 36)
                        // Выбранный подаётся вперёд и чуть крупнее — «поехали».
                        .scaleEffect(isSelected ? 1.12 : 1)
                        .offset(y: isSelected ? -4 : 0)
                        .motionAnimation(.spring(response: 0.35, dampingFraction: 0.6),
                                         value: isSelected)
                }
                .frame(height: 72)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : Theme.stroke,
                                      lineWidth: isSelected ? 2 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.roundedFree(15, .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Theme.onAccentFill, Theme.accentFill)
                            .padding(4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(style.title)
                    .font(.rounded(12, isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(style.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Кусочек дороги под курсором: полотно и пунктир осевой. Без него значок
    /// висит в пустоте, и масштаб машины не с чем сравнить.
    private var road: some View {
        ZStack {
            Rectangle()
                .fill(Theme.textTertiary.opacity(0.16))
                .frame(width: 34)
            CentreLine()
                .stroke(Theme.textTertiary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
        }
        .accessibilityHidden(true)
    }

    private struct CentreLine: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            return path
        }
    }
}
