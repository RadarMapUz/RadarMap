//
//  WidgetStyle.swift
//  RadarMapWidgets
//
//  Общее для виджетов: цвет с учётом режима системы и кольца. В тонированном
//  и «Прозрачном» режимах и в ночном StandBy система отбрасывает цвет и
//  оставляет альфу, поэтому заливка под белым значком становится сплошным
//  пятном, а все цвета текста — одним: иерархию там несёт только альфа.
//

import SwiftUI
import WidgetKit

extension View {
    /// Цвет переднего плана: свой в полном цвете, белый с альфой `mono` в
    /// режимах системы. `accent` — эта деталь берёт цвет тонирования.
    func ink(_ full: Color, mono: Double = 1, accent: Bool = false) -> some View {
        modifier(WidgetInk(full: full, mono: mono, accent: accent))
    }

    /// Подложка детали: своя в полном цвете, еле заметная в режимах системы.
    func wash<S: Shape>(_ full: Color, in shape: S, mono: Double = 0.14) -> some View {
        modifier(WidgetWash(full: full, shape: shape, mono: mono))
    }
}

private struct WidgetInk: ViewModifier {
    @Environment(\.widgetRenderingMode) private var mode
    let full: Color
    let mono: Double
    let accent: Bool

    func body(content: Content) -> some View {
        if mode == .fullColor {
            content.foregroundStyle(full)
        } else {
            content.foregroundStyle(Color.white.opacity(mono)).widgetAccentable(accent)
        }
    }
}

private struct WidgetWash<S: Shape>: ViewModifier {
    @Environment(\.widgetRenderingMode) private var mode
    let full: Color
    let shape: S
    let mono: Double

    func body(content: Content) -> some View {
        content.background(mode == .fullColor ? full : Color.white.opacity(mono), in: shape)
    }
}

/// Одна дуга: подложка кольца и заполнение.
struct RingArc: View {
    @Environment(\.widgetRenderingMode) private var mode
    let value: Double
    let colors: [Color]
    let width: CGFloat
    var inset: CGFloat = 0
    var accent = false

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: width)
            if value > 0 {
                Circle()
                    .trim(from: 0, to: min(1, value))
                    .stroke(fill, style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable(accent)
            }
        }
        .padding(width / 2 + inset)
    }

    private var track: Color {
        mode == .fullColor ? (colors.last ?? SW.accent).opacity(0.2) : Color.white.opacity(0.22)
    }

    private var fill: AnyShapeStyle {
        mode == .fullColor
            ? AnyShapeStyle(AngularGradient(colors: colors + [colors.first ?? SW.accent], center: .center))
            : AnyShapeStyle(Color.white)
    }
}

/// Как в календаре «Итогов»: внешнее кольцо — аккуратность, внутреннее — пробег.
/// `road` nil — внутреннего кольца нет: сравнивать ещё не с чем.
struct WidgetRings: View {
    let score: Int?
    let road: Double?
    let side: CGFloat

    var body: some View {
        let width = side * 0.135
        ZStack {
            RingArc(value: Double(score ?? 0) / 100, colors: SW.Ring.tier(score), width: width, accent: true)
            if let road {
                RingArc(value: road, colors: SW.Ring.road, width: width, inset: width * 1.3)
            }
        }
        .frame(width: side, height: side)
    }
}

/// Кольца одного дня; точка — день со штрафом или без единого замечания.
struct WidgetDayRing: View {
    let ring: WidgetWeek.DayRing?
    let side: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WidgetRings(score: ring?.score, road: ring?.road ?? 0, side: side)
                .opacity(ring == nil ? 0.35 : 1)
            if let ring, ring.fine || ring.perfect {
                Circle()
                    .ink(ring.fine ? SW.camera : SW.action, accent: ring.fine)
                    .frame(width: side * 0.24, height: side * 0.24)
                    .offset(x: side * 0.06, y: -side * 0.06)
            }
        }
        .frame(width: side, height: side)
    }
}

/// Жёлтая стрелка: виджет действует, а не только показывает. В режимах
/// системы — символ с прорезью, а не залитый круг.
struct WidgetGo: View {
    @Environment(\.widgetRenderingMode) private var mode
    var size: CGFloat = 26

    var body: some View {
        if mode == .fullColor {
            Image(systemName: "arrow.up.right")
                .font(.system(size: size * 0.46, weight: .heavy))
                .foregroundStyle(SW.onAction)
                .frame(width: size, height: size)
                .background(SW.action, in: Circle())
        } else {
            Image(systemName: "arrow.up.right.circle.fill")
                .font(.system(size: size * 0.92, weight: .regular))
                .foregroundStyle(Color.white)
                .widgetAccentable()
                .frame(width: size, height: size)
        }
    }
}
