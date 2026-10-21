//
//  RadarStatsWidget.swift
//  RadarMapWidgets
//
//  Домашний виджет: километры недели, дни столбиками и привычная норма.
//  Снимок пишет приложение при уходе в фон и в конце каждой поездки;
//  собственных обновлений (и расхода батареи) у виджета нет.
//
//  Три правила, из которых сделан этот экран:
//  1. Герой — километры. Балл и риск штрафа никуда не делись, но ушли в
//     подпись: на виджет смотрят ради факта «сколько я наездил», а за оценкой
//     идут в Итоги. Кольцо заполняется к СВОЕЙ обычной неделе, а не к чужой
//     цели, которую никто не ставил.
//  2. Неделя важнее последней поездки. Виджет смотрят МЕЖДУ поездками, а
//     сразу после неё итог показывает сама карточка «Поездка сохранена».
//  3. Виджет не имеет права выдавать прошлую неделю за текущую. Если снимок
//     не про эту неделю, шапка честно называет его даты (см. WidgetWeek).
//

import WidgetKit
import SwiftUI
import UIKit

/// Палитра виджета — палитра А приложения (WidgetPalette, числа сверяет
/// тест с Theme). Виджет живёт на ЧУЖОМ экране, рядом с «Погодой» и
/// «Календарём», поэтому следует теме системы: белая карточка днём,
/// графитовая ночью — как панели самого приложения.
enum SW {
    /// Один цвет без темы — для всегда тёмных Live Activity и Dynamic Island.
    static func fixed(_ hex: UInt32) -> Color { Color(uiColor: rgb(hex)) }

    private static func color(_ pair: WidgetPalette.Pair) -> Color {
        Color(uiColor: UIColor { traits in
            rgb(traits.userInterfaceStyle == .dark ? pair.dark : pair.light)
        })
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static let accent = color(WidgetPalette.accent)
    /// Заливки под белым значком: текстовые accent/danger ночью светлые.
    static let accentFill = color(WidgetPalette.accentFill)
    static let cameraFill = color(WidgetPalette.dangerFill)
    static let camera = color(WidgetPalette.danger)
    static let success = color(WidgetPalette.success)
    static let warning = color(WidgetPalette.warning)

    static let bgTop = color(WidgetPalette.top)
    static let bgBottom = color(WidgetPalette.bottom)

    static let primary = color(WidgetPalette.primary)
    static let secondary = color(WidgetPalette.secondary)
    static let tertiary = color(WidgetPalette.tertiary)
    /// Подложки плиток и пустых столбиков — «чернила» темы, а не белый.
    static let ink = primary

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
        completion(Timeline(entries: [entry], policy: .after(WidgetWeek.nextRefresh(after: .now, updatedAt: entry.snapshot.updatedAt))))
    }
}

extension SharedDefaults.Snapshot {
    /// Красивая неделя для галереи и превью.
    static var demo: Self {
        .init(weekStart: Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start,
              weekDistance: 128_400, weekTrips: 9, weekRating: 67, weekFineRisk: 2_200_000,
              weekDeltaPercent: 12,
              dayDistances: [14_000, 22_000, 31_000, 9_000, 27_000, 0, 25_400],
              dayOverspeed: [false, false, true, false, true, false, false],
              topRiskPlace: "Юнусабад, Амира Темура", topRiskPasses: 4,
              usualWeekDistance: 115_000, monthDistance: 486_000,
              lifetimeDistance: 12_400_000, weekMovingDuration: 4.5 * 3600,
              updatedAt: .now)
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
        .description("Километры недели, дни и привычная норма")
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
            // Пустое и нерабочее состояния одинаковы на всех размерах: там
            // нечего раскладывать, есть только одна честная мысль.
            switch state {
            case .noAccess: message(icon: "exclamationmark.lock.fill",
                                    title: String(localized: "Нет доступа к данным"),
                                    detail: String(localized: "Откройте приложение — виджет оживёт"))
            case .empty:    message(icon: "car.fill",
                                    title: String(localized: "Готов к поездке"),
                                    detail: String(localized: "Начнём считать километры"))
            case .few, .full:
                Group {
                    switch family {
                    case .systemMedium: medium
                    case .systemLarge: large
                    default: small
                    }
                }
                // Тап по цифрам ведёт к ним же — в Итоги. Без ссылки виджет
                // просто открывал карту, и за неделей приходилось идти
                // вторым тапом. Пустое и нерабочее состояния ссылку не
                // получают: там нечего смотреть, а «Готов к поездке» зовёт
                // на карту, не в пустые Итоги.
                .widgetURL(URL(string: "radarmap://stats"))
            }
        }
    }

    /// Одна мысль на весь виджет. Ноль километров показывать нельзя: это не
    /// факт, а его отсутствие, и выглядит оно так же, как поломка.
    private func message(icon: String, title: String, detail: String) -> some View {
        // Без растяжки внутри: на большом размере Spacer развёл бы значок и
        // текст по разным углам, и одна короткая мысль превратилась бы в
        // чёрную дыру. Блок компактный, а по высоте его центрирует рамка.
        VStack(alignment: .leading, spacing: 10) {
            // Без доступа — предупреждение тоном (жёлтый с белым не читается),
            // приглашение — белый значок на синей заливке.
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(state == .noAccess ? SW.warning : .white)
                .frame(width: 36, height: 36)
                .background(state == .noAccess ? SW.warning.opacity(0.16) : SW.accentFill,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(SW.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(detail)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(SW.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Общее

    private var snapshot: SharedDefaults.Snapshot { entry.snapshot }
    private var isCurrentWeek: Bool {
        WidgetWeek.isCurrentWeek(snapshot.weekStart, now: entry.date)
    }
    private var state: WidgetState { WidgetWeek.state(snapshot) }
    private var hasData: Bool { state == .few || state == .full }
    private var isStale: Bool { WidgetWeek.isStale(snapshot.updatedAt, now: entry.date) }

    /// Даты недели снимка: «19–25 окт.», через месяц — «28 сент. – 4 окт.»
    /// (склейка «день–день месяц» давала «28–4 окт.»).
    private var weekDates: String? {
        guard let start = snapshot.weekStart else { return nil }
        let end = start.addingTimeInterval(6 * 86400)
        return (start..<end).formatted(.interval.day().month(.abbreviated)
                                        .locale(NumberFormat.locale))
    }

    /// То же цифрами — «28.09 – 04.10» — для шапки маленького размера рядом
    /// с кольцом. Прошлую неделю нельзя сократить до «Итоги»: это выдало бы
    /// её за текущую.
    private var weekDatesShort: String? {
        guard let start = snapshot.weekStart else { return nil }
        let end = start.addingTimeInterval(6 * 86400)
        return (start..<end).formatted(.interval.day().month(.twoDigits)
                                        .locale(NumberFormat.locale))
    }

    /// Шапка — как у экрана, куда ведёт тап: значок «Итогов» и неделя.
    /// Текущая неделя называется словами, любая другая — своими датами:
    /// показать прошлые цифры под словом «неделя» значит соврать.
    private func header(showsDates: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(SW.accent)
            // Рядом с кольцом маленького размера «Итоги недели» не влезает —
            // тогда просто «Итоги», а не «Итоги неде…».
            ViewThatFits(in: .horizontal) {
                headerTitle(isCurrentWeek ? String(localized: "Итоги недели") : weekDates)
                headerTitle(isCurrentWeek ? String(localized: "Итоги") : weekDatesShort)
            }
            Spacer(minLength: 4)
            if showsDates, isCurrentWeek, let weekDates {
                Text(weekDates)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(SW.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func headerTitle(_ text: String?) -> some View {
        Text(text ?? String(localized: "Итоги недели"))
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(SW.secondary)
            .lineLimit(1)
    }

    /// Кольцо — километры к СВОЕЙ обычной неделе, и только они. Внутри —
    /// значок: балл живёт рядом, отдельной меткой. Только когда норма есть.
    private func weekRing(diameter: CGFloat) -> some View {
        let progress = WidgetWeek.usualWeekProgress(distance: snapshot.weekDistance,
                                                    usual: snapshot.usualWeekDistance)
        return ZStack {
            Circle().stroke(SW.accent.opacity(0.16), lineWidth: diameter * 0.12)
            Circle()
                .trim(from: 0, to: max(0.03, progress))
                .stroke(SW.accent, style: StrokeStyle(lineWidth: diameter * 0.12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "car.fill")
                .font(.system(size: diameter * 0.28, weight: .bold))
                .foregroundStyle(SW.accent)
        }
        .frame(width: diameter, height: diameter)
    }

    /// Километры недели и дельта к прошлой — как в герое «Итогов». Дельта
    /// уходит, если рядом с числом ей нет места: обрезанная цифра хуже.
    /// На маленьком размере трёхзначные километры рядом с меткой не
    /// помещаются — там остаётся одно число (дельта есть на среднем и
    /// большом и в «Итогах»).
    private func hero(size: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                heroNumber(size: size)
                deltaBadge
            }
            heroNumber(size: size)
        }
    }

    private func heroNumber(size: CGFloat) -> some View {
        Text(km(snapshot.weekDistance))
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .foregroundStyle(SW.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    /// «↗ 12%» — та же метка, что в «Итогах»: рост синим, спад серым.
    @ViewBuilder private var deltaBadge: some View {
        if state == .full, let delta = snapshot.weekDeltaPercent, delta != 0 {
            let up = delta > 0
            let tint = up ? SW.accent : SW.secondary
            HStack(spacing: 2) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 9, weight: .heavy))
                Text("\(abs(delta))%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .fixedSize()
            // Стрелку VoiceOver читал именем символа, и не было сказано, к
            // чему проценты.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(String(format: String(localized: "%@%lld%% к прошлой неделе"),
                                            up ? "+" : "−", abs(delta))))
        }
    }

    /// Строка про норму: «как обычно» или насколько эта неделя отличается.
    /// Перепробег говорится словами, а не вторым витком кольца.
    private var usualLine: String? {
        let usual = snapshot.usualWeekDistance
        guard usual > 1000, snapshot.weekDistance > 0 else { return nil }
        let share = snapshot.weekDistance / usual
        if share >= 0.95 && share <= 1.05 { return String(localized: "как обычно") }
        // Только отличие. Раньше здесь повторялись километры героя — одно
        // число оказывалось сказано трижды на одном экране.
        let percent = Int((abs(share - 1) * 100).rounded())
        return share > 1
            ? String(format: String(localized: "на %lld%% больше обычного"), percent)
            : String(format: String(localized: "на %lld%% меньше обычного"), percent)
    }

    /// Подзаголовок героя: при полной неделе — отличие от нормы, при скудной —
    /// последняя поездка. Сравнивать не с чем, но факт уже есть.
    private var heroSubtitle: String? { heroSubtitle(compact: false) }

    /// `compact` — без километров последней поездки: на маленьком размере
    /// строка обрезалась ровно на них, а единственная поездка недели и так
    /// стоит крупно в герое.
    private func heroSubtitle(compact: Bool) -> String? {
        if state == .full { return usualLine }
        guard snapshot.lastTripDistance > 0, let at = snapshot.lastTripAt else { return nil }
        let when = at.formatted(.relative(presentation: .named).locale(NumberFormat.locale))
        return compact
            ? String(format: String(localized: "последняя — %@"), when)
            : String(format: String(localized: "последняя — %@, %@"), when, km(snapshot.lastTripDistance))
    }

    private func subtitle(_ size: CGFloat = 11, compact: Bool = false) -> some View {
        Text(heroSubtitle(compact: compact) ?? "")
            .font(.system(size: size, design: .rounded))
            .foregroundStyle(SW.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private var showsBars: Bool { WidgetWeek.showsBars(snapshot.dayDistances) }

    /// Подсказка «неделя только началась» — только про ТЕКУЩУЮ неделю с одним
    /// ездовым днём: под датами прошлой недели или на пятый день за рулём
    /// она была бы неправдой.
    private var showsWeekStartsHint: Bool { !showsBars && isCurrentWeek }

    /// Узкая подпись для среднего размера: справа от героя ~105–120 pt, и
    /// «сегодня 22 км · в среднем 18,3 км» туда не влезала.
    private var averageLine: String {
        let average = WidgetWeek.averagePerActiveDay(snapshot.dayDistances)
        guard average > 0 else { return "" }
        return String(format: String(localized: "в среднем %@"), km(average))
    }

    /// Подпись под столбиками: сегодня и средний ездовой день.
    private var daysLine: String {
        let average = WidgetWeek.averagePerActiveDay(snapshot.dayDistances)
        guard average > 0 else { return "" }
        if let today = WidgetWeek.todayIndex(snapshot.weekStart, now: entry.date),
           WidgetWeek.padded(snapshot.dayDistances)[today] > 0 {
            return String(format: String(localized: "сегодня %@ · в среднем %@"),
                          km(WidgetWeek.padded(snapshot.dayDistances)[today]), km(average))
        }
        return String(format: String(localized: "в среднем %@ за день"), km(average))
    }

    /// Оценка недели: балл цветом ступени и деньги. Под фактом, а не внутри
    /// кольца километров. Балл подписан — голое «67» читалось ничьим числом.
    /// Балл и деньги в строку, а если не влезают — в две, но не обрезанные
    /// («≈ 2,2 млн с…» на маленьком размере).
    private func verdict(size: CGFloat = 12) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                scoreChip(size: size)
                money(size: size).fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                scoreChip(size: size)
                money(size: size)
            }
        }
    }

    @ViewBuilder
    private func scoreChip(size: CGFloat) -> some View {
        let rating = snapshot.weekRating
        if rating >= 0 {
            Text(String(format: String(localized: "балл %@"), "\(rating)"))
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .foregroundStyle(SW.score(rating))
                .lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(SW.score(rating).opacity(0.14), in: Capsule())
                .fixedSize()
        }
    }

    /// Деньги недели: щит и «без штрафов» или риск. Красный — у значка и
    /// суммы, не у всей строки.
    private func money(size: CGFloat) -> some View {
        let risk = snapshot.weekFineRisk
        return HStack(spacing: 4) {
            Image(systemName: risk > 0 ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                .font(.system(size: size - 1, weight: .bold))
                .foregroundStyle(risk > 0 ? SW.camera : SW.success)
            Text(risk > 0 ? moneyText(risk) : String(localized: "Без штрафов"))
                .font(.system(size: size, weight: .bold, design: .rounded))
                .foregroundStyle(risk > 0 ? SW.camera : SW.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// Подпись мелким: поездки и время за рулём, как под героем «Итогов».
    /// Устаревший снимок говорит об этом прямо — иначе человек считает, что
    /// сегодня не ездил.
    private var caption: some View {
        let text: String
        if isStale {
            text = String(localized: "Откройте приложение — обновим")
        } else {
            var parts = [String(format: String(localized: "Поездок: %lld"), snapshot.weekTrips)]
            if snapshot.weekMovingDuration >= 60 {
                parts.append(duration(snapshot.weekMovingDuration) + " " + String(localized: "за рулём"))
            }
            text = parts.joined(separator: " · ")
        }
        return Text(text)
            .font(.system(size: 10, design: .rounded))
            .foregroundStyle(isStale ? SW.warning : SW.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    /// Семь дней недели столбиками. Высота — километры; синий — ездовой день
    /// (сегодня — полным цветом), красный — день со штрафуемым проездом,
    /// тонкая полоска — не ездили. Пустой день не исчезает: иначе неделя
    /// выглядит короче, чем была.
    private func bars(height: CGFloat, barWidth: CGFloat = 12) -> some View {
        let heights = WidgetWeek.barHeights(snapshot.dayDistances)
        // Единственный ездовой день красным превращает виджет в аварийный щит,
        // хотя случилось обычное: цвет несёт смысл только в сравнении.
        let marks = WidgetWeek.marksOverspeedDays(snapshot.dayDistances)
        let overspeed = marks ? WidgetWeek.padded(snapshot.dayOverspeed)
                              : [Bool](repeating: false, count: 7)
        let labels = WidgetWeek.dayLabels()
        let today = WidgetWeek.todayIndex(snapshot.weekStart, now: entry.date)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<7, id: \.self) { index in
                let driven = heights[index] > 0
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: barWidth / 3, style: .continuous)
                        .fill(overspeed[index] ? SW.camera
                              : !driven ? SW.ink.opacity(0.12)
                              : today == index ? SW.accent : SW.accent.opacity(0.45))
                        .frame(width: barWidth, height: max(3, heights[index] * height))
                    Text(labels[index])
                        .font(.system(size: 9, weight: today == index ? .heavy : .regular,
                                      design: .rounded))
                        .foregroundStyle(today == index ? SW.primary : SW.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height + 15, alignment: .bottom)
    }

    /// Пока неделя не набралась, столбиков нет — и место говорит почему,
    /// вместо пустоты, которая выглядит поломкой.
    /// `compact` — для узкой правой половины среднего размера: без значка,
    /// иначе заголовок ломался на три строки, а пояснение обрезалось.
    private func weekStartsHint(compact: Bool = false) -> some View {
        HStack(spacing: 8) {
            if !compact {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SW.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Неделя только началась")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(SW.primary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Дни столбиками — со второго дня за рулём")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(SW.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(SW.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Размеры

    /// Маленький: километры, норма, балл и деньги. Кольцо — в шапке справа.
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                header(showsDates: false)
                // Прошлой неделе шапка нужнее кольца: даты рядом с ним не
                // помещались даже цифрами («28.09—0…»).
                if state == .full, isCurrentWeek { weekRing(diameter: 30) }
            }
            Spacer(minLength: 4)
            hero(size: 28)
            if heroSubtitle != nil { subtitle(compact: true) }
            Spacer(minLength: 6)
            verdict(size: 11)
            // Поездки и время — уже на среднем размере и в «Итогах»; здесь
            // строка нужна, только чтобы сказать, что цифры старые.
            if isStale { caption.padding(.top, 4) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Средний: слева километры и оценка, справа их форма по дням.
    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(showsDates: true)
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    hero(size: 26)
                    if heroSubtitle != nil { subtitle() }
                    Spacer(minLength: 6)
                    verdict(size: 11)
                    caption.padding(.top, 4)
                }
                // 160: «балл 67» и «≈ 2,2 млн сум» в строку, столбикам
                // остаётся ~115 pt и на SE (виджет 321 pt).
                .frame(width: 160, alignment: .leading)

                // Столбики имеют смысл с двух ездовых дней: один столбик и
                // шесть прочерков — это не форма недели, а её отсутствие.
                if showsBars {
                    VStack(spacing: 4) {
                        bars(height: 52, barWidth: 11)
                        Text(averageLine)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(SW.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                } else if showsWeekStartsHint {
                    weekStartsHint(compact: true)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Большой: «Итоги недели» целиком — километры к норме, оценка, дни,
    /// перспектива (месяц, всё время, за рулём) и одно место, где теряете.
    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(showsDates: true)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    hero(size: 36)
                    if heroSubtitle != nil { subtitle(12) }
                }
                Spacer(minLength: 0)
                if state == .full { weekRing(diameter: 50) }
            }
            verdict(size: 13)
            if showsBars {
                VStack(spacing: 5) {
                    bars(height: 58, barWidth: 16)
                    Text(daysLine)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(SW.secondary)
                        .lineLimit(1)
                }
            } else if showsWeekStartsHint {
                weekStartsHint()
            }
            HStack(spacing: 0) {
                tile(km(snapshot.monthDistance), String(localized: "за месяц"))
                tileDivider
                // «Всего» — только когда это не тот же месяц другими
                // словами: у нового пользователя счёт начался с установки.
                if WidgetWeek.showsLifetime(month: snapshot.monthDistance,
                                            lifetime: snapshot.lifetimeDistance) {
                    tile(km(snapshot.lifetimeDistance), String(localized: "всего"))
                } else {
                    tile("\(WidgetWeek.activeDayCount(snapshot.dayDistances))",
                         String(localized: "дней за рулём"))
                }
                tileDivider
                tile(duration(snapshot.weekMovingDuration), String(localized: "за рулём"))
            }
            .padding(.vertical, 8)
            .background(SW.ink.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let place = snapshot.topRiskPlace, snapshot.topRiskPasses > 0 {
                riskRow(place: place, passes: snapshot.topRiskPasses)
            }
            Spacer(minLength: 0)
            caption
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(SW.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(SW.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private var tileDivider: some View {
        Rectangle().fill(SW.ink.opacity(0.10)).frame(width: 1, height: 24)
    }

    /// Где теряете баллы — то же место, что в «Итогах», одной строкой.
    private func riskRow(place: String, passes: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(SW.cameraFill, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("Где теряете баллы")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(SW.secondary)
                Text(place)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(SW.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(String(format: String(localized: "×%lld"), passes))
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(SW.camera)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(SW.camera.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
        }
        .widgetURL(URL(string: "radarmap://start-trip"))
    }

    private var lockRectangular: some View {
        HStack(spacing: 8) {
            Image(systemName: "car.fill")
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

    // MARK: - Форматирование

    /// Километры. До сотни — с десятой (12,4 км читается точнее, чем 12),
    /// дальше без неё и с разделителем разрядов: «12400.0 km» в плитке
    /// «всего» выглядело сырым числом из отладки, а не пробегом.
    private func km(_ meters: Double) -> String {
        if meters < 1000 { return String(format: String(localized: "%lld м"), Int(meters)) }
        let value = meters / 1000
        guard value < 100 else {
            return String(format: String(localized: "%@ км"),
                          value.formatted(.number.precision(.fractionLength(0)).locale(NumberFormat.locale)))
        }
        // Общим правилом: `String(format:)` без локали ставил точку — «12.4 км».
        return String(format: String(localized: "%@ км"), NumberFormat.decimal(value))
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0
            ? String(format: String(localized: "%lld ч %lld мин"), hours, minutes)
            : String(format: String(localized: "%lld мин"), minutes)
    }

    /// Сумы без копеек и по-короткому: на виджете места нет. Миллионы — через
    /// общее правило чисел: `%.1f` ставил точку посреди русского текста.
    private func moneyText(_ amount: Double) -> String {
        if amount >= 1_000_000 {
            return "≈ " + String(format: String(localized: "%@ млн сум"),
                                 NumberFormat.decimal(amount / 1_000_000))
        }
        return String(format: String(localized: "≈ %lld тыс сум"), Int(amount / 1000))
    }
}
