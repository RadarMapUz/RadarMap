//
//  ItogiAnswerCard.swift
//  RadarMap
//
//  Карточка-ответ «Итогов» — вариант A «Неделя одним взглядом» (аудит 05.11,
//  выбор владельца). Одно главное число — рейтинг «из 100», — и сразу за ним
//  ответ «за что сняли». Километры, поездки и время — полосой одного кегля
//  ниже: до 05.11 «65 рейтинг» и «142 км» были одинаково крупными, и глаз не
//  знал, что из них главное, а «из 100» нигде не было.
//
//  Порядок: рейтинг → за что сняли → факты → неделя столбиками → «Могут
//  прийти». Мало данных — без кольца, одной честной строкой (как `few` у
//  виджета). У дня рейтинга нет: его баллы — в строках поездок.
//
//  Вьюха без окружения: всё приходит готовым из ItogiScreen — по ней же
//  снимаются превью.
//

import SwiftUI

struct ItogiAnswerCard: View {
    let itogi: ItogiScreen
    let period: StatsPeriod
    /// Разбор рейтинга.
    var onRating: () -> Void = {}
    /// «Штрафы» на вкладке «Могут прийти».
    var onFines: () -> Void = {}
    /// Выбранный на графике день.
    var onOpenDay: ((Date) -> Void)? = nil

    private var summary: PeriodSummary { itogi.summary }

    var body: some View {
        VStack(spacing: 12) {
            ratingCard
            if !itogi.bars.isEmpty, summary.distance > 0 {
                ItogiPeriodChart(bars: itogi.bars, unit: itogi.barUnit, average: itogi.averageKm,
                                 title: totalTitle, value: Formatting.distance(summary.distance),
                                 delta: summary.distanceChange.map { Self.distanceChangeText($0, period: period) },
                                 footer: footerText,
                                 onOpenDay: itogi.barUnit == .hour ? nil : onOpenDay)
                    .statCard()
            }
            if let money = moneyLine {
                Button(action: onFines) {
                    ItogiCardRow(symbol: money.symbol, tint: money.tint, title: money.title,
                                 caption: money.caption, chevron: true)
                }
                .buttonStyle(PressableStyle(.row))
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text("Открыть штрафы"))
                .statCard(padding: 0)
            }
        }
    }

    @ViewBuilder private var ratingCard: some View {
        if case .none = itogi.availability {
            EmptyView()
        } else if case .notForPeriod = itogi.availability {
            EmptyView()
        } else {
            ratingBlock.statCard(padding: 0)
        }
    }

    private var totalTitle: String {
        switch period {
        case .day:   return String(localized: "Всего за день")
        case .week:  return String(localized: "Всего за неделю")
        case .month: return String(localized: "Всего за месяц")
        }
    }

    /// «19 поездок · 15 ч 1 мин за рулём» — одной строкой, поэтому не обрезается.
    private var footerText: String {
        "\(summary.trips)\u{00A0}" + Formatting.tripsLabel(summary.trips) + " · "
            + Formatting.duration(summary.movingDuration) + " " + String(localized: "за рулём")
    }

    // MARK: - Рейтинг

    @ViewBuilder private var ratingBlock: some View {
        switch itogi.availability {
        case .shown(let rating):
            Button(action: onRating) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 16) {
                        RatingRing(rating: rating)
                            .frame(width: 88, height: 88)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Self.ratingTitle(period))
                                .font(.rounded(12, .medium))
                                .foregroundStyle(Theme.textSecondary)
                            Text(ItogiRating.Level(rating: rating).title)
                                .font(.rounded(19, .bold))
                                .foregroundStyle(Theme.score(rating))
                            if let words = ItogiRating.deltaWords(summary.ratingDelta, period: period) {
                                Text(words)
                                    .font(.rounded(12, .semibold))
                                    .foregroundStyle((summary.ratingDelta ?? 0) > 0 ? Theme.success : Theme.danger)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityHidden(true)
                    }
                    if let taken = takenText(rating: rating) {
                        Text(taken)
                            .font(.rounded(15, .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(.card))
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("За что сняли баллы"))
        case .tooFew:
            ItogiCardRow(symbol: Icon.ratingPending, tint: Theme.textSecondary,
                         title: Self.tooFewTitle(period),
                         caption: String(format: String(localized: "Рейтинг появится после %1$lld поездок и %2$@"),
                                         AppConfig.itogiRatingMinTrips,
                                         Formatting.distance(AppConfig.itogiRatingMinMeters)))
        case .notForPeriod, .none:
            EmptyView()
        }
    }

    static func ratingTitle(_ period: StatsPeriod) -> String {
        switch period {
        case .month: return String(localized: "Рейтинг месяца")
        case .week, .day: return String(localized: "Рейтинг недели")
        }
    }

    static func tooFewTitle(_ period: StatsPeriod) -> String {
        period == .month ? String(localized: "Пока мало поездок для рейтинга месяца")
                         : String(localized: "Пока мало поездок для рейтинга недели")
    }

    /// «Сняли 35 баллов: камеры −15, резкая езда −20». Без разложения (записи
    /// вычищены) — просто сколько сняли; 100 — ничего не сняли.
    private func takenText(rating: Int) -> String? {
        let total = 100 - rating
        guard total > 0 else { return String(localized: "Ничего не сняли — так держать") }
        guard let taken = itogi.taken else {
            return String(localized: "Сняли \(total) баллов — подробнее в разборе")
        }
        var parts: [String] = []
        if taken.cameras > 0 {
            parts.append(String(format: String(localized: "камеры %@"), Formatting.points(taken.cameras)))
        }
        if taken.smoothness > 0 {
            parts.append(String(format: String(localized: "резкая езда %@"), Formatting.points(taken.smoothness)))
        }
        return String(format: String(localized: "Сняли %1$@: %2$@"),
                      String(localized: "\(total) баллов"), parts.joined(separator: ", "))
    }

    // MARK: - Сравнение

    /// «+18 км к тем же дням прошлой недели» — процент только у сопоставимых
    /// периодов (PeriodSummary.distanceChange).
    static func distanceChangeText(_ change: DistanceChange, period: StatsPeriod) -> String {
        let versus = change.soFar ? period.versusPreviousSoFar : period.versusPrevious
        if let percent = change.percent {
            return String(format: String(localized: "%1$@ %% %2$@"), Formatting.signed(percent), versus)
        }
        let sign = change.meters >= 0 ? "+" : "−"
        return String(format: String(localized: "%1$@ %2$@"),
                      sign + Formatting.distance(abs(change.meters)), versus)
    }

    // MARK: - Деньги

    /// «Могут прийти 2 штрафа ≈ 2,2 млн» — оценка, а не счёт (аудит, п. 3):
    /// «Возможные штрафы» читались суммой к оплате. Подпись говорит, по чему
    /// оценено, и прямо — что это не постановления.
    private var moneyLine: (symbol: String, tint: Color, title: String, caption: String)? {
        let judged = summary.cleanPasses + summary.overPasses
        guard judged > 0 else { return nil }
        let over = summary.overPasses
        let passes = ItogiWords.overOfPasses(over: over, passes: judged)
        if over > 0, summary.fineRisk > 0 {
            return (Icon.fines, Theme.danger,
                    String(format: String(localized: "Могут прийти %1$@ ≈ %2$@"),
                           ItogiWords.fines(over), Formatting.unbreakable(Formatting.money(summary.fineRisk))),
                    String(format: String(localized: "оценка: %@ · не постановления"), passes))
        }
        if over > 0 {
            // Все превышения уже отмечены «пришёл / не пришёл».
            return (Icon.fines, Theme.textSecondary, String(localized: "Штрафы периода отмечены"), passes)
        }
        if summary.edgePasses > 0 {
            return (PassVerdict.edge.symbol, PassVerdict.edge.tint,
                    String(localized: "Штрафуемых превышений нет"),
                    String(format: String(localized: "на грани: %1$lld из %2$lld проездов — штрафа обычно нет, балл снят"),
                           summary.edgePasses, judged))
        }
        return (PassVerdict.clean.symbol, PassVerdict.clean.tint,
                String(localized: "Штрафуемых превышений нет"),
                String(localized: "Пока без превышений: \(judged) проездов"))
    }
}

// MARK: - Строка внутри карточки

/// Строка-продолжение карточки: значок в той же плашке, что у строк
/// разделов (IconBadge 30), заголовок 15, подпись 12, шеврон по желанию.
struct ItogiCardRow: View {
    let symbol: String
    var tint: Color = Theme.textSecondary
    let title: String
    var caption: String? = nil
    var chevron = false

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption {
                    Text(caption)
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: Theme.controlSize)
        .contentShape(Rectangle())
    }
}

// MARK: - Слова с числом

/// Фразы с двумя числами — формы слов по `PluralRu`, как у
/// `Formatting.camerasLabel`: plural-вариация каталога обязана печатать
/// число, а здесь их два в одной фразе.
enum ItogiWords {
    /// «2 превышения из 14 проездов».
    static func overOfPasses(over: Int, passes: Int) -> String {
        String(format: String(localized: "%1$lld %2$@ из %3$lld %4$@"),
               over, overLabel(over), passes, passesGenitive(passes))
    }

    /// «2 штрафа».
    static func fines(_ count: Int) -> String {
        let word: String
        switch PluralRu.form(count) {
        case .one:  word = String(localized: "штраф")
        case .few:  word = String(localized: "штрафа")
        case .many: word = String(localized: "штрафов")
        }
        return "\(count)\u{00A0}" + word
    }

    static func overLabel(_ count: Int) -> String {
        switch PluralRu.form(count) {
        case .one:  return String(localized: "превышение")
        case .few:  return String(localized: "превышения")
        case .many: return String(localized: "превышений")
        }
    }

    /// «по 1 проезду», «по 14 проездам».
    static func passesDative(_ count: Int) -> String {
        "\(count)\u{00A0}" + (PluralRu.form(count) == .one ? String(localized: "проезду")
                                                          : String(localized: "проездам"))
    }

    /// После «из»: «из 1 проезда», «из 14 проездов».
    static func passesGenitive(_ count: Int) -> String {
        PluralRu.form(count) == .one ? String(localized: "проезда") : String(localized: "проездов")
    }

    /// «3 раза» — плюрализация «раз» (аудит: «4 раз» в отметках).
    static func times(_ count: Int) -> String {
        let word: String
        switch PluralRu.form(count) {
        case .one, .many: word = String(localized: "раз")
        case .few:        word = String(localized: "раза")
        }
        return "\(count)\u{00A0}" + word
    }
}

#if DEBUG
// MARK: - Превью

/// Демо-неделя для превью «Итогов»: девять поездок, два штрафуемых проезда у
/// «Юнусабада», один «на грани», резкая езда в пятницу — те же числа, что в
/// листе аудита (65 из 100, −35).
enum ItogiPreviewData {
    static let now = Date()

    static func pass(_ camera: Int, _ place: String, _ speed: Double, limit: Int = 60,
                     at date: Date) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: camera, typeRaw: "Стационар радар", location: place,
                     speedKmh: speed, date: date, lat: 41.31, lon: 69.28, limitKmh: limit)
    }

    static var records: [TripRecord] {
        let calendar = Calendar.current
        let week = StatsPeriod.week.interval(containing: now)
        var result: [TripRecord] = []
        let plan: [(day: Int, hour: Int, km: Double, score: Double, passes: [(Int, String, Double)])] = [
            (0, 8, 13.8, 96, [(1, "Амира Темура", 58)]),
            (0, 18, 14.2, 55, [(2, "Юнусабад", 88), (3, "Ниёзбек йули", 64)]),
            (1, 9, 21.0, 70, [(2, "Юнусабад", 78)]),
            (2, 8, 12.4, 90, [(1, "Амира Темура", 61)]),
            (3, 19, 30.1, 62, [(4, "Малая кольцевая", 66)]),
            (4, 8, 13.8, 98, []),
            (4, 18, 14.6, 80, [(1, "Амира Темура", 57)]),
            (5, 11, 9.2, 100, []),
            (6, 13, 12.9, 84, [(3, "Ниёзбек йули", 59)]),
        ]
        for item in plan {
            guard let day = calendar.date(byAdding: .day, value: item.day, to: week.start),
                  let start = calendar.date(byAdding: .hour, value: item.hour, to: day),
                  start < now else { continue }
            let passes = item.passes.map { pass($0.0, $0.1, $0.2, at: start.addingTimeInterval(600)) }
            result.append(TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                                     endedAt: start.addingTimeInterval(item.km * 170),
                                     distanceMeters: item.km * 1000, maxSpeedKmh: 92,
                                     passed: passes, score: item.score))
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }

    static var screen: ItogiScreen {
        let history = records
        return ItogiScreen.build(days: TripDayBook.rebuilt(from: history), history: history,
                                 period: .week, anchor: now, now: now)
    }

    /// Одна короткая поездка — «пока мало».
    static var fewScreen: ItogiScreen {
        let start = now.addingTimeInterval(-3_600)
        let one = [TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                              endedAt: start.addingTimeInterval(1_200), distanceMeters: 9_400,
                              maxSpeedKmh: 62, passed: [], score: 100)]
        return ItogiScreen.build(days: TripDayBook.rebuilt(from: one), history: one,
                                 period: .week, anchor: now, now: now)
    }
}

/// Превью-обёртка: SE (375), язык и тема — как у остальных превью проекта.
struct ItogiPreviewFrame<Content: View>: View {
    let locale: String
    let scheme: ColorScheme
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 16) { content }
                .padding(16)
        }
        .frame(width: 375, height: 812)
        .background(Theme.background)
        .environment(\.locale, Locale(identifier: locale))
        .environment(\.colorScheme, scheme)
    }
}

#Preview("Карточка-ответ · SE · ru · день") {
    ItogiPreviewFrame(locale: "ru", scheme: .light) {
        ItogiAnswerCard(itogi: ItogiPreviewData.screen, period: .week)
        ItogiAnswerCard(itogi: ItogiPreviewData.fewScreen, period: .week)
    }
}

#Preview("Карточка-ответ · SE · uz · ночь") {
    ItogiPreviewFrame(locale: "uz", scheme: .dark) {
        ItogiAnswerCard(itogi: ItogiPreviewData.screen, period: .week)
        ItogiAnswerCard(itogi: ItogiPreviewData.fewScreen, period: .week)
    }
}
#endif
