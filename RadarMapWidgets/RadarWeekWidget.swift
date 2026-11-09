//
//  RadarWeekWidget.swift
//  RadarMapWidgets
//
//  Неделя на локскрине — отдельный виджет, а не второе лицо у существующего.
//
//  Круглый и прямоугольный слоты у RadarStatsWidget заняты кнопкой «Старт
//  поездки». Между поездками полезно ровно обратное — балл недели, не открывая
//  приложение, — и это отдельный виджет, чтобы человек сам выбрал, что у него
//  на экране блокировки.
//
//  Локскрин рисуется одним цветом, поэтому здесь нет ни заливок, ни красного
//  «риска»: число, километры, слово. Нулей здесь тоже нет: ноль километров —
//  не факт, а его отсутствие.
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
        let snapshot = SharedDefaults.read()
        completion(Timeline(entries: [RadarWeekEntry(date: .now, snapshot: snapshot)],
                            policy: .after(WidgetWeek.nextRefresh(after: .now))))
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
    private var hasWeek: Bool {
        WidgetWeek.isCurrentWeek(snapshot.weekStart, now: entry.date) && snapshot.weekDistance > 0
    }
    private var state: WidgetState { WidgetWeek.state(snapshot) }
    private var progress: Double {
        WidgetWeek.usualWeekProgress(distance: snapshot.weekDistance, usual: snapshot.usualWeekDistance)
    }
    private var rating: Int? { snapshot.weekRating >= 0 ? snapshot.weekRating : nil }
    private var today: Int? { WidgetWeek.todayIndex(snapshot.weekStart, now: entry.date) }
    private var kmNumber: String {
        snapshot.weekDistance < 1000 ? "<1" : "\(Int(snapshot.weekDistance / 1000))"
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
            if hasWeek {
                Gauge(value: progress, in: 0...1) {
                    Image(systemName: "car.fill")
                } currentValueLabel: {
                    Text(verbatim: kmNumber)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .minimumScaleFactor(0.7)
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                VStack(spacing: 0) {
                    Image(systemName: "car.fill")
                        .font(.system(size: 15, weight: .bold))
                    Text(verbatim: "—")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                }
            }
        }
        .widgetURL(URL(string: "radarmap://stats"))
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Неделя")
                .font(.system(size: 12, weight: .semibold))
            if hasWeek {
                Text(verbatim: valueLine)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                dots
            } else {
                Text(emptyTitle)
                    .font(.system(size: 17, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let emptyNote {
                    Text(verbatim: emptyNote)
                        .font(.system(size: 11))
                        .opacity(0.8)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "radarmap://stats"))
    }

    private var inline: some View {
        Group {
            if hasWeek {
                Text(verbatim: inlineLine)
            } else if state == .noAccess {
                Text("Нет доступа к данным")
            } else if state == .empty {
                Text("Первая поездка")
            } else {
                Text("На этой неделе поездок нет")
            }
        }
        .widgetURL(URL(string: "radarmap://stats"))
    }

    /// Прошедшие ездовые дни бледнее, сегодня полной точкой, остальное — кружок.
    private var dots: some View {
        let values = WidgetWeek.dayDots(snapshot.dayDistances, today: today)
        return HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { index in
                Group {
                    switch values[index] {
                    case .today: Circle().fill(.primary)
                    case .driven: Circle().fill(.primary.opacity(0.55))
                    case .none: Circle().stroke(.primary.opacity(0.4), lineWidth: 1)
                    }
                }
                .frame(width: 7, height: 7)
            }
        }
    }

    private var emptyTitle: LocalizedStringKey {
        switch state {
        case .noAccess: return "Нет доступа"
        case .empty: return "Первая поездка"
        default: return "Поездок нет"
        }
    }

    private var emptyNote: String? {
        guard state != .noAccess, snapshot.usualWeekDistance > 1000 else { return nil }
        return String(format: String(localized: "обычно %@"), km(snapshot.usualWeekDistance))
    }

    private var valueLine: String {
        guard let rating else { return km(snapshot.weekDistance) }
        return String(format: String(localized: "%1$@ · балл %2$lld"), km(snapshot.weekDistance), rating)
    }

    private var inlineLine: String {
        guard snapshot.usualWeekDistance > 1000, state == .full else { return valueLine }
        let usual = "\(Int(snapshot.usualWeekDistance / 1000))"
        if let rating {
            return String(format: String(localized: "%1$@ из %2$@ км · балл %3$lld"), kmNumber, usual, rating)
        }
        return String(format: String(localized: "%1$@ из %2$@ км"), kmNumber, usual)
    }

    private func km(_ meters: Double) -> String {
        meters < 1000 ? String(format: String(localized: "%lld м"), Int(meters))
                      : String(format: String(localized: "%@ км"),
                               (meters / 1000).formatted(.number.precision(.fractionLength(0))
                                                            .locale(NumberFormat.locale)))
    }
}
