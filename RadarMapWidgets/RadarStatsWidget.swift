//
//  RadarStatsWidget.swift
//  RadarMapWidgets
//
//  Домашний виджет: рейтинг и километры текущей недели (через App Group).
//
//  Виджет — статистика, видимая вообще без открытия приложения, поэтому его
//  лицо — неделя (кольцо рейтинга, километры, деньги), а не служебные цифры
//  базы. Последняя поездка остаётся на среднем размере второй колонкой.
//  Снимок пишет приложение при уходе в фон и в конце каждой поездки —
//  собственных обновлений (и расхода батареи) у виджета нет.
//

import WidgetKit
import SwiftUI

private enum SW {
    static let accent = Color(red: 0.235, green: 0.863, blue: 1.0)
    static let camera = Color(red: 1.0, green: 0.27, blue: 0.38)
    static let bgTop = Color(red: 0.05, green: 0.08, blue: 0.16)
    static let bgBottom = Color(red: 0.02, green: 0.04, blue: 0.07)
    static let secondary = Color.white.opacity(0.6)
    static let success = Color(red: 0.30, green: 0.87, blue: 0.56)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.25)

    /// Те же пороги, что у баллов в приложении (DrivingScore.tier): виджет не
    /// имеет права красить 70 иначе, чем список поездок.
    static func score(_ rating: Int) -> Color {
        rating >= 75 ? success : rating >= 60 ? warning : camera
    }
}

struct RadarStatsEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedDefaults.Snapshot
}

struct RadarStatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> RadarStatsEntry {
        // Плейсхолдер галереи — красивая живая неделя, а не нули.
        RadarStatsEntry(date: .now, snapshot: .init(
            dbCount: 3475, dbVersion: 11, mobileCount: 2,
            tripCameras: 6, tripMaxSpeed: 92, tripDistance: 12_400,
            weekDistance: 95_200, weekTrips: 6, weekRating: 84,
            weekFineRisk: 0, updatedAt: nil))
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
        .description("Рейтинг и километры недели")
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

    /// Маленький размер — неделя целиком: кольцо рейтинга, километры, деньги.
    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                weekRing(diameter: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Неделя")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(SW.secondary)
                    Text(km(entry.snapshot.weekDistance))
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 0)
            if entry.snapshot.weekRating < 0 {
                Text("Начните поездку — соберём статистику")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(SW.secondary)
            } else {
                weekMoneyLine
                Text(tripsLine)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(SW.secondary.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Кольцо рейтинга недели; без поездок — спокойный прочерк, не ноль.
    private func weekRing(diameter: CGFloat) -> some View {
        let rating = entry.snapshot.weekRating
        let tint = rating >= 0 ? SW.score(rating) : SW.secondary
        return ZStack {
            Circle().stroke(tint.opacity(0.2), lineWidth: 4.5)
            if rating >= 0 {
                Circle()
                    .trim(from: 0, to: max(0.04, Double(rating) / 100))
                    .stroke(tint, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(rating >= 0 ? "\(rating)" : "—")
                .font(.system(size: diameter * 0.34, weight: .heavy, design: .rounded))
                .foregroundStyle(rating >= 0 ? tint : SW.secondary)
        }
        .frame(width: diameter, height: diameter)
    }

    /// Деньги недели одной строкой: щит и «без штрафов» или риск.
    private var weekMoneyLine: some View {
        let risk = entry.snapshot.weekFineRisk
        return HStack(spacing: 5) {
            Image(systemName: risk > 0 ? "exclamationmark.shield.fill"
                                       : "checkmark.shield.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(risk > 0 ? SW.camera : SW.success)
            Text(risk > 0 ? money(risk) : String(localized: "Без штрафов"))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(risk > 0 ? SW.camera : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var tripsLine: String {
        String(format: String(localized: "Поездок: %lld"), entry.snapshot.weekTrips)
    }

    /// Средний размер: неделя слева, последняя поездка справа.
    private var medium: some View {
        HStack(spacing: 16) {
            small
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1)
            VStack(alignment: .leading, spacing: 8) {
                Text("Последняя поездка")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(SW.secondary)
                statRow(icon: "point.topleft.down.to.point.bottomright.curvepath", tint: SW.success,
                        value: km(entry.snapshot.tripDistance), label: "пройдено")
                statRow(icon: "camera.fill", tint: SW.camera,
                        value: "\(entry.snapshot.tripCameras)", label: "камер")
                statRow(icon: "gauge.with.dots.needle.67percent", tint: SW.warning,
                        value: "\(Int(entry.snapshot.tripMaxSpeed))", label: "макс. км/ч")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func km(_ meters: Double) -> String {
        meters < 1000 ? "\(Int(meters)) м" : String(format: "%.1f км", meters / 1000)
    }

    /// Сумы без копеек и по-короткому: на виджете места нет.
    private func money(_ amount: Double) -> String {
        if amount >= 1_000_000 {
            return String(format: String(localized: "≈ %.1f млн сум"), amount / 1_000_000)
        }
        return String(format: String(localized: "≈ %lld тыс сум"), Int(amount / 1000))
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
