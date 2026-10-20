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
import AppIntents

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
    /// Подпись призрака: позже срока, впритык, заметно дольше обычного.
    static let warning = SW.fixed(WidgetPalette.warning.dark)
    /// «Радар!» — жёлтое главное действие, как на карте.
    static let action = SW.fixed(WidgetPalette.action)
    static let onAction = SW.fixed(WidgetPalette.onAction)

    /// Цвет дистанции и полосы по уровню тревоги (9.1): ближе — горячее.
    /// Цвет не единственный носитель: уровень 3 — это и дистанция, и полоса
    /// почти до конца.
    static func level(_ level: Int?) -> Color {
        switch level ?? 0 {
        case 3...: return camera
        case 2: return warning
        default: return accent
        }
    }
}

/// Знак ограничения дороги (9.1): белый круг с красной каймой, как на дороге
/// и на карточке скорости в приложении.
private struct LimitSign: View {
    let limit: Int
    var size: CGFloat = 30

    var body: some View {
        Text("\(limit)")
            .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
            .foregroundStyle(.black)
            .minimumScaleFactor(0.6)
            .frame(width: size, height: size)
            .background(Circle().fill(.white))
            .overlay(Circle().stroke(Color(red: 0.86, green: 0.16, blue: 0.16), lineWidth: size * 0.12))
    }
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
                // Высота плашки — не больше 160 pt: на самом крупном шрифте
                // строка с дистанцией, прибытием и полосой выталкивала кнопки
                // за край (ревью 20.10).
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .activityBackgroundTint(WTheme.background.opacity(0.92))
                .activitySystemActionForegroundColor(WTheme.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    typeIcon(context.state, isStale: context.isStale)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // Без сигнала расстояние уже неправда — его нет вовсе,
                    // как и на локскрине (ревью 19.10: остров держал «300 м»).
                    if !context.isStale, let distance = context.state.distanceMeters {
                        Text(format(distance))
                            .font(.system(.title3, design: .rounded).bold())
                            .foregroundStyle(WTheme.level(context.state.alertLevel))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        if !context.isStale { ApproachBar(state: context.state) }
                        // `?? "…"` дал бы String — мимо каталога, на узбекском
                        // осталось бы по-русски.
                        Group {
                            if context.isStale {
                                Text("Нет сигнала GPS")
                            } else if let title = context.state.nearestTitle {
                                Text(title)
                            } else {
                                Text("Камер рядом нет")
                            }
                        }
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(WTheme.secondary)
                            .lineLimit(context.isStale ? 2 : 1)
                        if !context.isStale {
                            GhostLine(state: context.state)
                            ActivityButtons(state: context.state, height: 34)
                                .padding(.top, 2)
                        }
                    }
                    // Развёрнутый остров тоже не выше 160 pt (ревью 20.10).
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
                }
            } compactLeading: {
                typeIcon(context.state, isStale: context.isStale)
            } compactTrailing: {
                if !context.isStale, let distance = context.state.distanceMeters {
                    Text(format(distance))
                        .font(.system(.caption2, design: .rounded).bold())
                        .foregroundStyle(WTheme.level(context.state.alertLevel))
                }
            } minimal: {
                typeIcon(context.state, isStale: context.isStale)
            }
            .keylineTint(WTheme.accent)
        }
    }

    @ViewBuilder
    private func typeIcon(_ state: CameraActivityAttributes.ContentState, isStale: Bool) -> some View {
        Image(systemName: isStale ? "location.slash.fill"
              : state.nearestTitle == nil ? "checkmark.shield.fill" : state.nearestSymbol)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(isStale ? WTheme.secondary
                             : state.nearestTitle == nil ? WTheme.clear : WTheme.camera)
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
                .tint((state.alertLevel ?? 0) >= 2 ? WTheme.level(state.alertLevel) : WTheme.camera)
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
        VStack(spacing: 10) {
            row
            // Без сигнала кнопок нет: где мы — неизвестно, и «Радар!» встал
            // бы не там (а отказ «нет позиции» — лишний звук).
            if !isStale { ActivityButtons(state: state) }
        }
        .padding(14)
    }

    private var row: some View {
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
                        .foregroundStyle(WTheme.level(state.alertLevel))
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
                if !isStale { GhostLine(state: state) }
            }
            Spacer(minLength: 0)
            // Ограничение дороги (9.1) — сравнить «еду / можно» без приложения.
            if !isStale, let limit = state.limitKmh {
                LimitSign(limit: limit, size: 36)
            }
        }
    }
}

/// Кнопки плашки (9.1б): «Радар!» — широкая жёлтая, по ней бьют не глядя;
/// «Звук» — узкая, со значком нынешнего состояния. Намерения выполняет
/// приложение (Shared/ActivityIntents), ответ приходит следующим состоянием:
/// ✓ «Отмечено» или ✕ «Не отправлено» (причину говорит голос).
private struct ActivityButtons: View {
    let state: CameraActivityAttributes.ContentState
    var height: CGFloat = 38

    private var muted: Bool { state.muted == true }

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: ActivityReportIntent()) {
                HStack(spacing: 6) {
                    Image(systemName: reportSymbol)
                        .font(.system(size: 15, weight: .bold))
                        .accessibilityHidden(true)
                    reportTitle
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(state.reportFlash == nil ? WTheme.onAction : .white)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(reportFill, in: Capsule())
            }
            .buttonStyle(.plain)

            Button(intent: ActivitySoundIntent()) {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(muted ? WTheme.warning : WTheme.primary)
                    .frame(width: 56, height: height)
                    .background(WTheme.primary.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(muted ? Text("Включить звук") : Text("Выключить звук"))
        }
    }

    private var reportSymbol: String {
        switch state.reportFlash {
        case true?: return "checkmark"
        case false?: return "xmark"
        case nil: return "dot.radiowaves.left.and.right"
        }
    }

    @ViewBuilder
    private var reportTitle: some View {
        switch state.reportFlash {
        case true?: Text("Отмечено")
        case false?: Text("Не отправлено")
        case nil: Text("Радар!")
        }
    }

    private var reportFill: Color {
        switch state.reportFlash {
        case true?: return WTheme.clearFill
        case false?: return WTheme.primary.opacity(0.22)
        case nil: return WTheme.action
        }
    }
}

/// Прибытие: по маршруту — «9:12 · Работа · 4,2 км» (9.1), без маршрута —
/// призрак дороги на работу (8.8.3б): «9:12 · Работа · +4 мин к обычному».
/// Подпись готовит приложение на своём языке; время рисует система.
private struct GhostLine: View {
    let state: CameraActivityAttributes.ContentState

    var body: some View {
        if let clock = state.etaClock, let caption = state.etaCaption {
            HStack(spacing: 4) {
                Text(clock, style: .time)
                    .monospacedDigit()
                    .foregroundStyle(WTheme.primary)
                Text(verbatim: "· \(caption)")
                    .foregroundStyle(state.etaAlert == true ? WTheme.warning : WTheme.secondary)
                    .lineLimit(1)
            }
            .font(.system(.caption, design: .rounded).weight(.semibold))
        }
    }
}
