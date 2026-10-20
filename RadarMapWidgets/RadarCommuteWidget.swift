//
//  RadarCommuteWidget.swift
//  RadarMapWidgets
//
//  «Дорога на работу» (план 19.10, 9.4 и 12б.2): «сейчас ~44 мин · пробки
//  +8», «обычно 42 мин, выезжайте до 8:10». У дома — на работу, у работы —
//  домой, без отметки места — по часам. Числа готовит приложение
//  (WidgetCommute в App Group); виджет только выбирает строку на сейчас.
//  Таймлайн — запись на каждое 15-минутное окно таблицы «сейчас» и на
//  минуту подсказки, а не каждый час. Адреса не показываются никогда —
//  только «Работа»/«Дом». Тап — «Итоги», где карточка дороги.
//

import WidgetKit
import SwiftUI

struct RadarCommuteEntry: TimelineEntry {
    let date: Date
    let data: CommuteWidgetData?
}

struct RadarCommuteProvider: TimelineProvider {
    func placeholder(in context: Context) -> RadarCommuteEntry {
        RadarCommuteEntry(date: .now, data: .demo)
    }

    func getSnapshot(in context: Context, completion: @escaping (RadarCommuteEntry) -> Void) {
        completion(RadarCommuteEntry(date: .now, data: context.isPreview ? .demo : WidgetCommute.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RadarCommuteEntry>) -> Void) {
        let data = WidgetCommute.read()
        let now = Date.now
        let entries = WidgetCommute.entryDates(after: now, data: data).map { RadarCommuteEntry(date: $0, data: data) }
        completion(Timeline(entries: entries,
                            policy: .after(WidgetCommute.nextRefresh(after: now, data: data))))
    }
}

extension CommuteWidgetData {
    /// Утро с советом — для галереи и превью.
    static var demo: Self {
        let day = Calendar.current.startOfDay(for: .now)
        let leave: Date = day.addingTimeInterval(29_400)   // 8:10
        var work = Direction(usualSeconds: 2520, usualDepartureMinute: 500,
                             bestStartMinute: 465, bestSeconds: 2160, leaveBy: leave)
        let slot = Date.now.addingTimeInterval(-60)
        work.slots = [CommuteWidgetData.Slot(start: slot, seconds: 2640)]
        work.jam = CommuteWidgetData.Jam(extraSeconds: 480, at: slot)
        let home = Direction(usualSeconds: 2340, usualDepartureMinute: 1110)
        return CommuteWidgetData(toWork: work, toHome: home, updatedAt: .now)
    }
}

struct RadarCommuteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RadarCommuteWidget", provider: RadarCommuteProvider()) { entry in
            RadarCommuteView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [SW.bgTop, SW.bgBottom], startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("Дорога на работу")
        .description("Сколько обычно ехать и когда выезжать — по вашим поездкам")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

private struct RadarCommuteView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RadarCommuteEntry

    private var line: WidgetCommute.Line? { WidgetCommute.line(entry.data, now: entry.date) }

    var body: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryRectangular: rectangular
        case .systemMedium: medium
        default: small
        }
    }

    // MARK: Малый

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let line {
                lineBlock(line)
            } else {
                invitation
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(URL(string: "radarmap://stats"))
    }

    /// Направление, «сейчас ~N» (или «обычно»), пробки и подсказка.
    @ViewBuilder
    private func lineBlock(_ line: WidgetCommute.Line) -> some View {
        HStack(spacing: 6) {
            Image(systemName: line.toWork ? "briefcase.fill" : "house.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(SW.accent)
            Text(title(line))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(SW.secondary)
        }
        Spacer(minLength: 0)
        Text(headline(line))
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .foregroundStyle(SW.primary)
            .minimumScaleFactor(0.7)
            .lineLimit(1)
        Text(caption(line))
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(SW.tertiary)
            .lineLimit(1)
        if let jam = line.jam {
            Text(jamText(jam))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(SW.warning)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else if let hint = line.hint {
            Text(hintText(hint))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(isAdvice(hint) ? SW.success : SW.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }

    private var invitation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "briefcase.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(SW.accent)
            Spacer(minLength: 0)
            // Приглашение, а не ноль: «дороги» ещё нет — так и сказать.
            Text("Дорога на работу появится после трёх поездок между домом и работой")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(SW.secondary)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: Средний

    /// Слева — дорога на сейчас целиком, справа — обратная одной строкой
    /// и подсказка, если пробки заняли её место слева.
    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if let line { lineBlock(line) } else { invitation }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            if let line {
                VStack(alignment: .leading, spacing: 8) {
                    if let other = otherDirection(line) {
                        Label(line.toWork ? String(localized: "Домой") : String(localized: "На работу"),
                              systemImage: line.toWork ? "house.fill" : "briefcase.fill")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(SW.secondary)
                        Text(String(format: String(localized: "обычно %@"), minutes(other.usualSeconds)))
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                            .foregroundStyle(SW.primary)
                    }
                    Spacer(minLength: 0)
                    if line.jam != nil, let hint = line.hint {
                        Text(hintText(hint))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(isAdvice(hint) ? SW.success : SW.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .widgetURL(URL(string: "radarmap://stats"))
    }

    private func otherDirection(_ line: WidgetCommute.Line) -> CommuteWidgetData.Direction? {
        line.toWork ? entry.data?.toHome : entry.data?.toWork
    }

    // MARK: Локскрин

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let line {
                Text(title(line))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(line.nowSeconds.map { approx($0) }
                     ?? String(format: String(localized: "обычно %@"), minutes(line.usualSeconds)))
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                if let jam = line.jam {
                    Text(jamText(jam))
                        .font(.system(size: 11, design: .rounded))
                        .opacity(0.8)
                        .lineLimit(1)
                } else if let hint = line.hint {
                    Text(hintText(hint))
                        .font(.system(size: 11, design: .rounded))
                        .opacity(0.8)
                        .lineLimit(1)
                }
            } else {
                Text("Дорога на работу")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text("после трёх поездок")
                    .font(.system(size: 11, design: .rounded))
                    .opacity(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "radarmap://stats"))
    }

    private var inline: some View {
        Group {
            if let line {
                Text(String(format: String(localized: "%1$@ · %2$@"), title(line),
                            line.nowSeconds.map { approx($0) }
                                ?? String(format: String(localized: "обычно %@"), minutes(line.usualSeconds))))
            } else {
                Text("Дорога на работу")
            }
        }
        .widgetURL(URL(string: "radarmap://stats"))
    }

    /// Крупная цифра: «~44 мин» по таблице на сейчас, иначе «обычно».
    private func headline(_ line: WidgetCommute.Line) -> String {
        line.nowSeconds.map { approx($0) } ?? minutes(line.usualSeconds)
    }

    private func caption(_ line: WidgetCommute.Line) -> String {
        guard line.nowSeconds != nil else { return String(localized: "обычно") }
        return String(format: String(localized: "сейчас · обычно %@"), minutes(line.usualSeconds))
    }

    private func approx(_ seconds: Double) -> String {
        String(format: String(localized: "~%@"), minutes(seconds))
    }

    private func jamText(_ jam: CommuteWidgetData.Jam) -> String {
        String(format: String(localized: "пробки +%1$@ · на %2$@"), minutes(jam.extraSeconds),
               jam.at.formatted(date: .omitted, time: .shortened))
    }

    // MARK: Слова

    private func title(_ line: WidgetCommute.Line) -> String {
        line.toWork ? String(localized: "На работу") : String(localized: "Домой")
    }

    private func minutes(_ seconds: Double) -> String {
        String(format: String(localized: "%lld мин"), Int((seconds / 60).rounded()))
    }

    private func clock(_ minute: Int) -> String {
        let date = Calendar.current.startOfDay(for: entry.date).addingTimeInterval(Double(minute) * 60)
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func hintText(_ hint: WidgetCommute.Hint) -> String {
        switch hint {
        case .leaveBy(let minute):
            return String(format: String(localized: "выезжайте до %@"), clock(minute))
        case .best(let minute, let seconds):
            return String(format: String(localized: "в %1$@ — %2$@"), clock(minute), minutes(seconds))
        case .usualDeparture(let minute):
            return String(format: String(localized: "выезд около %@"), clock(minute))
        }
    }

    private func isAdvice(_ hint: WidgetCommute.Hint) -> Bool {
        if case .usualDeparture = hint { return false }
        return true
    }
}
