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

enum SW {
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
        RadarStatsEntry(date: .now, snapshot: .demo)
    }

    func getSnapshot(in context: Context, completion: @escaping (RadarStatsEntry) -> Void) {
        // Витрина галереи — живая неделя, а не нули: там виджет выбирают.
        completion(RadarStatsEntry(date: .now,
                                   snapshot: context.isPreview ? .demo : SharedDefaults.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RadarStatsEntry>) -> Void) {
        let entry = RadarStatsEntry(date: .now, snapshot: SharedDefaults.read())
        // Час — не ради новых цифр (их приносит приложение), а чтобы виджет
        // сам заметил смену недели и перестал называть прошлую текущей.
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
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
                switch family {
                case .systemMedium: medium
                case .systemLarge: large
                default: small
                }
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
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(state == .noAccess ? SW.warning : SW.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(detail)
                    .font(.system(size: 11, design: .rounded))
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

    /// Шапка. Текущая неделя называется «Неделей», любая другая — своими
    /// датами: показать прошлые цифры под словом «Неделя» значит соврать.
    private var weekTitle: String {
        guard let start = snapshot.weekStart else { return String(localized: "Неделя") }
        guard !isCurrentWeek else { return String(localized: "Неделя") }
        let end = start.addingTimeInterval(6 * 86400)
        return start.formatted(.dateTime.day()) + "–"
            + end.formatted(.dateTime.day().month(.abbreviated))
    }

    /// Кольцо — километры к СВОЕЙ обычной неделе, и только они. Раньше внутри
    /// стоял балл, и элемент нёс два разных смысла сразу: на макете это читалось
    /// умно, на экране — как «55 процентов чего-то». Внутри теперь значок, балл
    /// живёт внизу рядом с деньгами. Показываем только когда норма есть.
    private func weekRing(diameter: CGFloat) -> some View {
        let progress = WidgetWeek.usualWeekProgress(distance: snapshot.weekDistance,
                                                    usual: snapshot.usualWeekDistance)
        return ZStack {
            Circle().stroke(SW.accent.opacity(0.18), lineWidth: diameter * 0.11)
            Circle()
                .trim(from: 0, to: max(0.03, progress))
                .stroke(SW.accent, style: StrokeStyle(lineWidth: diameter * 0.11, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "car.fill")
                .font(.system(size: diameter * 0.3, weight: .bold))
                .foregroundStyle(SW.accent)
        }
        .frame(width: diameter, height: diameter)
    }

    /// Балл и деньги одной строкой — оценка недели там, где ей место: под
    /// фактом, а не внутри кольца километров.
    private func verdictLine(size: CGFloat = 13) -> some View {
        let rating = snapshot.weekRating
        return HStack(spacing: 7) {
            if rating >= 0 {
                Text("\(rating)")
                    .font(.system(size: size + 2, weight: .heavy, design: .rounded))
                    .foregroundStyle(SW.score(rating))
            }
            moneyLine(size: size)
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
    private var heroSubtitle: String? {
        if state == .full { return usualLine }
        guard snapshot.lastTripDistance > 0, let at = snapshot.lastTripAt else { return nil }
        return String(format: String(localized: "последняя — %@, %@"),
                      at.formatted(.relative(presentation: .named)), km(snapshot.lastTripDistance))
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

    /// Деньги недели одной строкой: щит и «без штрафов» или риск.
    private func moneyLine(size: CGFloat = 13) -> some View {
        let risk = snapshot.weekFineRisk
        return HStack(spacing: 5) {
            Image(systemName: risk > 0 ? "exclamationmark.shield.fill"
                                       : "checkmark.shield.fill")
                .font(.system(size: size - 1, weight: .bold))
                .foregroundStyle(risk > 0 ? SW.camera : SW.success)
            Text(risk > 0 ? money(risk) : String(localized: "Без штрафов"))
                .font(.system(size: size, weight: .bold, design: .rounded))
                .foregroundStyle(risk > 0 ? SW.camera : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// Подпись мелким: поездки и дельта к прошлой неделе. Устаревший снимок
    /// говорит об этом прямо — иначе человек считает, что сегодня не ездил.
    private var caption: String {
        if WidgetWeek.isStale(snapshot.updatedAt, now: entry.date) {
            return String(localized: "Откройте приложение — обновим")
        }
        var parts = [String(format: String(localized: "Поездок: %lld"), snapshot.weekTrips)]
        if state == .full, let delta = snapshot.weekDeltaPercent, delta != 0 {
            parts.append(String(format: String(localized: "%@%lld%% к прошлой"),
                                delta > 0 ? "+" : "−", abs(delta)))
        }
        return parts.joined(separator: " · ")
    }

    /// Семь дней недели столбиками. Высота — километры, красный — день, в
    /// который был штрафуемый проезд, тонкая полоска — не ездили. Пустой день
    /// не исчезает: иначе неделя выглядит короче, чем была.
    private func bars(height: CGFloat) -> some View {
        let heights = WidgetWeek.barHeights(snapshot.dayDistances)
        // Единственный ездовой день красным превращает виджет в аварийный щит,
        // хотя случилось обычное: цвет несёт смысл только в сравнении.
        let marks = WidgetWeek.marksOverspeedDays(snapshot.dayDistances)
        let overspeed = marks ? WidgetWeek.padded(snapshot.dayOverspeed)
                              : [Bool](repeating: false, count: 7)
        let labels = WidgetWeek.dayLabels()
        let today = WidgetWeek.todayIndex(snapshot.weekStart, now: entry.date)
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(0..<7, id: \.self) { index in
                VStack(spacing: 4) {
                    // Столбик уже ячейки: на семь дней ячейка ~40 pt, и во всю
                    // ширину столбик читается блоком, а не графиком.
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(overspeed[index] ? SW.camera : Color.white.opacity(0.28))
                        .frame(width: 14, height: max(3, heights[index] * height))
                        .overlay {
                            if today == index {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .stroke(.white.opacity(0.85), lineWidth: 1.5)
                            }
                        }
                    Text(labels[index])
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(today == index ? .white : SW.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height + 14, alignment: .bottom)
    }

    // MARK: - Размеры

    /// Герой — километры. Балл и деньги никуда не делись, но перестали спорить
    /// за взгляд: на виджет смотрят ради факта («сколько я наездил»), а за
    /// оценкой идут в Итоги.
    private func hero(size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(weekTitle)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(SW.secondary)
                .lineLimit(1)
            Text(km(snapshot.weekDistance))
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let heroSubtitle {
                Text(heroSubtitle)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(SW.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    /// Маленький: километры, кольцо к обычной неделе и одна приглушённая
    /// строка про деньги. Без поездок — приглашение, а не нули.
    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                hero(size: 26)
                Spacer(minLength: 0)
                if state == .full { weekRing(diameter: 38) }
            }
            Spacer(minLength: 0)
            verdictLine()
            Text(caption)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(SW.secondary.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Средний: слева километры, справа их форма по дням.
    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    hero(size: 24)
                    Spacer(minLength: 0)
                    if state == .full { weekRing(diameter: 36) }
                }
                Spacer(minLength: 0)
                verdictLine()
                Text(caption)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(SW.secondary.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 134, alignment: .leading)

            // Столбики имеют смысл с двух ездовых дней: один столбик и шесть
            // прочерков — это не форма недели, а её отсутствие.
            if state == .full {
                VStack(spacing: 5) {
                    bars(height: 56)
                    Text(daysLine)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(SW.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            } else {
                Text("Неделя только началась")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(SW.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Большой: километры в перспективе — неделя, месяц, всё время. И только
    /// последней строкой то, по чему можно что-то сделать завтра.
    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                hero(size: 34)
                Spacer(minLength: 0)
                if state == .full {
                    weekRing(diameter: 50)
                }
            }
            verdictLine(size: 15)
            if state == .full {
                bars(height: 60)
                Text(daysLine)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(SW.secondary)
            }
            if hasData {
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
                .padding(.vertical, 9)
                .background(.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let place = snapshot.topRiskPlace, snapshot.topRiskPasses > 0 {
                    riskRow(place: place, passes: snapshot.topRiskPasses)
                }
            }
            if state == .full { Spacer(minLength: 0) }
        }
        // Пока неделя не набралась, содержимого на большой размер не хватает.
        // Прижимать его к верху значит показать пустую нижнюю половину и
        // выглядеть сломанным — центрируем, и разрежённость читается замыслом.
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: state == .full ? .topLeading : .leading)
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(SW.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var tileDivider: some View {
        Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 24)
    }

    private func riskRow(place: String, passes: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(SW.camera)
            VStack(alignment: .leading, spacing: 1) {
                Text(place)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(String(format: String(localized: "%lld проезда с превышением — здесь теряете больше всего"),
                            passes))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(SW.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(SW.camera.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    // MARK: - Форматирование

    private func km(_ meters: Double) -> String {
        meters < 1000 ? String(format: String(localized: "%lld м"), Int(meters))
                      : String(format: String(localized: "%.1f км"), meters / 1000)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0
            ? String(format: String(localized: "%lld ч %lld мин"), hours, minutes)
            : String(format: String(localized: "%lld мин"), minutes)
    }

    /// Сумы без копеек и по-короткому: на виджете места нет.
    private func money(_ amount: Double) -> String {
        if amount >= 1_000_000 {
            return String(format: String(localized: "≈ %.1f млн сум"), amount / 1_000_000)
        }
        return String(format: String(localized: "≈ %lld тыс сум"), Int(amount / 1000))
    }
}
