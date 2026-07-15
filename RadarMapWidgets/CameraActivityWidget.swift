//
//  CameraActivityWidget.swift
//  RadarMapWidgets
//
//  Live Activity: ближайшая камера на локскрине и в Dynamic Island,
//  пока приложение свёрнуто. Тёмный «радар-детектор» стиль.
//

import WidgetKit
import SwiftUI
import ActivityKit

private enum WTheme {
    static let accent = Color(red: 0.235, green: 0.863, blue: 1.0)
    static let camera = Color(red: 1.0, green: 0.27, blue: 0.38)
    static let background = Color(red: 0.02, green: 0.04, blue: 0.07)
    static let secondary = Color.white.opacity(0.62)
}

private func format(_ meters: Double) -> String {
    meters < 1000 ? "\(Int(meters.rounded())) м" : String(format: "%.1f км", meters / 1000)
}

struct CameraActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CameraActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(WTheme.background.opacity(0.85))
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
                    Text(context.state.nearestTitle ?? "Камер рядом нет")
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
            .foregroundStyle(state.nearestTitle == nil ? .green : WTheme.camera)
    }
}

private struct LockScreenView: View {
    let state: CameraActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.nearestTitle == nil ? "checkmark.shield.fill" : state.nearestSymbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background((state.nearestTitle == nil ? Color.green : WTheme.camera).gradient, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                if let title = state.nearestTitle, let distance = state.distanceMeters {
                    Text(format(distance))
                        .font(.system(.title3, design: .rounded).bold())
                        .foregroundStyle(WTheme.accent)
                    Text(title)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(WTheme.secondary)
                        .lineLimit(1)
                } else {
                    Text("Камер рядом нет")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.white)
                }
                Text("RadarMap следит за \(state.camerasNearby) камерами вокруг")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(WTheme.secondary.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}
