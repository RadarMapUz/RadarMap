//
//  RatingDetailSheet.swift
//  RadarMap
//
//  Разбор рейтинга периода — вариант A аудита 05.11 «Что сняли и как вернуть».
//
//  Водитель спрашивает здесь две вещи: за что сняли и что сделать. До 05.11
//  первый экран отвечал арифметикой разработчика — «100 − 35 = 65»,
//  «удержано / потеряно», «недобор балла × доля пути», «Норма и динамика»,
//  «Понять данные». Теперь первый экран — без формул:
//
//      «65 из 100», уровень словом, «обычно у вас 66–76», сдвиг словами
//      «Из 100 сняли 35»: резкая езда −20 ›, камеры −15 ›
//      «Как вернуть баллы»: 1–2 совета со своим «что было бы»
//      «Какие поездки потянули вниз · длинные весят больше» ›
//      «Как считаем рейтинг» › — шкала, формула, полоса вкладов, динамика
//
//  Стек в четыре уровня сохранён (6.10): период → вклады → поездка → проезд.
//  «Назад» всегда возвращает туда, откуда пришли, а не на «Итоги».
//
//  Все числа — из RatingBreakdown.screen, посчитанного вне main.
//

import SwiftUI
import Charts

/// Куда можно провалиться из разбора. Значения Hashable и лёгкие — путь живёт
/// по идентификаторам, а сами записи достаются из истории в момент показа.
private enum RatingRoute: Hashable {
    case allContributions
    case cameras
    case method
    case trip(Double)
    case pass(trip: Double, pass: UUID)
}

struct RatingDetailSheet: View {
    let summary: PeriodSummary
    let period: StatsPeriod
    /// Окно, за которое показан рейтинг: по нему считается всё разложение.
    var interval: DateInterval = DateInterval(start: .distantPast, end: Date())
    /// Якорь окна — по нему берутся прошлые такие же окна для «вашей нормы».
    var anchor: Date = Date()

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var path: [RatingRoute] = []
    @State private var data = RatingScreen()
    /// «Что было бы» для самой дорогой камеры — из .task, не из body.
    @State private var cameraRating: Int?
    /// Поездка, где резкая езда сняла больше всего.
    @State private var roughest: TripRecord?
    @State private var chartMode: ChartMode = .days

    /// Ключ пересчёта: окно и состав истории.
    private struct DataKey: Equatable {
        let period: StatsPeriod
        let anchor: Date
        let trips: Int
        let days: Int
        let latest: Double?
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    hero
                    takenGroup
                    tipsGroup
                    moreGroup
                }
                .padding(16)
            }
            .backport.scrollEdgeEffectStyle(.hard, for: .top)
            .background(Theme.background)
            .navigationTitle(Text(ItogiAnswerCard.ratingTitle(period)))
            .onAppear { env.usage.noteScreen("rating") }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
            .navigationDestination(for: RatingRoute.self) { destination($0) }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: DataKey(period: period, anchor: anchor, trips: env.trip.history.count,
                          days: env.trip.days.count, latest: env.trip.history.first?.id)) {
            let history = env.trip.history
            let days = env.trip.days
            let window = interval
            data = await RatingBreakdown.screen(records: history, days: days,
                                                period: period, anchor: anchor)
            cameraRating = data.sources.cameras.first.flatMap {
                ItogiRating.ratingIfCameraClean(cameraID: $0.id, records: history, days: days, in: window)
            }
            roughest = ItogiRating.roughestTrip(records: history, in: window)
        }
    }

    // MARK: - Уровни разбора

    @ViewBuilder private func destination(_ route: RatingRoute) -> some View {
        switch route {
        case .allContributions:
            AllContributionsView(items: data.contributions, period: period,
                                 days: env.trip.days) { path.append(.trip($0)) }
        case .cameras:
            camerasPage
        case .method:
            methodPage
        case .trip(let id):
            if let record = env.trip.history.first(where: { $0.id == id }) {
                TripDetailContent(record: record, rating: ratingContext(for: id),
                                  onOpenPass: { path.append(.pass(trip: id, pass: $0.id)) })
                    .navigationTitle(Formatting.tripTitle(record.startedAt))
                    .navigationBarTitleDisplayMode(.inline)
            }
        case .pass(let tripID, let passID):
            if let record = env.trip.history.first(where: { $0.id == tripID }),
               let pass = record.passed.first(where: { $0.id == passID }) {
                PassDetailView(pass: pass, track: record.trackPoints, record: record,
                               days: env.trip.days, interval: interval, period: period)
            }
        }
    }

    /// Связь поездки с рейтингом периода — чтобы на её экране было видно, что
    /// именно она отняла у общей цифры.
    private func ratingContext(for id: Double) -> TripRatingContext? {
        guard let item = data.contributions.first(where: { $0.id == id && $0.isTrip })
        else { return nil }
        return TripRatingContext(contribution: item, periodCaption: period.caption,
                                 periodDistance: summary.distance, period: period)
    }

    // MARK: - Шапка

    private var hero: some View {
        HStack(spacing: 16) {
            if let rating = summary.rating {
                RatingRing(rating: rating)
                    .frame(width: 92, height: 92)
            } else {
                IconBadge(symbol: Icon.ratingPending, tint: Theme.textSecondary, size: 92)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(period.rangeTitle(containing: anchor))
                    .font(.rounded(12, .medium))
                    .foregroundStyle(Theme.textSecondary)
                if let rating = summary.rating {
                    Text(ItogiRating.Level(rating: rating).title)
                        .font(.rounded(19, .bold))
                        .foregroundStyle(Theme.score(rating))
                    if let usual = ItogiRating.baselineWords(data.baseline, rating: rating, period: period) {
                        Text(usual)
                            .font(.rounded(13))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let words = ItogiRating.deltaWords(summary.ratingDelta, period: period) {
                        Text(words)
                            .font(.rounded(13, .semibold))
                            .foregroundStyle((summary.ratingDelta ?? 0) > 0 ? Theme.success : Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Пока не из чего считать рейтинг")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            Spacer(minLength: 0)
        }
        .statCard()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Из 100 сняли

    private var total: Int {
        if let rating = summary.rating { return max(0, 100 - rating) }
        return Int(data.sources.total.rounded())
    }

    /// Две причины, как у телематики страховых: резкая езда и камеры, каждая
    /// ведёт глубже. Сумма строк — ровно `100 − рейтинг` (наибольшие остатки).
    @ViewBuilder private var takenGroup: some View {
        let sources = data.sources
        if !sources.isEmpty, total > 0 {
            let camerasExact = sources.cameras.reduce(0) { $0 + $1.points }
            let whole = RatingBreakdown.wholePoints([sources.smoothness, camerasExact], total: total)
            let items = takenItems(smooth: whole[0], cameras: whole[1])
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ItogiGroupTitle(title: String(localized: "Из 100 сняли \(total)"))
                    ItogiRowGroup(items: items)
                }
            }
        } else if summary.rating != nil, total > 0 {
            // Записи окна вычищены — причин не назвать, только вклады по дням.
            ItogiRowGroup(items: [
                ItogiRowItem(id: "days", symbol: Icon.byDays,
                             title: String(localized: "Из 100 сняли \(total)"),
                             caption: String(localized: "Полные записи за это время уже удалены — остались итоги по дням"),
                             action: { path.append(.allContributions) }),
            ])
        }
    }

    private func takenItems(smooth: Int, cameras: Int) -> [ItogiRowItem] {
        var rows: [(points: Int, item: ItogiRowItem)] = []
        if smooth > 0 {
            rows.append((smooth, ItogiRowItem(
                id: "smooth", symbol: Icon.smoothness,
                title: String(localized: "Резкие разгоны и торможения"),
                caption: roughest.map {
                    String(format: String(localized: "больше всего — в поездке %@"),
                           Formatting.tripTitle($0.startedAt))
                },
                value: Formatting.points(smooth), valueTint: Theme.danger,
                action: {
                    if let roughest { path.append(.trip(roughest.id)) } else { path.append(.allContributions) }
                })))
        }
        let hotspots = data.sources.cameras
        if cameras > 0, let top = hotspots.first {
            let more = hotspots.count - 1
            let caption = more > 0
                ? String(format: String(localized: "больше всего — %1$@ · ещё %2$lld %3$@"),
                         top.location, more, Formatting.camerasLabel(more))
                // Проезды, снявшие баллы, — и «на грани» тоже: не «превышения».
                : top.location + " · " + "\(top.times)\u{00A0}" + Formatting.passesLabel(top.times)
            rows.append((cameras, ItogiRowItem(
                id: "cameras", symbol: Icon.cameras, tint: Theme.Icon.camera,
                title: String(localized: "Камеры: выше лимита"),
                caption: caption,
                value: Formatting.points(cameras), valueTint: Theme.danger,
                action: { path.append(.cameras) })))
        }
        // Больше снявшее — первым: блок обещает «за что сняли».
        return rows.sorted { $0.points > $1.points }.map(\.item)
    }

    // MARK: - Как вернуть баллы

    @ViewBuilder private var tipsGroup: some View {
        if let rating = summary.rating {
            let tips = ItogiRating.tips(rating: rating, sources: data.sources, cameraRating: cameraRating)
            if !tips.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ItogiGroupTitle(title: String(localized: "Как вернуть баллы"))
                    ItogiRowGroup(items: tips.enumerated().map { index, tip in tipItem(tip, index: index) })
                }
            }
        }
    }

    private func tipItem(_ tip: ItogiRating.Tip, index: Int) -> ItogiRowItem {
        switch tip {
        case .camera(let location, let limit, let rating):
            return ItogiRowItem(
                id: "tip\(index)", symbol: Icon.tip,
                title: limit.map { String(format: String(localized: "%1$@ — не выше %2$lld"), location, $0) }
                    ?? String(format: String(localized: "%@ — в лимите"), location),
                caption: period == .month
                    ? String(format: String(localized: "будь так весь месяц — рейтинг был бы %lld"), rating)
                    : String(format: String(localized: "будь так всю неделю — рейтинг был бы %lld"), rating))
        case .smoothness(let rating, let beatsCameras):
            return ItogiRowItem(
                id: "tip\(index)", symbol: Icon.tip,
                title: String(localized: "Плавнее трогайтесь и тормозите"),
                caption: beatsCameras
                    ? String(format: String(localized: "резкая езда сняла больше, чем камеры · без неё было бы %lld"), rating)
                    : String(format: String(localized: "без резкой езды рейтинг был бы %lld"), rating))
        }
    }

    // MARK: - Глубже

    private var moreGroup: some View {
        var items: [ItogiRowItem] = []
        if !data.contributions.isEmpty {
            items.append(ItogiRowItem(
                id: "byTrips", symbol: Icon.byTrips,
                title: String(localized: "Какие поездки потянули вниз"),
                caption: data.unrated > 0
                    ? String(localized: "Ещё \(data.unrated) поездок без известных лимитов и трека — в рейтинг они не вошли")
                    : String(localized: "длинные поездки весят больше коротких"),
                value: "\(data.contributions.count)",
                action: { path.append(.allContributions) }))
        }
        items.append(ItogiRowItem(
            id: "method", symbol: Icon.method,
            title: String(localized: "Как считаем рейтинг"),
            caption: String(localized: "шкала, баллы за камеры и плавность, динамика"),
            action: { path.append(.method) }))
        return ItogiRowGroup(items: items)
    }

    // MARK: - Камеры

    /// Все камеры, на которых сняли, — от дорогих к дешёвым; тап — худший
    /// проезд этой камеры за окно.
    private var camerasPage: some View {
        let hotspots = data.sources.cameras
        let camerasExact = hotspots.reduce(0) { $0 + $1.points }
        let whole = RatingBreakdown.wholePoints(
            hotspots.map(\.points) + [data.sources.smoothness],
            total: total)
        let shown = zip(hotspots, whole).map { ($0, $1) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(format: String(localized: "Сняли за камеры: %@ из %lld"),
                            Formatting.points(Int(camerasExact.rounded())), total))
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 4)
                ItogiRowGroup(items: shown.map { hotspot, points in
                    ItogiRowItem(id: "cam\(hotspot.id)", symbol: Icon.cameras, tint: Theme.Icon.camera,
                                 title: hotspot.location,
                                 caption: hotspotDetail(hotspot),
                                 value: Formatting.points(points), valueTint: Theme.danger,
                                 action: {
                                     guard let found = worstPass(cameraID: hotspot.id) else { return }
                                     path.append(.pass(trip: found.record.id, pass: found.pass.id))
                                 })
                })
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Камеры")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// «3 проезда · до 88 при 60». Одна улица может нести несколько камер с
    /// одинаковым названием — тогда единственный проезд различает дата.
    private func hotspotDetail(_ hotspot: RatingHotspot) -> String {
        let head = hotspot.times > 1
            ? "\(hotspot.times)\u{00A0}" + Formatting.passesLabel(hotspot.times)
            : Formatting.dateAndClock(hotspot.worstDate, .dateTime.day().month(.abbreviated), separator: " ")
        guard let limit = hotspot.limitKmh else { return head }
        let speed = hotspot.times > 1
            ? String(format: String(localized: "до %1$lld при лимите %2$lld"), Int(hotspot.worstSpeedKmh.rounded()), limit)
            : String(format: String(localized: "%1$lld при лимите %2$lld"), Int(hotspot.worstSpeedKmh.rounded()), limit)
        return head + " · " + speed
    }

    /// Худший проезд этой камеры за окно — именно его и стоит показать.
    private func worstPass(cameraID: Int) -> (record: TripRecord, pass: PassedCamera)? {
        var best: (record: TripRecord, pass: PassedCamera)?
        for record in env.trip.history where interval.contains(record.startedAt) {
            for pass in record.passed where pass.cameraID == cameraID {
                if best == nil || pass.speedKmh > best!.pass.speedKmh {
                    best = (record, pass)
                }
            }
        }
        return best
    }

    // MARK: - Как считаем

    /// Формулы живут только здесь (аудит, п. 4): на первом экране — «сняли N
    /// за …», здесь — откуда это число, проверяемо сложением.
    private var methodPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let rating = summary.rating {
                    formulaCard(rating: rating)
                }
                normAndTrendCard
                scaleCard
                componentsCard
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Как считаем рейтинг")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// `100 − 35 = 65` плюс сама сотня, разложенная в полосу вкладов поездок.
    private func formulaCard(rating: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(String(localized: "Из чего сложилось число"))
            HStack(spacing: 6) {
                Text(verbatim: "100")
                    .font(.rounded(19, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                Text(Formatting.points(100 - rating))
                    .font(.rounded(19, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.danger)
                Text(verbatim: "=")
                    .font(.rounded(15, .medium))
                    .foregroundStyle(Theme.textTertiary)
                Text("\(rating)")
                    .font(.numeral(24, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            ContributionBar(rating: rating, items: data.contributions, highlighted: nil) { id in
                path.append(.trip(id))
            }
            HStack(spacing: 14) {
                ItogiLegendDot(color: Theme.score(rating), title: String(localized: "удержано"))
                ItogiLegendDot(color: Theme.danger, title: String(localized: "снято поездками"))
                Spacer(minLength: 0)
            }
            if let first = data.contributions.max(by: { $0.points < $1.points }) {
                ContributionFormula(item: first)
            }
            if let next = ItogiRating.Level(rating: rating).next(from: rating) {
                Text(String(format: String(localized: "До уровня «%1$@» — %2$@"), next.level.title,
                            String(localized: "\(next.points) баллов")))
                    .font(.rounded(13, .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .statCard()
    }

    /// Шкала уровней — те же четыре слова, что на главном листе.
    private var scaleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(String(localized: "Шкала"))
            ForEach(ItogiRating.Level.allCases.reversed(), id: \.self) { level in
                HStack(spacing: 10) {
                    Circle().fill(Theme.score(level.range.lowerBound)).frame(width: 10, height: 10)
                    Text(verbatim: "\(level.range.lowerBound)–\(level.range.upperBound)")
                        .font(.rounded(15, .bold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 72, alignment: .leading)
                    Text(level.title)
                        .font(.rounded(15))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .statCard()
    }

    private var componentsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(String(localized: "Из чего складывается"))
            componentRow(icon: Icon.cameras, title: String(localized: "Скорость у камер"),
                         text: String(localized: "Каждый проезд камеры с известным лимитом: берём минимальную скорость в 80 м перед камерой — разгон после проезда не считается. От +2 км/ч балл снимается («на грани»), со штрафной ступени — сильнее всего."))
            componentRow(icon: Icon.smoothness, title: String(localized: "Плавность езды"),
                         text: String(localized: "Резкие разгоны и торможения по треку поездки снижают балл."))
            componentRow(icon: "scalemass.fill", title: String(localized: "Вес поездки"),
                         text: String(localized: "Рейтинг периода — среднее баллов, взвешенное по километрам: длинная трасса влияет на него сильнее, чем поездка до магазина."))
        }
        .statCard()
    }

    private func componentRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: icon, tint: Theme.textSecondary, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rounded(15, .semibold)).foregroundStyle(Theme.textPrimary)
                Text(text).font(.rounded(13)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Динамика

    private enum ChartMode: Hashable { case days, weeks }

    /// Норма и динамика — одна карточка с переключателем, когда есть оба графика.
    @ViewBuilder private var normAndTrendCard: some View {
        let weeks = data.trend.filter { $0.rating != nil }
        let hasDays = data.daily.count >= 2, hasWeeks = weeks.count >= 2
        if hasDays || hasWeeks {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: String(localized: "Как менялся рейтинг")) {
                    if let baseline = data.baseline {
                        Text(period.baselineTitle(periods: baseline.periods))
                            .font(.rounded(12, .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                if hasDays && hasWeeks {
                    Picker("", selection: $chartMode) {
                        Text("По дням").tag(ChartMode.days)
                        Text("По неделям").tag(ChartMode.weeks)
                    }
                    .pickerStyle(.segmented)
                }
                if hasDays && (chartMode == .days || !hasWeeks) {
                    ratingChart
                } else if hasWeeks {
                    weeksChart(weeks)
                }
            }
            .statCard()
        }
    }

    @ViewBuilder private func weeksChart(_ filled: [RatingTrend.Week]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(filled) { week in
                BarMark(x: .value("Неделя", week.start, unit: .weekOfYear),
                        y: .value("Рейтинг", week.rating ?? 0),
                        width: .fixed(20))
                    // Цвет колонки = цвет балла в списках; заливка плоская.
                    .foregroundStyle(Theme.score(week.rating ?? 0))
                    .opacity(week.id == filled.last?.id ? 1 : 0.65)
                    .cornerRadius(4)
                    .annotation(position: .top, spacing: 3) {
                        if filled.count <= 8 {
                            Text("\(week.rating ?? 0)")
                                .font(.rounded(12, .semibold).monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
            }
            .chartYScale(domain: 0...115)
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: filled.count <= 4 ? 1 : 2)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.defaultDigits), centered: true)
                        .foregroundStyle(Theme.textTertiary)
                        .font(.rounded(12))
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 110)
            Text("Недели без поездок пропущены")
                .font(.rounded(12))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// Дни для подписей оси: не больше четырёх, все — полночь дня точки.
    private var dayAxisValues: [Date] {
        let days = data.daily.map(\.day)
        guard days.count > 4 else { return days }
        let step = Int((Double(days.count) / 4).rounded(.up))
        return days.enumerated().filter { $0.offset % step == 0 }.map(\.element)
    }

    /// Линия рейтинга по дням; полоса «обычного диапазона» — фоном графика.
    private var ratingChart: some View {
        Chart {
            if let baseline = data.baseline {
                RuleMark(y: .value("Норма", baseline.median))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(data.daily) { point in
                LineMark(x: .value("День", point.day, unit: .day),
                         y: .value("Рейтинг", point.rating))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.accent)
                PointMark(x: .value("День", point.day, unit: .day),
                          y: .value("Рейтинг", point.rating))
                    .foregroundStyle(Theme.accent)
                    .symbolSize(60)
                    .symbol {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                    }
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { _ in
                AxisValueLabel().font(.rounded(12)).foregroundStyle(Theme.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: dayAxisValues) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.rounded(12)).foregroundStyle(Theme.textTertiary)
            }
        }
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let baseline = data.baseline, let plot = proxy.plotFrame,
                   let low = proxy.position(forY: Double(baseline.low)),
                   let high = proxy.position(forY: Double(baseline.high)) {
                    let frame = geometry[plot]
                    Rectangle()
                        .fill(Theme.quietFill)
                        .frame(width: frame.width, height: max(2, abs(low - high)))
                        .position(x: frame.midX, y: frame.minY + (low + high) / 2)
                }
            }
        }
        .frame(height: 120)
    }
}

// MARK: - Полоса вкладов

/// Сотня баллов, разложенная в одну шкалу: удержанное плюс сегменты потерь.
/// Тап по сегменту подсвечивает свою строку в списке — картинка и цифры
/// связаны, а не живут рядом.
private struct ContributionBar: View {
    let rating: Int
    let items: [RatingContribution]
    var highlighted: Double?
    var onSelect: (Double) -> Void

    /// Сколько потерь показываем отдельными сегментами: дальше полоса
    /// превращается в рябь из волосков.
    private static let visibleLosses = 4

    private struct Segment: Identifiable {
        let id: Double?
        let points: Double
        let color: Color
    }

    private var segments: [Segment] {
        var result = [Segment(id: nil, points: Double(rating),
                              color: TripHistorySection.scoreColor(rating))]
        let losses = items.filter { $0.points >= 0.05 }
        for (index, item) in losses.prefix(Self.visibleLosses).enumerated() {
            result.append(Segment(id: item.id, points: item.points,
                                  color: Theme.danger.opacity(1 - Double(index) * 0.18)))
        }
        let rest = losses.dropFirst(Self.visibleLosses).reduce(0) { $0 + $1.points }
        if rest >= 0.05 {
            result.append(Segment(id: nil, points: rest, color: Theme.textTertiary))
        }
        return result
    }

    var body: some View {
        let parts = segments
        let spacing: CGFloat = 2
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - spacing * CGFloat(parts.count - 1))
            HStack(spacing: spacing) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, segment in
                    Capsule()
                        .fill(segment.color)
                        .frame(width: max(3, available * segment.points / 100))
                        .opacity(highlighted == nil || highlighted == segment.id ? 1 : 0.35)
                        .onTapGesture {
                            if let id = segment.id { onSelect(id) }
                        }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(localized: "Удержано \(rating) баллов из 100")))
    }
}

// MARK: - Строка вклада

/// Строка обязана объяснять сама себя: слева — что за поездка, справа — вклад
/// и та самая арифметика «недобор × доля», из которой он получился.
/// Легенда к правой колонке строк (6.3): «18 × 23 %» без неё — шифр. Пример
/// берётся из первой строки, чтобы формула читалась на своих числах; «≈» —
/// потому что доля в строке округлена до процента.
private struct ContributionFormula: View {
    let item: RatingContribution

    var body: some View {
        // Арифметика — одним неразрывным куском: «≈» в конце строки и «−27,2»
        // на следующей читались как два разных выражения.
        // Произведение положительное — и результат без минуса: «18 × 23 % ≈
        // −4,1» читалось как ошибка знака; минус у вклада стоит в строке.
        let math = Formatting.unbreakable(
            "\(item.deficit) × \(Int((item.weightShare * 100).rounded())) % ≈ \(Formatting.decimal(item.points))")
        Text(String(format: String(localized: "Сколько поездка сняла = недобор её балла до 100 × её доля пути: %@"), math))
            .font(.rounded(13))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ContributionRow: View {
    let item: RatingContribution
    var highlighted = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Тонкая риска слева: величина вклада читается до чтения цифр.
                Capsule()
                    .fill(item.points >= 1 ? Theme.danger : Theme.textTertiary)
                    .frame(width: 3, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    // Даты — как в списке поездок: «Вчера, 19:00», «12 октября»;
                    // было «19 окт. 2026 г., 19:00» — другой экран, другой язык.
                    Text(item.isTrip ? Formatting.tripTitle(item.date) : Formatting.dayTitle(item.date))
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(String(format: String(localized: "балл %lld"), item.score)
                         + " · \(Formatting.distance(item.distanceMeters))")
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)
                // Сколько сняла у периода — без «18 × 23 %»: формула живёт
                // в «Как считаем рейтинг» (аудит 05.11, п. 4).
                Text(Formatting.points(item.points))
                    .font(.rounded(15, .heavy).monospacedDigit())
                    .foregroundStyle(item.points >= 1 ? Theme.danger : Theme.textSecondary)
                if item.isTrip {
                    Image(systemName: "chevron.right")
                        .font(.rounded(11, .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.vertical, 2)
            .background(highlighted ? Theme.quietFill : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(.row))
        .disabled(!item.isTrip)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Все вклады

/// Полный список без потолка: сортировка и фильтр вместо «остальные поездки: 7».
private struct AllContributionsView: View {
    let items: [RatingContribution]
    let period: StatsPeriod
    /// Дневные агрегаты — по ним раскрываются строки-дни, чьи записи вычищены.
    let days: [TripDay]
    let onOpenTrip: (Double) -> Void

    private enum Sort: String, CaseIterable, Identifiable {
        case points, date
        var id: String { rawValue }
        var title: String {
            switch self {
            case .points: return String(localized: "По вкладу")
            case .date:   return String(localized: "По дате")
            }
        }
    }

    @State private var sort: Sort = .points
    @State private var onlyViolations = false
    @State private var expandedDay: Double?
    @Namespace private var sortPill

    private var shown: [RatingContribution] {
        let filtered = onlyViolations ? items.filter(\.hasViolation) : items
        return sort == .points ? filtered.sorted { $0.points > $1.points }
                               : filtered.sorted { $0.date > $1.date }
    }

    var body: some View {
        // Один расчёт на проход body: shown — фильтр + сортировка, и как
        // computed property оно считалось четырежды (isEmpty, ForEach, total×2).
        let shown = self.shown
        return ScrollView {
            LazyVStack(spacing: 10) {
                controls
                Text("Длинные поездки весят больше коротких: справа — сколько каждая сняла с рейтинга.")
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if shown.isEmpty {
                    Text("В этом периоде нет поездок с превышениями — это хорошая новость.")
                        .font(.rounded(15))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 24)
                } else {
                    ForEach(shown) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            ContributionRow(item: item) { tap(item) }
                            if !item.isTrip, expandedDay == item.id {
                                dayDetail(item)
                            }
                        }
                        .statCard(padding: 12, radius: Theme.cornerMedium)
                    }
                    total(shown)
                }
            }
            .padding(20)
        }
        .backport.scrollEdgeEffectStyle(.hard, for: .top)
        .background(Theme.background)
        .navigationTitle("По поездкам")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Sort.allCases) { item in
                    let selected = sort == item
                    Button {
                        withMotion(Motion.quick) { sort = item }
                    } label: {
                        Text(item.title)
                            .font(.rounded(15, .semibold))
                            // Белое на accentFill: ночью accent светлый, и
                            // графитовый Theme.background на нём не читался.
                            .foregroundStyle(selected ? Theme.onAccentFill : Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background {
                                if selected {
                                    Capsule().fill(Theme.accentFill)
                                        .matchedGeometryEffect(id: "sortPill", in: sortPill)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle(.choice))
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(3)
            .background(Theme.surface, in: Capsule())

            Button {
                withMotion(Motion.quick) { onlyViolations.toggle() }
            } label: {
                Label("Только с превышениями",
                      systemImage: onlyViolations ? "checkmark.circle.fill" : "circle")
                    .font(.rounded(15, .medium))
                    .foregroundStyle(onlyViolations ? Theme.accent : Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(.choice))
        }
        .padding(.bottom, 4)
    }

    /// Итог списка: сумма показанных вкладов. Она обязана сходиться с
    /// «100 − рейтинг», когда фильтр выключен, — это и есть проверка сложением.
    private func total(_ shown: [RatingContribution]) -> some View {
        HStack {
            Text(String(format: String(localized: "Показано вкладов: %lld"), shown.count))
                .font(.rounded(15))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
            Text(Formatting.points(shown.reduce(0) { $0 + $1.points }))
                .font(.rounded(14, .heavy).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 4)
    }

    private func tap(_ item: RatingContribution) {
        if item.isTrip {
            onOpenTrip(item.id)
        } else {
            withMotion(Motion.quick) {
                expandedDay = expandedDay == item.id ? nil : item.id
            }
        }
    }

    /// Строка-день: записи уже вычищены, но дневной агрегат жив — показываем
    /// его целиком и честно говорим, почему поездок не видно.
    @ViewBuilder private func dayDetail(_ item: RatingContribution) -> some View {
        if let day = days.first(where: { $0.day.timeIntervalSince1970 == item.id }) {
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(Theme.stroke).frame(height: 1)
                HStack(spacing: 14) {
                    dayMetric("\(day.trips)", Formatting.tripsLabel(day.trips))
                    dayMetric(Formatting.distance(day.distanceMeters),
                              String(localized: "пройдено"))
                    dayMetric("\(day.overPasses)", String(localized: "превышений"))
                    Spacer(minLength: 0)
                }
                Text("Полные записи за этот день уже удалены — остались дневные итоги.")
                    .font(.rounded(10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dayMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.rounded(14, .bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.rounded(10))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}
