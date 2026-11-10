//
//  RadarStatsWidget.swift
//  RadarMapWidgets
//
//  Домашний виджет: неделя кольцами, как календарь «Итогов». Внешнее кольцо —
//  аккуратность, внутреннее — пробег к СВОЕЙ обычной неделе, а не к чужой
//  цели. Снимок пишет приложение при уходе в фон и в конце каждой поездки;
//  собственных обновлений (и расхода батареи) у виджета нет.
//
//  Два правила:
//  1. Неделя важнее последней поездки. Виджет смотрят МЕЖДУ поездками, а
//     сразу после неё итог показывает сама карточка «Поездка сохранена».
//  2. Виджет не имеет права выдавать прошлую неделю за текущую. Если снимок
//     не про эту неделю, он называет свои даты (см. WidgetWeek).
//

import WidgetKit
import SwiftUI
import UIKit

/// Палитра виджета — палитра А приложения (WidgetPalette, числа сверяет
/// тест с Theme). Виджет живёт на ЧУЖОМ экране, рядом с «Погодой» и
/// «Календарём», поэтому следует теме системы: белая карточка днём,
/// графитовая ночью — как панели самого приложения. Кольца тоже: ночью цвета
/// Theme.Stats, днём те же оттенки потемнее (на белом ночные не читаются).
enum SW {
    /// Один цвет без темы — для всегда тёмных Live Activity и Dynamic Island.
    static func fixed(_ hex: UInt32) -> Color { WidgetPalette.color(hex) }

    private static func color(_ pair: WidgetPalette.Pair) -> Color {
        Color(uiColor: UIColor { traits in
            rgb(traits.userInterfaceStyle == .dark ? pair.dark : pair.light)
        })
    }

    private static func rgb(_ hex: UInt32) -> UIColor { UIColor(WidgetPalette.color(hex)) }

    static let accent = color(WidgetPalette.accent)
    /// Заливки под белым значком: текстовые accent/danger ночью светлые.
    static let accentFill = color(WidgetPalette.accentFill)
    static let cameraFill = color(WidgetPalette.dangerFill)
    static let camera = color(WidgetPalette.danger)
    static let success = color(WidgetPalette.success)
    static let warning = color(WidgetPalette.warning)

    static let background = color(WidgetPalette.surface)
    static let signRed = fixed(WidgetPalette.signRed)
    /// Жёлтый один на виджет: главное действие.
    static let action = fixed(WidgetPalette.action)
    static let onAction = fixed(WidgetPalette.onAction)
    /// Спокойная зона «Дороги».
    static let quiet = color(WidgetPalette.quiet)

    static let primary = color(WidgetPalette.primary)
    static let secondary = color(WidgetPalette.secondary)
    static let tertiary = color(WidgetPalette.tertiary)
    /// Подложки плиток и пустых столбиков — «чернила» темы, а не белый.
    static let ink = primary

    enum Ring {
        static let calm = gradient(WidgetPalette.ringCalm)
        static let watch = gradient(WidgetPalette.ringWatch)
        static let risk = gradient(WidgetPalette.ringRisk)
        static let road = gradient(WidgetPalette.ringRoad)
        static let commute = color(WidgetPalette.statsCommute)
        static let other = color(WidgetPalette.statsOther)

        private static func gradient(_ value: WidgetPalette.Gradient) -> [Color] {
            zip(value.light, value.dark).map { color(WidgetPalette.Pair(light: $0, dark: $1)) }
        }

        /// Кольцо аккуратности по ступени балла; нет балла — спокойное.
        static func tier(_ score: Int?) -> [Color] {
            guard let score else { return calm }
            switch WidgetPalette.scoreTier(score) {
            case 2:  return calm
            case 1:  return watch
            default: return risk
            }
        }
    }

    /// Сумы без копеек и по-короткому: на виджете места нет.
    static func moneyText(_ amount: Double) -> String {
        if amount >= 1_000_000 {
            return "≈ " + String(format: String(localized: "%@ млн сум"),
                                 NumberFormat.decimal(amount / 1_000_000))
        }
        return String(format: String(localized: "≈ %lld тыс сум"), Int(amount / 1000))
    }

    /// Цвет балла — ступени DrivingScore.tier через WidgetPalette.scoreTier.
    static func score(_ rating: Int) -> Color {
        switch WidgetPalette.scoreTier(rating) {
        case 2:  return success
        case 1:  return warning
        default: return camera
        }
    }
}

struct RadarStatsEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedDefaults.Snapshot
}

struct RadarStatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> RadarStatsEntry {
        RadarStatsEntry(date: .now, snapshot: .demo)
    }

    func getSnapshot(in context: Context, completion: @escaping (RadarStatsEntry) -> Void) {
        // Витрина галереи — живая неделя, а не нули: там виджет выбирают.
        completion(RadarStatsEntry(date: .now,
                                   snapshot: context.isPreview ? .demo : SharedDefaults.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RadarStatsEntry>) -> Void) {
        let entry = RadarStatsEntry(date: .now, snapshot: SharedDefaults.read())
        // Не ради новых цифр (их приносит приложение), а чтобы виджет сам
        // заметил смену дня и недели — раз в сутки, не раз в час.
        completion(Timeline(entries: [entry], policy: .after(WidgetWeek.nextRefresh(after: .now))))
    }
}

extension SharedDefaults.Snapshot {
    /// Красивая неделя для галереи и превью.
    static var demo: Self {
        .init(weekStart: Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start,
              weekDistance: 128_400, weekTrips: 9, weekRating: 67, weekFineRisk: 2_200_000,
              dayDistances: [14_000, 22_000, 31_000, 9_000, 27_000, 0, 25_400],
              dayOverspeed: [false, false, true, false, true, false, false],
              dayScores: [84, 92, 48, 76, 66, -1, 71],
              dayRoad: [0.7, 1, 1, 0.45, 1, 0, 1],
              dayPerfect: [false, true, false, false, false, false, false],
              topRiskPlace: "Юнусабад, Амира Темура", topRiskPasses: 4,
              usualWeekDistance: 115_000, monthDistance: 486_000,
              lifetimeDistance: 12_400_000, weekMovingDuration: 4.5 * 3600,
              weekCommuteDistance: 82_000,
              updatedAt: .now)
    }
}

struct RadarStatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RadarStatsWidget", provider: RadarStatsProvider()) { entry in
            RadarStatsView(entry: entry)
                .containerBackground(for: .widget) {
                    SW.background
                }
        }
        .configurationDisplayName("RadarMap")
        .description("Неделя за рулём: километры, балл и дни. На экране блокировки — старт поездки")
        // accessory* остаются здесь ради тех, у кого виджет уже стоит на
        // локскрине: смена набора семейств у существующего kind сносит его с
        // экрана. Неделя на локскрине живёт отдельным виджетом (RadarWeekWidget).
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular])
        .notInCarPlay()
    }
}

private extension WidgetConfiguration {
    /// «Итоги» не для машины (25.H3). С iOS 26 малые виджеты (`systemSmall`)
    /// идут и на главный экран CarPlay, а километры и норма недели за рулём —
    /// разглядывание, а не дело. В машине остаётся «Дорога на работу»: «На
    /// работу ~44 мин» отвечает на вопрос, который там и задают.
    /// Запретить место WidgetKit не даёт (в SDK iOS 27 это единственный API
    /// мест): `disfavored` уносит виджет в раздел «Другие» галереи машины,
    /// с глаз долой из предложенных. Что с уже поставленным — документация
    /// молчит; проверка в машине (🚗).
    func notInCarPlay() -> some WidgetConfiguration {
        if #available(iOSApplicationExtension 26.0, *) {
            return disfavoredLocations([.carPlay], for: [.systemSmall])
        } else {
            return self
        }
    }
}

private struct RadarStatsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RadarStatsEntry

    var body: some View {
        switch family {
        // Локскрин: старт поездки одним тапом (диплинк), не доставая телефон из держателя.
        case .accessoryCircular: lockCircular
        case .accessoryRectangular: lockRectangular
        default:
            switch state {
            case .noAccess: noAccess
            case .empty:    firstTrip
            case .newWeek:  newWeek.widgetURL(URL(string: "radarmap://stats"))
            case .few, .full:
                Group {
                    switch family {
                    case .systemMedium: medium
                    case .systemLarge: large
                    default: small
                    }
                }
                .widgetURL(URL(string: "radarmap://stats"))
            }
        }
    }

    // MARK: - Общее

    private var snapshot: SharedDefaults.Snapshot { entry.snapshot }
    private var isCurrentWeek: Bool {
        WidgetWeek.isCurrentWeek(snapshot.weekStart, now: entry.date)
    }
    private var state: WidgetState { WidgetWeek.state(snapshot) }
    private var rating: Int? { snapshot.weekRating >= 0 ? snapshot.weekRating : nil }
    private var today: Int? { WidgetWeek.todayIndex(snapshot.weekStart, now: entry.date) }

    /// Внутреннее кольцо — только когда норма есть.
    private var roadProgress: Double? {
        state == .full
            ? WidgetWeek.usualWeekProgress(distance: snapshot.weekDistance, usual: snapshot.usualWeekDistance)
            : nil
    }

    /// Даты недели снимка: «19–25 окт.», через месяц — «28 сент. – 4 окт.».
    private var weekDates: String? {
        guard let start = snapshot.weekStart else { return nil }
        let end = start.addingTimeInterval(6 * 86400)
        return (start..<end).formatted(.interval.day().month(.abbreviated)
                                        .locale(NumberFormat.locale))
    }

    /// Подпись под километрами. Снимок чужой недели называет свои даты, полная
    /// неделя говорит о норме, скудная — о последней поездке.
    private func subtitle(compact: Bool) -> String? {
        if !isCurrentWeek { return weekDates }
        if state == .full { return usualText }
        return lastTripText(compact: compact)
    }

    private var usualText: String? {
        switch WidgetWeek.usualLine(distance: snapshot.weekDistance, usual: snapshot.usualWeekDistance) {
        case .none: return nil
        case .asUsual: return String(localized: "как обычно")
        case .ofUsual(let usual): return String(format: String(localized: "из обычных %@"), km(usual))
        case .above(let percent): return String(format: String(localized: "на %lld%% больше обычного"), percent)
        }
    }

    /// Абсолютный день, а не «2 часа назад»: виджет перерисовывается раз в
    /// сутки, и относительная подпись замирала между перезагрузками.
    private func lastTripText(compact: Bool) -> String? {
        guard snapshot.lastTripDistance > 0, let at = snapshot.lastTripAt else { return nil }
        let when: String
        switch WidgetWeek.daysAgo(at, now: entry.date) {
        case 0:  when = String(localized: "сегодня")
        case 1:  when = String(localized: "вчера")
        default: when = at.formatted(.dateTime.day().month(.abbreviated).locale(NumberFormat.locale))
        }
        return compact
            ? String(format: String(localized: "последняя — %@"), when)
            : String(format: String(localized: "последняя — %@, %@"), when, km(snapshot.lastTripDistance))
    }

    private var previousLine: String? {
        guard snapshot.previousWeekDistance >= 1000 else { return nil }
        if snapshot.previousWeekRating >= 0 {
            return String(format: String(localized: "Прошлая: %1$@ · балл %2$lld"),
                          km(snapshot.previousWeekDistance), snapshot.previousWeekRating)
        }
        return String(format: String(localized: "Прошлая: %@"), km(snapshot.previousWeekDistance))
    }

    private var usualHint: String? {
        snapshot.usualWeekDistance > 1000
            ? String(format: String(localized: "обычно %@"), km(snapshot.usualWeekDistance)) : nil
    }

    private func hero(size: CGFloat) -> some View {
        let parts = kmParts(snapshot.weekDistance)
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: parts.value)
                .font(.system(size: size, weight: .heavy, design: .rounded))
            Text(verbatim: parts.unit)
                .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
        }
        .ink(SW.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private func caption(_ text: String?, size: CGFloat = 11, lines: Int = 1) -> some View {
        Text(text ?? "")
            .font(.system(size: size))
            .ink(SW.secondary, mono: 0.72)
            .lineLimit(lines)
            .minimumScaleFactor(0.75)
    }

    private func scoreChip(_ rating: Int, size: CGFloat) -> some View {
        Text(String(format: String(localized: "балл %@"), "\(rating)"))
            .font(.system(size: size, weight: .heavy))
            .ink(SW.score(rating), accent: true)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .wash(SW.score(rating).opacity(0.14), in: Capsule())
            .fixedSize()
    }

    /// Щит и «без штрафов» или риск: красный у значка и суммы, не у строки.
    private func money(size: CGFloat) -> some View {
        let risk = snapshot.weekFineRisk
        return HStack(spacing: 3) {
            Image(systemName: risk > 0 ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                .font(.system(size: size - 1, weight: .bold))
                .ink(risk > 0 ? SW.camera : SW.success, accent: risk > 0)
            Text(risk > 0 ? SW.moneyText(risk) : String(localized: "Без штрафов"))
                .font(.system(size: size, weight: .bold, design: .rounded))
                .ink(risk > 0 ? SW.camera : SW.primary, accent: risk > 0)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// Семь дней кольцами; пустой день не исчезает, иначе неделя короче.
    private func days(side: CGFloat) -> some View {
        let rings = WidgetWeek.dayRings(snapshot)
        let labels = WidgetWeek.dayLabels()
        return HStack(alignment: .top, spacing: 0) {
            ForEach(0..<7, id: \.self) { index in
                VStack(spacing: 3) {
                    WidgetDayRing(ring: rings[index], side: side)
                    Text(labels[index])
                        .font(.system(size: 9, weight: today == index ? .heavy : .medium))
                        .ink(today == index ? SW.primary : SW.tertiary, mono: today == index ? 1 : 0.6)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Состояния без данных

    private var noAccess: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "exclamationmark.lock.fill")
                .font(.system(size: 20, weight: .bold))
                .ink(SW.warning, accent: true)
            Text("Нет доступа к данным")
                .font(.system(size: 17, weight: .heavy))
                .ink(SW.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var firstTrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            if family != .systemSmall { Spacer(minLength: 0) }
            WidgetRings(score: nil, road: 0, side: family == .systemSmall ? 54 : 60)
            if family == .systemSmall { Spacer(minLength: 0) }
            Text("Первая поездка")
                .font(.system(size: 17, weight: .heavy))
                .ink(SW.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("Кольца заполнятся сами")
                .font(.system(size: 12))
                .ink(SW.secondary, mono: 0.72)
                .lineLimit(2)
            if family != .systemSmall { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Понедельник у водителя с историей: пустые кольца, прошлая неделя.
    private var newWeek: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                WidgetRings(score: nil, road: 0, side: family == .systemSmall ? 62 : 72)
                if family != .systemSmall {
                    VStack(alignment: .leading, spacing: 2) {
                        newWeekTitle(size: 19)
                        if let usualHint { caption(usualHint, size: 12) }
                    }
                }
                Spacer(minLength: 0)
            }
            if family == .systemSmall {
                Spacer(minLength: 4)
                newWeekTitle(size: 17)
            } else {
                Spacer(minLength: 6)
            }
            if let line = previousLine ?? (family == .systemSmall ? usualHint : nil) {
                caption(line, size: 12, lines: family == .systemSmall ? 2 : 1)
            }
            if family == .systemLarge {
                Spacer(minLength: 10)
                days(side: 34)
                Spacer(minLength: 10)
                tiles
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func newWeekTitle(size: CGFloat) -> some View {
        Text("Новая неделя")
            .font(.system(size: size, weight: .heavy))
            .ink(SW.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    // MARK: - Размеры

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 2) {
                WidgetRings(score: rating, road: roadProgress, side: 70)
                Spacer(minLength: 2)
                if let rating {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(verbatim: "\(rating)")
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .ink(SW.score(rating), accent: true)
                        Text("балл")
                            .font(.system(size: 10, weight: .medium))
                            .ink(SW.secondary, mono: 0.72)
                    }
                }
            }
            Spacer(minLength: 2)
            hero(size: 26)
            caption(subtitle(compact: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var medium: some View {
        VStack(spacing: 8) {
            HStack(spacing: 11) {
                WidgetRings(score: rating, road: roadProgress, side: 60)
                VStack(alignment: .leading, spacing: 1) {
                    hero(size: 25)
                    caption(subtitle(compact: true))
                }
                Spacer(minLength: 2)
                VStack(alignment: .trailing, spacing: 5) {
                    if let rating { scoreChip(rating, size: 11) }
                    money(size: 11)
                }
            }
            days(side: 27)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Содержимое большого: система даёт 322 pt на экранах 390 и 292 на SE,
    /// поэтому строки разложены по важности, а не по порядку на экране.
    private var large: some View {
        ViewThatFits(in: .vertical) {
            largeBody(risk: true, tiles: true, rings: 100)
            largeBody(risk: true, tiles: false, rings: 100)
            largeBody(risk: true, tiles: false, rings: 84)
            largeBody(risk: false, tiles: false, rings: 84)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func largeBody(risk showsRisk: Bool, tiles showsTiles: Bool, rings side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Неделя")
                    .font(.system(size: 13, weight: .semibold))
                    .ink(SW.secondary, mono: 0.72)
                Spacer()
                if let weekDates {
                    Text(verbatim: weekDates)
                        .font(.system(size: 11))
                        .ink(SW.tertiary, mono: 0.6)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 14) {
                WidgetRings(score: rating, road: roadProgress, side: side)
                VStack(alignment: .leading, spacing: 3) {
                    hero(size: 34)
                    caption(subtitle(compact: false), size: 12)
                    HStack(spacing: 7) {
                        if let rating { scoreChip(rating, size: 12) }
                        money(size: 12)
                    }
                }
                Spacer(minLength: 0)
            }
            days(side: 34)
            let split = WidgetWeek.split(snapshot)
            if let split { splitRow(split) }
            if showsTiles || split == nil { tiles }
            if showsRisk, let place = snapshot.topRiskPlace, snapshot.topRiskPasses > 0 {
                riskRow(place: place, passes: snapshot.topRiskPasses)
            }
        }
    }

    /// Дорога дом–работа и всё остальное: цвета те же, что столбики «Итогов».
    private func splitRow(_ split: WidgetWeek.Split) -> some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .ink(SW.Ring.commute, accent: true)
                        .frame(width: max(4, (geometry.size.width - 2) * split.commuteShare))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .ink(SW.Ring.other, mono: 0.5)
                }
            }
            .frame(height: 7)
            HStack {
                splitLabel(SW.Ring.commute, accent: true,
                           String(format: String(localized: "Работа и дом %@"), kmWhole(split.commute)))
                Spacer(minLength: 4)
                splitLabel(SW.Ring.other, accent: false,
                           String(format: String(localized: "Другое %@"), kmWhole(split.other)))
            }
        }
    }

    private func splitLabel(_ color: Color, accent: Bool, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().ink(color, mono: accent ? 1 : 0.5, accent: accent).frame(width: 7, height: 7)
            Text(verbatim: text)
                .font(.system(size: 11))
                .ink(SW.secondary, mono: 0.72)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var tiles: some View {
        HStack(spacing: 0) {
            tile(km(snapshot.monthDistance), String(localized: "за месяц"))
            tileDivider
            // «Всего» — только когда это не тот же месяц другими словами.
            if WidgetWeek.showsLifetime(month: snapshot.monthDistance, lifetime: snapshot.lifetimeDistance) {
                tileDivider
                tile(km(snapshot.lifetimeDistance), String(localized: "всего"))
            }
            // Ноль минут — не факт, а его отсутствие.
            if snapshot.weekMovingDuration >= 60 {
                tileDivider
                tile(duration(snapshot.weekMovingDuration), String(localized: "за рулём"))
            }
        }
        .padding(.vertical, 8)
        .wash(SW.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous), mono: 0.1)
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .ink(SW.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 10))
                .ink(SW.secondary, mono: 0.72)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private var tileDivider: some View {
        Rectangle().ink(SW.ink.opacity(0.10), mono: 0.2).frame(width: 1, height: 24)
    }

    /// Где теряете баллы — то же место, что в «Итогах», одной строкой.
    private func riskRow(place: String, passes: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 13, weight: .bold))
                .ink(SW.camera, accent: true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Где теряете баллы")
                    .font(.system(size: 10))
                    .ink(SW.secondary, mono: 0.72)
                Text(place)
                    .font(.system(size: 12, weight: .semibold))
                    .ink(SW.primary)
                    .lineLimit(1)
                    .privacySensitive()
            }
            Spacer(minLength: 4)
            Text(String(format: String(localized: "×%lld"), passes))
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .ink(SW.camera, accent: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .wash(SW.camera.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous), mono: 0.1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(format: String(localized: "Где теряете баллы: %@, проездов с превышением: %lld"),
                                        place, passes)))
    }

    // MARK: - Локскрин: старт поездки

    private var lockCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: "car.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("Старт")
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .widgetURL(TripLink.ownStartURL)
    }

    private var lockRectangular: some View {
        HStack(spacing: 8) {
            Image(systemName: "car.fill")
                .font(.system(size: 16, weight: .bold))
            VStack(alignment: .leading, spacing: 1) {
                Text("RadarMap")
                    .font(.system(size: 13, weight: .bold))
                Text("Начать поездку")
                    .font(.system(size: 11))
                    .opacity(0.75)
            }
            Spacer(minLength: 0)
        }
        .widgetURL(TripLink.ownStartURL)
    }

    // MARK: - Форматирование

    private func kmParts(_ meters: Double) -> (value: String, unit: String) {
        if meters < 1000 { return ("\(Int(meters))", String(localized: "м")) }
        let value = meters / 1000
        let text = value < 100 ? NumberFormat.decimal(value)
            : value.formatted(.number.precision(.fractionLength(0)).locale(NumberFormat.locale))
        return (text, String(localized: "км"))
    }

    /// Километры. До сотни — с десятой, дальше без неё и с разделителем разрядов.
    private func km(_ meters: Double) -> String {
        let parts = kmParts(meters)
        return meters < 1000 ? String(format: String(localized: "%lld м"), Int(meters))
                             : String(format: String(localized: "%@ км"), parts.value)
    }

    private func kmWhole(_ meters: Double) -> String {
        String(format: String(localized: "%@ км"),
               (meters / 1000).formatted(.number.precision(.fractionLength(0)).locale(NumberFormat.locale)))
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0
            ? String(format: String(localized: "%lld ч %lld мин"), hours, minutes)
            : String(format: String(localized: "%lld мин"), minutes)
    }

}
