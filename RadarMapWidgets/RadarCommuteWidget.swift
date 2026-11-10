//
//  RadarCommuteWidget.swift
//  RadarMapWidgets
//
//  «Дорога»: сколько ехать и маршрут одним касанием — нажатие открывает экран
//  «Поехали», поездка сама не стартует. У дома — на работу, у работы — домой,
//  без отметки места — по часам. Числа готовит приложение (WidgetCommute в
//  App Group); виджет только выбирает строку на сейчас. Таймлайн — запись на
//  каждое 15-минутное окно таблицы и на минуту подсказки, а не каждый час.
//  Адреса не показываются никогда — только «Работа»/«Дом», а в приватном
//  режиме на экране блокировки и того нет.
//

import WidgetKit
import SwiftUI

struct RadarCommuteEntry: TimelineEntry {
    let date: Date
    let data: CommuteWidgetData?
    var prefs: WidgetPrefs? = nil
}

struct RadarCommuteProvider: TimelineProvider {
    func placeholder(in context: Context) -> RadarCommuteEntry {
        RadarCommuteEntry(date: .now, data: .demo, prefs: .demo)
    }

    func getSnapshot(in context: Context, completion: @escaping (RadarCommuteEntry) -> Void) {
        completion(context.isPreview
                   ? RadarCommuteEntry(date: .now, data: .demo, prefs: .demo)
                   : RadarCommuteEntry(date: .now, data: WidgetCommute.read(), prefs: WidgetPrefs.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RadarCommuteEntry>) -> Void) {
        let data = WidgetCommute.read()
        let prefs = WidgetPrefs.read()
        let now = Date.now
        let entries = WidgetCommute.entryDates(after: now, data: data)
            .map { RadarCommuteEntry(date: $0, data: data, prefs: prefs) }
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

extension WidgetPrefs {
    static var demo: WidgetPrefs { WidgetPrefs(hasHome: true, hasWork: true) }
}

struct RadarCommuteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RadarCommuteWidget", provider: RadarCommuteProvider()) { entry in
            RadarCommuteView(entry: entry)
                .containerBackground(for: .widget) {
                    SW.background
                }
        }
        .configurationDisplayName("Дорога на работу")
        .description("Сколько ехать и маршрут одним касанием — по вашим поездкам")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct RadarCommuteView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    let entry: RadarCommuteEntry

    private var prefs: WidgetPrefs { entry.prefs ?? WidgetPrefs() }
    private var panel: WidgetCommute.Panel { WidgetCommute.panel(entry.data, prefs: prefs, now: entry.date) }
    private var line: WidgetCommute.Line? { WidgetCommute.line(entry.data, now: entry.date) }

    /// Экран блокировки и StandBy (там нет подложки): телефон лежит открыто.
    private var isPrivate: Bool {
        guard prefs.privateLock else { return false }
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: return true
        default: return !showsBackground
        }
    }

    var body: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .systemMedium: medium
        default: small
        }
    }

    private func url(_ zone: WidgetCommute.Zone) -> URL {
        zone.state == .setup ? TripLink.placesURL : TripLink.ownGoURL(zone.place)
    }

    // MARK: Малый

    private var small: some View {
        Group {
            if panel.primary.state == .setup {
                setupSmall
            } else {
                smallZone(panel.primary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .voicePhrase(line.map { spoken($0, jamAndHint: false) })
        .widgetURL(url(panel.primary))
    }

    @ViewBuilder
    private func smallZone(_ zone: WidgetCommute.Zone) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon(zone))
                    .font(.system(size: 13, weight: .bold))
                    .ink(SW.accent, accent: true)
                    .accessibilityHidden(true)
                Text(title(zone))
                    .font(.system(size: 13, weight: .semibold))
                    .ink(SW.secondary, mono: 0.72)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                WidgetGo()
            }
            Spacer(minLength: 2)
            bigValue(zone, size: 38, color: SW.primary)
            Text(captionText(zone))
                .font(.system(size: 12))
                .ink(SW.secondary, mono: 0.72)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let jam = zone.jam {
                Text(jamText(jam))
                    .font(.system(size: 12, weight: .semibold))
                    .ink(SW.warning, accent: true)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else if let hint = zone.hint {
                Text(hintText(hint))
                    .font(.system(size: 12, weight: .semibold))
                    .ink(isAdvice(hint) ? SW.success : SW.secondary, mono: isAdvice(hint) ? 1 : 0.72,
                         accent: isAdvice(hint))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }

    private var setupSmall: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "house.fill")
                Image(systemName: "briefcase.fill")
            }
            .font(.system(size: 15, weight: .bold))
            .ink(SW.accent, accent: true)
            .accessibilityHidden(true)
            Spacer(minLength: 0)
            Text("Домой — одним касанием")
                .font(.system(size: 15, weight: .heavy))
                .ink(SW.primary)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
            Text("Укажите адреса")
                .font(.system(size: 12, weight: .semibold))
                .ink(SW.accent, accent: true)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: Средний

    /// Две зоны и у каждой своя ссылка. Края виджета заходят в его поля:
    /// карточки держат собственный отступ.
    private var medium: some View {
        HStack(spacing: 8) {
            Link(destination: url(panel.primary)) { zoneCard(panel.primary, main: true) }
            Link(destination: url(panel.secondary)) {
                zoneCard(panel.secondary, main: false)
            }
            .frame(width: panel.primary.state == .setup ? nil : 112)
        }
        .padding(-6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func zoneCard(_ zone: WidgetCommute.Zone, main: Bool) -> some View {
        if zone.state == .setup {
            setupCard(zone)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(place(zone)). \(String(localized: "Указать"))"))
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: icon(zone))
                        .font(.system(size: 12, weight: .bold))
                        .ink(main ? .white : SW.primary, accent: main)
                    Text(title(zone))
                        .font(.system(size: 13, weight: .semibold))
                        .ink(main ? .white.opacity(0.85) : SW.secondary, mono: 0.72)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if main { WidgetGo(size: 22) }
                }
                Spacer(minLength: 0)
                bigValue(zone, size: 30, color: main ? .white : SW.primary)
                Text(cardCaption(zone, main: main))
                    .font(.system(size: 11, weight: main ? .semibold : .regular))
                    .ink(main ? .white.opacity(0.85) : SW.secondary, mono: 0.72)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .wash(main ? SW.accentFill : SW.quiet, in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                  mono: main ? 0.22 : 0.1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spoken(zone)))
        }
    }

    private func setupCard(_ zone: WidgetCommute.Zone) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: icon(zone))
                .font(.system(size: 14, weight: .bold))
                .ink(SW.accent, accent: true)
            Spacer(minLength: 0)
            Text(place(zone))
                .font(.system(size: 15, weight: .heavy))
                .ink(SW.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("Указать")
                .font(.system(size: 11))
                .ink(SW.accent, accent: true)
                .lineLimit(1)
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .ink(SW.primary.opacity(0.22), mono: 0.3))
    }

    private func cardCaption(_ zone: WidgetCommute.Zone, main: Bool) -> String {
        guard main, case .time = zone.state else {
            if case .route = zone.state { return String(localized: "время — после 3 поездок") }
            return String(localized: "обычно")
        }
        var parts: [String] = []
        if let jam = zone.jam {
            parts.append(String(format: String(localized: "пробки +%lld"), Int((jam.extraSeconds / 60).rounded())))
        }
        if let hint = zone.hint { parts.append(shortHint(hint)) }
        return parts.isEmpty ? String(localized: "обычно") : parts.joined(separator: " · ")
    }

    private func bigValue(_ zone: WidgetCommute.Zone, size: CGFloat, color: Color) -> some View {
        Group {
            if case .time = zone.state {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: minutesNumber(zone))
                        .font(.system(size: size, weight: .heavy, design: .rounded))
                    Text("мин")
                        .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                }
            } else {
                Text("Маршрут")
                    .font(.system(size: size * 0.66, weight: .heavy))
            }
        }
        .ink(color)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    // MARK: Локскрин

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                if panel.primary.state == .setup {
                    Text("Указать")
                        .font(.system(size: 11, weight: .semibold))
                        .minimumScaleFactor(0.7)
                } else {
                    Image(systemName: lockIcon(panel.primary))
                        .font(.system(size: 15, weight: .bold))
                        .accessibilityHidden(true)
                    if case .time = panel.primary.state {
                        Text(verbatim: minutesNumber(panel.primary))
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .minimumScaleFactor(0.6)
                    } else {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .bold))
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .voicePhrase(line.map { spoken($0, jamAndHint: nil) })
        .widgetURL(url(panel.primary))
    }

    private var rectangular: some View {
        let zone = panel.primary
        return VStack(alignment: .leading, spacing: 1) {
            switch zone.state {
            case .time:
                Text(lockTitle(zone))
                    .font(.system(size: 12, weight: .semibold))
                Text(verbatim: "\(minutesNumber(zone)) \(String(localized: "мин"))")
                    .font(.system(size: 17, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let note = lockNote(zone) {
                    Text(verbatim: note)
                        .font(.system(size: 11))
                        .opacity(0.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            case .route:
                Text(lockTitle(zone))
                    .font(.system(size: 12, weight: .semibold))
                Text("Маршрут")
                    .font(.system(size: 17, weight: .heavy))
            case .setup:
                Text("Дорога")
                    .font(.system(size: 12, weight: .semibold))
                Text("Укажите адреса")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .voicePhrase(line.map { spoken($0, jamAndHint: false) })
        .widgetURL(url(zone))
    }

    private var inline: some View {
        let zone = panel.primary
        return Group {
            if zone.state == .setup {
                Text("Укажите адреса")
            } else if case .time = zone.state {
                Text(verbatim: String(format: String(localized: "%1$@ · %2$@"), lockTitle(zone),
                                      "\(minutesNumber(zone)) \(String(localized: "мин"))"))
            } else {
                Text(lockTitle(zone))
            }
        }
        .voicePhrase(line.map { spoken($0, jamAndHint: nil) })
        .widgetURL(url(zone))
    }

    private func lockTitle(_ zone: WidgetCommute.Zone) -> String {
        isPrivate ? String(localized: "Дорога") : title(zone)
    }

    private func lockIcon(_ zone: WidgetCommute.Zone) -> String {
        isPrivate ? "road.lanes" : icon(zone)
    }

    /// Строка совета без значения направления: в приватном режиме тоже можно.
    private func lockNote(_ zone: WidgetCommute.Zone) -> String? {
        if let jam = zone.jam {
            return String(format: String(localized: "пробки +%lld"), Int((jam.extraSeconds / 60).rounded()))
        }
        return zone.hint.map(shortHint)
    }

    // MARK: Слова

    private func title(_ zone: WidgetCommute.Zone) -> String {
        if isPrivate { return String(localized: "Дорога") }
        return zone.toWork ? String(localized: "На работу") : String(localized: "Домой")
    }

    private func place(_ zone: WidgetCommute.Zone) -> String {
        zone.toWork ? String(localized: "Работа") : String(localized: "Дом")
    }

    private func icon(_ zone: WidgetCommute.Zone) -> String {
        if isPrivate { return "road.lanes" }
        return zone.toWork ? "briefcase.fill" : "house.fill"
    }

    private func minutesNumber(_ zone: WidgetCommute.Zone) -> String {
        guard case let .time(seconds, approx, _) = zone.state else { return "" }
        let number = "\(Int((seconds / 60).rounded()))"
        return approx ? "~" + number : number
    }

    /// «в это время · обычно 42»: медиана своих поездок в этот час, а не «сейчас»
    /// на дороге — про текущие пробки виджет знает только строкой пробок.
    private func captionText(_ zone: WidgetCommute.Zone) -> String {
        switch zone.state {
        case let .time(_, true, usual):
            return String(format: String(localized: "в это время · обычно %lld"), Int((usual / 60).rounded()))
        case .route: return String(localized: "время — после 3 поездок")
        default: return String(localized: "обычно")
        }
    }

    private func minutes(_ seconds: Double) -> String {
        String(format: String(localized: "%lld мин"), Int((seconds / 60).rounded()))
    }

    private func jamText(_ jam: CommuteWidgetData.Jam) -> String {
        String(format: String(localized: "пробки +%1$@ · %2$@"), minutes(jam.extraSeconds),
               NumberFormat.clock(jam.at))
    }

    private func clock(_ minute: Int) -> String {
        let date = Calendar.current.startOfDay(for: entry.date).addingTimeInterval(Double(minute) * 60)
        return NumberFormat.clock(date)
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

    private func shortHint(_ hint: WidgetCommute.Hint) -> String {
        guard case .leaveBy(let minute) = hint else { return hintText(hint) }
        return String(format: String(localized: "выезд до %@"), clock(minute))
    }

    // MARK: VoiceOver

    private func spoken(_ zone: WidgetCommute.Zone) -> String {
        if case .time(let seconds, _, _) = zone.state {
            return title(zone) + ": " + String(format: String(localized: "обычно %@"), spokenMinutes(seconds))
        }
        return title(zone)
    }

    /// Виджет одной фразой, словами: «На работу: в это время около 44 минут,
    /// обычно 42 минуты. Пробки плюс 8 минут, на 8:05. Выезжайте до 8:10».
    /// `jamAndHint`: `false` — пробки, иначе подсказка, `true` — обе, `nil` —
    /// ни одной.
    private func spoken(_ line: WidgetCommute.Line, jamAndHint: Bool?) -> String {
        let usual = String(format: String(localized: "обычно %@"), spokenMinutes(line.usualSeconds))
        var head = usual
        if let now = line.nowSeconds {
            head = String(format: String(localized: "в это время около %@"), spokenMinutes(now)) + ", " + usual
        }
        let word = isPrivate ? String(localized: "Дорога")
            : line.toWork ? String(localized: "На работу") : String(localized: "Домой")
        var parts = [word + ": " + head]
        if let jamAndHint {
            if let jam = line.jam {
                parts.append(String(format: String(localized: "пробки плюс %1$@, на %2$@"),
                                    spokenMinutes(jam.extraSeconds),
                                    NumberFormat.clock(jam.at)))
            }
            if let hint = line.hint, line.jam == nil || jamAndHint {
                parts.append(spokenHint(hint))
            }
        }
        return parts.joined(separator: ". ")
    }

    private func spokenMinutes(_ seconds: Double) -> String {
        SpokenUnits.minutes(Int((seconds / 60).rounded()))
    }

    private func spokenHint(_ hint: WidgetCommute.Hint) -> String {
        switch hint {
        case .leaveBy(let minute):
            return String(format: String(localized: "выезжайте до %@"), clock(minute))
        case .best(let minute, let seconds):
            return String(format: String(localized: "в %1$@ — %2$@"), clock(minute), spokenMinutes(seconds))
        case .usualDeparture(let minute):
            return String(format: String(localized: "выезд около %@"), clock(minute))
        }
    }

    private func isAdvice(_ hint: WidgetCommute.Hint) -> Bool {
        if case .usualDeparture = hint { return false }
        return true
    }
}

private extension View {
    /// Виджет — одна мысль: VoiceOver читает его одной фразой, если она есть
    /// (без данных — приглашение читается как есть, строками).
    @ViewBuilder
    func voicePhrase(_ phrase: String?) -> some View {
        if let phrase {
            accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(phrase))
        } else {
            self
        }
    }
}
