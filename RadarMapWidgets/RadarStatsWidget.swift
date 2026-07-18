//
//  RadarStatsWidget.swift
//  RadarMapWidgets
//
//  Домашний виджет: база камер + статистика последней поездки (через App Group).
//

import WidgetKit
import SwiftUI

private enum SW {
    static let accent = Color(red: 0.235, green: 0.863, blue: 1.0)
    static let camera = Color(red: 1.0, green: 0.27, blue: 0.38)
    static let bgTop = Color(red: 0.05, green: 0.08, blue: 0.16)
    static let bgBottom = Color(red: 0.02, green: 0.04, blue: 0.07)
    static let secondary = Color.white.opacity(0.6)
}

struct RadarStatsEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedDefaults.Snapshot
}

struct RadarStatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> RadarStatsEntry {
        RadarStatsEntry(date: .now, snapshot: .init(dbCount: 1831, dbVersion: 2,
                                                    mobileCount: 0, tripCameras: 0,
                                                    tripMaxSpeed: 0, tripDistance: 0, updatedAt: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping (RadarStatsEntry) -> Void) {
        completion(RadarStatsEntry(date: .now, snapshot: SharedDefaults.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RadarStatsEntry>) -> Void) {
        let entry = RadarStatsEntry(date: .now, snapshot: SharedDefaults.read())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
    }
}

struct RadarStatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RadarStatsWidget", provider: RadarStatsProvider()) { entry in
            RadarStatsView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [SW.bgTop, SW.bgBottom],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("RadarMap")
        .description("База камер и статистика поездки")
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryCircular, .accessoryRectangular])
    }
}

private struct RadarStatsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RadarStatsEntry

    var body: some View {
        switch family {
        case .systemMedium: medium
        // Локскрин: старт поездки одним тапом (диплинк), не доставая телефон из держателя.
        case .accessoryCircular: lockCircular
        case .accessoryRectangular: lockRectangular
        default: small
        }
    }

    private var lockCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: "car.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("Старт")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
        }
        .widgetURL(URL(string: "radarmap://start-trip"))
    }

    private var lockRectangular: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.metering.center.weighted")
                .font(.system(size: 16, weight: .bold))
            VStack(alignment: .leading, spacing: 1) {
                Text("RadarMap")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text("Начать поездку")
                    .font(.system(size: 11, design: .rounded))
                    .opacity(0.75)
            }
            Spacer(minLength: 0)
        }
        .widgetURL(URL(string: "radarmap://start-trip"))
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "camera.metering.center.weighted")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(SW.accent)
            Spacer(minLength: 0)
            Text("База камер")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(SW.secondary)
            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.green)
                Text("Актуальна")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Text("обновляется сама")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(SW.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(spacing: 16) {
            small
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1)
            VStack(alignment: .leading, spacing: 8) {
                statRow(icon: "camera.fill", tint: SW.camera,
                        value: "\(entry.snapshot.tripCameras)", label: "камер за поездку")
                statRow(icon: "gauge.with.dots.needle.67percent", tint: .orange,
                        value: "\(Int(entry.snapshot.tripMaxSpeed))", label: "макс. км/ч")
                statRow(icon: "point.topleft.down.to.point.bottomright.curvepath", tint: .green,
                        value: distanceText, label: "пройдено")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var distanceText: String {
        let m = entry.snapshot.tripDistance
        return m < 1000 ? "\(Int(m)) м" : String(format: "%.1f км", m / 1000)
    }

    private func statRow(icon: String, tint: Color, value: String, label: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(SW.secondary)
                .lineLimit(1)
        }
    }
}
