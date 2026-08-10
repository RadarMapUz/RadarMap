//
//  RadarWeekWidget.swift
//  RadarMapWidgets
//
//  Неделя на локскрине — отдельный виджет, а не второе лицо у существующего.
//
//  Круглый и прямоугольный слоты у RadarStatsWidget заняты кнопкой «Старт
//  поездки», и правильно: за рулём с локскрина нужна кнопка, а не цифра. Но
//  между поездками полезно ровно обратное — балл недели, не открывая
//  приложение. Двум разным задачам нужны два разных виджета, чтобы человек
//  сам выбрал, что у него на экране блокировки.
//
//  Локскрин рисуется одним цветом (система сама решает, каким), поэтому здесь
//  нет ни колец с заливкой, ни красного «риска»: только число, километры и
//  слово. Цвет как носитель смысла на этом экране не работает.
//

import WidgetKit
import SwiftUI

struct RadarWeekEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedDefaults.Snapshot
}

struct RadarWeekProvider: TimelineProvider {
    func placeholder(in context: Context) -> RadarWeekEntry {
        RadarWeekEntry(date: .now, snapshot: .demo)
    }

    func getSnapshot(in context: Context, completion: @escaping (RadarWeekEntry) -> Void) {
        completion(RadarWeekEntry(date: .now,
                                  snapshot: context.isPreview ? .demo : SharedDefaults.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RadarWeekEntry>) -> Void) {
        completion(Timeline(entries: [RadarWeekEntry(date: .now, snapshot: SharedDefaults.read())],
                            policy: .after(.now.addingTimeInterval(3600))))
    }
}

struct RadarWeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RadarWeekWidget", provider: RadarWeekProvider()) { entry in
            RadarWeekView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Неделя")
        .description("Балл и километры недели на экране блокировки")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct RadarWeekView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RadarWeekEntry

    private var snapshot: SharedDefaults.Snapshot { entry.snapshot }
    private var rating: Int { snapshot.weekRating }
    /// Прошлая неделя на локскрине выдала бы себя за текущую особенно легко:
    /// там нет места для дат. Поэтому не свою неделю показываем прочерком.
    private var isCurrentWeek: Bool {
        WidgetWeek.isCurrentWeek(snapshot.weekStart, now: entry.date)
    }
    private var state: WidgetState { WidgetWeek.state(snapshot) }
    private var value: String { rating >= 0 && isCurrentWeek ? "\(rating)" : "—" }
    /// На локскрине герой тоже километры: балл ушёл внутрь кольца.
    private var distance: String { isCurrentWeek ? km(snapshot.weekDistance) : "—" }
    private var progress: Double {
        WidgetWeek.usualWeekProgress(distance: snapshot.weekDistance,
                                     usual: snapshot.usualWeekDistance)
    }

    var body: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryRectangular: rectangular
        default: circular
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            // Кольцо — к обычной неделе, число внутри — километры. Балл на
            // локскрине не помещается вместе с ними, а факт нужнее оценки.
            Gauge(value: progress, in: 0...1) {
                Image(systemName: "car.fill")
            } currentValueLabel: {
                Text(isCurrentWeek ? "\(Int(snapshot.weekDistance / 1000))" : "—")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.7)
            }
            .gaugeStyle(.accessoryCircularCapacity)
        }
        .widgetURL(URL(string: "radarmap://stats"))
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Неделя за рулём")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            HStack(spacing: 6) {
                Text(distance)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                Text(String(format: String(localized: "балл %@"), value))
                    .font(.system(size: 13, design: .rounded))
                    .opacity(0.8)
            }
            Text(usualLine)
                .font(.system(size: 11, design: .rounded))
                .opacity(0.75)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "radarmap://stats"))
    }

    private var inline: some View {
        // Строка над часами: одна короткая мысль, без иконок и без цвета.
        Text(String(format: String(localized: "Неделя %@ · балл %@"), distance, value))
            .widgetURL(URL(string: "radarmap://stats"))
    }

    /// «как обычно» или «из обычных 115 км» — норма, а не абстрактная цель.
    private var usualLine: String {
        let usual = snapshot.usualWeekDistance
        if state == .noAccess { return String(localized: "Нет доступа к данным") }
        guard isCurrentWeek, usual > 1000, snapshot.weekDistance > 0 else {
            return String(localized: "Неделя за рулём")
        }
        let share = snapshot.weekDistance / usual
        if share >= 0.95 && share <= 1.05 { return String(localized: "как обычно") }
        return String(format: String(localized: "из обычных %@"), km(usual))
    }

    private func km(_ meters: Double) -> String {
        meters < 1000 ? String(format: String(localized: "%lld м"), Int(meters))
                      : String(format: String(localized: "%@ км"),
                               (meters / 1000).formatted(.number.precision(.fractionLength(0))))
    }
}
