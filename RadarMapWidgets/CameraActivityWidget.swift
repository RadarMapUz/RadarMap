//
//  CameraActivityWidget.swift
//  RadarMapWidgets
//
//  Live Activity: ближайшая камера на локскрине и в Dynamic Island,
//  пока приложение свёрнуто. Палитра А в её ночном варианте — как окно
//  тревоги в самом приложении (до 19.10 здесь жил неоновый циан).
//

import WidgetKit
import SwiftUI
import ActivityKit

/// Плашка всегда тёмная (и Dynamic Island чёрный), поэтому цвета — ночные
/// значения палитры А; числа сверяет WidgetPaletteTests.
private enum WTheme {
    static let accent = SW.fixed(WidgetPalette.accent.dark)
    /// Текст «камера» и полоса приближения.
    static let camera = SW.fixed(WidgetPalette.danger.dark)
    /// Диск под белым значком: камера / «камер рядом нет».
    static let cameraFill = SW.fixed(WidgetPalette.dangerFill.dark)
    static let clearFill = SW.fixed(WidgetPalette.successFill.dark)
    static let clear = SW.fixed(WidgetPalette.success.dark)
    static let background = SW.fixed(WidgetPalette.alertSurface)
    static let primary = SW.fixed(WidgetPalette.primary.dark)
    static let secondary = SW.fixed(WidgetPalette.secondary.dark)
}

/// Единицы — через каталог: плашка живёт на экране блокировки в том же
/// языке, что и приложение, и «м»/«км» строкой в коде на узбекском остались
/// бы русскими.
private func format(_ meters: Double) -> String {
    guard meters >= 1000 else {
        return String(format: String(localized: "%lld м"), Int(meters.rounded()))
    }
    // Число — общим правилом (Shared/NumberFormat): `String(format:)` без
    // локали давал «1.4 км» с точкой и в русском.
    return String(format: String(localized: "%@ км"), NumberFormat.decimal(meters / 1000))
}

struct CameraActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CameraActivityAttributes.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(WTheme.background.opacity(0.92))
                .activitySystemActionForegroundColor(WTheme.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    typeIcon(context.state)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let distance = context.state.distanceMeters {
                        Text(format(distance))
                            .font(.system(.title3, design: .rounded).bold())
                            .foregroundStyle(WTheme.accent)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ApproachBar(state: context.state)
                    // `?? "…"` дал бы String — мимо каталога, на узбекском
                    // осталось бы по-русски.
                    Group {
                        if let title = context.state.nearestTitle { Text(title) } else { Text("Камер рядом нет") }
                    }
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(WTheme.secondary)
                        .lineLimit(2)
                }
            } compactLeading: {
                typeIcon(context.state)
            } compactTrailing: {
                if let distance = context.state.distanceMeters {
                    Text(format(distance))
                        .font(.system(.caption2, design: .rounded).bold())
                        .foregroundStyle(WTheme.accent)
                }
            } minimal: {
                typeIcon(context.state)
            }
            .keylineTint(WTheme.accent)
        }
    }

    @ViewBuilder
    private func typeIcon(_ state: CameraActivityAttributes.ContentState) -> some View {
        Image(systemName: state.nearestTitle == nil ? "checkmark.shield.fill" : state.nearestSymbol)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(state.nearestTitle == nil ? WTheme.clear : WTheme.camera)
    }
}

/// Полоса приближения к камере. Её двигает система по времени прибытия
/// (`arrivesAt`) — плашку не будят на каждые 25 м ради живой картинки.
private struct ApproachBar: View {
    let state: CameraActivityAttributes.ContentState

    var body: some View {
        if state.nearestTitle != nil, let since = state.since, let arrives = state.arrivesAt, arrives > since {
            ProgressView(timerInterval: since...arrives, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .progressViewStyle(.linear)
                .tint(WTheme.camera)
        }
    }
}

private struct LockScreenView: View {
    let state: CameraActivityAttributes.ContentState
    /// Обновлений давно не было (staleDate): GPS замолчал или приложение
    /// выгружено — «300 м» больше не правда, и сказать это честнее, чем молча
    /// держать цифру.
    var isStale = false

    var body: some View {
        HStack(spacing: 14) {
            // Без сигнала — не красная камера: цифры под ней уже неправда,
            // и значок говорит о GPS, а не о камере впереди.
            Image(systemName: isStale ? "location.slash.fill"
                  : state.nearestTitle == nil ? "checkmark.shield.fill" : state.nearestSymbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(isStale ? WTheme.primary.opacity(0.16)
                            : state.nearestTitle == nil ? WTheme.clearFill : WTheme.cameraFill,
                            in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                if isStale {
                    Text("Нет сигнала GPS")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(WTheme.primary)
                    Text("Откройте RadarMap, если поездка идёт")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(WTheme.secondary)
                } else if let title = state.nearestTitle, let distance = state.distanceMeters {
                    Text(format(distance))
                        .font(.system(.title3, design: .rounded).bold())
                        .foregroundStyle(WTheme.accent)
                    Text(title)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(WTheme.secondary)
                        .lineLimit(1)
                    ApproachBar(state: state)
                } else {
                    Text("Камер рядом нет")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(WTheme.primary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}
