//
//  RatingDetailSheet.swift
//  RadarMap
//
//  Разбор рейтинга периода: почему у ВАС именно столько и что с этим делать.
//
//  Раньше это была расшифровка-методичка с пятью строками разложения и тупиком
//  вместо продолжения: список обрезался на «остальные поездки: 7», а тап по
//  строке закрывал шит и открывал ДРУГОЙ шит — «Назад» возвращало не в разбор,
//  а на экран Итогов. Цепочка рассуждения рвалась ровно там, где начиналась.
//
//  Теперь это стек с четырьмя уровнями, и на каждом видно, откуда взялось
//  число предыдущего:
//
//      рейтинг периода → все вклады → поездка → проезд камеры
//
//  Порядок блоков — от вывода к сырым данным: сколько (герой) → из чего
//  сложилось (формула и полоса) → нормально ли это для меня (норма) → где
//  именно теряю (камеры) → поимённо (вклады) → как это устроено (свёрнуто).
//
//  Все числа приходят готовыми из RatingBreakdown.screen, посчитанного вне
//  main: на месяце это полсотни записей со всеми проездами.
//

import SwiftUI
import Charts

/// Куда можно провалиться из разбора. Значения Hashable и лёгкие — путь живёт
/// по идентификаторам, а сами записи достаются из истории в момент показа.
private enum RatingRoute: Hashable {
    case allContributions
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
    /// Подсвеченная строка — тап по сегменту полосы вкладов.
    @State private var highlighted: Double?

    /// Ключ пересчёта: окно и состав истории.
    private struct DataKey: Equatable {
        let period: StatsPeriod
        let anchor: Date
        let trips: Int
        let days: Int
        let latest: Double?
    }

    @State private var chartMode: ChartMode = .days

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                ScrollViewReader { proxy in
                    LazyVStack(spacing: 16) {
                        // Порядок (6.6): итог и его формула — одной карточкой;
                        // «Где теряете баллы» сразу за ними — это вопрос,
                        // ради которого открывают экран; норма и динамика —
                        // одним графиком с переключателем.
                        VStack(alignment: .leading, spacing: 14) {
                            hero
                            if summary.rating != nil {
                                Divider().overlay(Theme.stroke)
                                formulaCard(proxy: proxy)
                            }
                        }
                        .statCard()
                        sourcesCard
                        normAndTrendCard
                        contributionsCard
                        understandCard
                    }
                    .padding(20)
                }
            }
            .backport.scrollEdgeEffectStyle(.hard, for: .top)
            .background(Theme.background)
            .navigationTitle("Рейтинг вождения")
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
            data = await RatingBreakdown.screen(records: env.trip.history, days: env.trip.days,
                                                period: period, anchor: anchor)
        }
    }

    // MARK: - Уровни разбора

    @ViewBuilder private func destination(_ route: RatingRoute) -> some View {
        switch route {
        case .allContributions:
            AllContributionsView(items: data.contributions, period: period,
                                 days: env.trip.days) { path.append(.trip($0)) }
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
                                 periodDistance: summary.distance)
    }

    // MARK: - Динамика по неделям

    /// «Я расту или падаю?» — рейтинг последних недель одной картинкой, ответ,
    /// которого нет внутри одного окна. Считается из дневных агрегатов, поэтому
    /// видит и месяцы, чьи полные записи давно вычищены. Меньше двух непустых
    /// недель — не показываем: тренд из одной точки не тренд.
    private enum ChartMode: Hashable { case days, weeks }

    /// Норма и динамика — одна карточка (6.6): были два графика подряд,
    /// дневной с линией нормы и недельный, и читались как один, нарисованный
    /// дважды. Переключатель — только когда есть оба.
    @ViewBuilder private var normAndTrendCard: some View {
        let weeks = data.trend.filter { $0.rating != nil }
        let hasDays = data.daily.count >= 2, hasWeeks = weeks.count >= 2
        if hasDays || hasWeeks || data.baseline != nil {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: String(localized: "Норма и динамика")) {
                    if let baseline = data.baseline {
                        Text(period.baselineTitle(periods: baseline.periods))
                            .font(.rounded(11, .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                if let verdict = baselineVerdict {
                    Text(verdict)
                        .font(.rounded(15, .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
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
                if let last = filled.last?.rating,
                   let previous = filled.dropLast().last?.rating,
                   last != previous {
                    Text(String(format: String(localized: "%@ к прошлой неделе"),
                                Formatting.signed(last - previous)))
                        .font(.rounded(13, .bold).monospacedDigit())
                        .foregroundStyle(last > previous ? Theme.success : Theme.danger)
                }
                Chart(filled) { week in
                    BarMark(x: .value("Неделя", week.start, unit: .weekOfYear),
                            y: .value("Рейтинг", week.rating ?? 0),
                            // Фиксированная ширина: при двух заполненных неделях
                            // ratio растягивал колонки в плиты на полэкрана.
                            width: .fixed(20))
                        // Цвет колонки = цвет балла в списках: одна шкала на всё.
                        // Заливка плоская: градиент по высоте столбика красил бы
                        // одну и ту же оценку по-разному в зависимости от того,
                        // насколько она велика, — величину уже кодирует высота.
                        .foregroundStyle(TripHistorySection.scoreColor(week.rating ?? 0))
                        .opacity(week.id == filled.last?.id ? 1 : 0.65)
                        .cornerRadius(4)
                        .annotation(position: .top, spacing: 3) {
                            // Число над колонкой — пока колонок мало и цифры
                            // не слипаются; на длинном тренде ось скажет сама.
                            if filled.count <= 8 {
                                Text("\(week.rating ?? 0)")
                                    .font(.rounded(9, .bold).monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                }
                .chartYScale(domain: 0...112)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear,
                                              count: filled.count <= 4 ? 1 : 2)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.defaultDigits),
                                       centered: true)
                            .foregroundStyle(Theme.textTertiary)
                            .font(.rounded(9, .medium))
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 104)
                Text("Недели без поездок пропущены")
                    .font(.rounded(10))
                    .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Герой

    private var hero: some View {
        HStack(spacing: 16) {
            if let rating = summary.rating {
                RatingRing(rating: rating)
                    .frame(width: 92, height: 92)
            } else {
                Image(systemName: "gauge.with.needle")
                    .font(.rounded(30))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 92, height: 92)
                    .background(Theme.quietFill, in: Circle())
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(period.caption)
                    .font(.rounded(11, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.uppercase)
                if let rating = summary.rating {
                    Text(DrivingScore.level(for: rating))
                        .font(.rounded(19, .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let delta = summary.ratingDelta {
                    deltaBadge(delta)
                }
                Text(String(format: String(localized: "Поездок: %1$lld · %2$@"),
                            summary.trips, Formatting.distance(summary.distance)))
                    .font(.rounded(15))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Та же метка, что в герое «Итогов» (6.3): «−8 к прошлой», без стрелки
    /// рядом со знаком — один экран не должен называть одно число по-разному.
    private func deltaBadge(_ delta: Int) -> some View {
        let up = delta > 0
        let flat = delta == 0
        let tint: Color = flat ? Theme.textSecondary : (up ? Theme.success : Theme.danger)
        return Text(flat ? String(localized: "как в прошлый период") : period.ratingDeltaText(delta))
            .font(.rounded(11, .bold).monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.quietFill, in: Capsule())
    }

    // MARK: - Формула и полоса вкладов

    /// `100 − 27 = 73` плюс сама сотня, разложенная в полосу: сразу видно,
    /// рейтинг съела одна поездка или десяток мелких. Число и картинка
    /// показывают одно и то же — полоса строится из тех же вкладов.
    @ViewBuilder private func formulaCard(proxy: ScrollViewProxy) -> some View {
        if let rating = summary.rating {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Text("100")
                        .font(.rounded(17, .heavy).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                    Text("−\(Int((100 - Double(rating)).rounded()))")
                        .font(.rounded(17, .heavy).monospacedDigit())
                        .foregroundStyle(Theme.danger)
                    Text("=")
                        .font(.rounded(15, .medium))
                        .foregroundStyle(Theme.textTertiary)
                    Text("\(rating)")
                        .font(.numeral(20, .heavy).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                }

                ContributionBar(rating: rating, items: data.contributions,
                                highlighted: highlighted) { id in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withMotion(Motion.standard) {
                        highlighted = highlighted == id ? nil : id
                        if highlighted != nil { proxy.scrollTo(id, anchor: .center) }
                    }
                }

                HStack(spacing: 14) {
                    legendDot(TripHistorySection.scoreColor(rating),
                              String(format: String(localized: "удержано %lld"), rating))
                    legendDot(Theme.danger,
                              String(format: String(localized: "потеряно %lld"),
                                     Int((100 - Double(rating)).rounded())))
                    Spacer(minLength: 0)
                }

                if let next = DrivingScore.nextLevel(for: rating) {
                    // Форма числа — отдельной строкой каталога: «1 балл»,
                    // «3 балла», «7 баллов» (6.11).
                    Text(String(localized: "До уровня «\(next.name)» — \(String(localized: "\(next.threshold - rating) баллов"))"))
                        .font(.rounded(11, .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private func legendDot(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.rounded(11)).foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Ваша норма

    /// Абсолютная цифра ничего не говорит: 73 для одного водителя рекорд, для
    /// другого — провал. Норма считается по прошлым таким же окнам (текущее в
    /// неё не входит — иначе оно объясняло бы само себя).
    private var baselineVerdict: String? {
        guard let baseline = data.baseline, let rating = summary.rating else { return nil }
        if baseline.contains(rating) {
            return String(format: String(localized: "Это ваш обычный уровень — вы обычно держитесь между %1$lld и %2$lld."),
                          baseline.low, baseline.high)
        }
        let delta = baseline.delta(from: rating)
        return delta > 0
            ? String(format: String(localized: "На %1$lld балла выше вашей нормы (обычно %2$lld)."),
                     delta, baseline.median)
            : String(format: String(localized: "На %1$lld балла ниже вашей нормы (обычно %2$lld)."),
                     -delta, baseline.median)
    }

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
                // Точки — того же цвета, что линия, и это исправление.
                //
                // Раньше они красились по баллу (`scoreColor`), и на одном
                // графике сходились ДВЕ разные работы цвета: линия говорила
                // «это рейтинг» (принадлежность), а точки — «хорошо/плохо»
                // (состояние). Хуже того, состояние тут уже закодировано
                // высотой точки: балл и есть ось Y. Цвет повторял ось и при
                // этом отнимал у линии её собственную опознаваемость.
                //
                // Кольцо цветом фона — чтобы точки не слипались на плотном
                // участке; размер поднят до различимого пальцем.
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
                AxisValueLabel().font(.rounded(9)).foregroundStyle(Theme.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.rounded(9)).foregroundStyle(Theme.textTertiary)
            }
        }
        // Полоса «обычного диапазона» рисуется фоном графика: так она не спорит
        // с линией и не требует отдельной шкалы.
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
        .frame(height: 110)
    }

    // MARK: - Где теряете баллы

    /// Двенадцать строк «поездка такая-то» не говорят, что делать. «Юнусабад,
    /// 4 проезда, −18» говорит. Сумма строк равна сумме вкладов поездок.
    @ViewBuilder private var sourcesCard: some View {
        let sources = data.sources
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(String(localized: "Где теряете баллы"))
                // Плавность встаёт в общий порядок по величине, а не отдельной
                // строкой снизу: блок обещает «где теряете больше всего», и
                // −20 за рваную езду под −6 за камеру этому обещанию врёт.
                ForEach(sourceRows(sources)) { row in
                    switch row {
                    case .camera(let hotspot): hotspotRow(hotspot)
                    case .smoothness(let points): smoothnessRow(points)
                    }
                }
                let rest = sources.cameras.dropFirst(AppConfig.hotspotsVisibleRows)
                if !rest.isEmpty {
                    restRow(title: String(format: String(localized: "Остальные камеры: %lld"),
                                          rest.count),
                            points: rest.reduce(0) { $0 + $1.points })
                }
            }
            .statCard()
        }
    }

    private enum SourceRow: Identifiable {
        case camera(RatingHotspot)
        case smoothness(Double)

        var id: Int {
            switch self {
            case .camera(let hotspot): return hotspot.id
            case .smoothness:          return -1
            }
        }
        var points: Double {
            switch self {
            case .camera(let hotspot): return hotspot.points
            case .smoothness(let value): return value
            }
        }
    }

    private func sourceRows(_ sources: RatingSources) -> [SourceRow] {
        var rows = sources.cameras.prefix(AppConfig.hotspotsVisibleRows).map(SourceRow.camera)
        if sources.smoothness >= 0.5 { rows.append(.smoothness(sources.smoothness)) }
        return rows.sorted { $0.points > $1.points }
    }

    private func hotspotRow(_ hotspot: RatingHotspot) -> some View {
        Button {
            guard let found = worstPass(cameraID: hotspot.id) else { return }
            path.append(.pass(trip: found.record.id, pass: found.pass.id))
        } label: {
            HStack(spacing: 12) {
                SymbolIcon(Icon.cameras, size: 15, weight: .bold)
                    .foregroundStyle(Theme.danger)
                    .frame(width: 32, height: 32)
                    .background(Theme.quietFill, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(hotspot.location)
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(hotspotDetail(hotspot))
                        .font(.rounded(11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(Formatting.points(hotspot.points))
                    .font(.rounded(16, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.danger)
                Image(systemName: "chevron.right")
                    .font(.rounded(11, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Без .disabled по worstPass: он обходит всю историю, и в body это
        // делалось 4 раза на каждый пересчёт. Кнопка с пустым действием при
        // отсутствии проезда безвредна, а случай почти невозможен — hotspot
        // построен из тех же записей.
        .accessibilityElement(children: .combine)
    }

    /// Подпись строки. Одна улица может нести несколько камер с одинаковым
    /// названием — тогда единственный проезд различает дата, а повторные
    /// проезды и так различаются числом.
    private func hotspotDetail(_ hotspot: RatingHotspot) -> String {
        let head = hotspot.times > 1
            ? String(format: String(localized: "проездов: %lld"), hotspot.times)
            : Formatting.dateAndClock(hotspot.worstDate, .dateTime.day().month(.abbreviated), separator: " ")
        guard let limit = hotspot.limitKmh else { return head }
        let speed = hotspot.times > 1
            ? String(format: String(localized: "до %1$lld при лимите %2$lld"),
                     Int(hotspot.worstSpeedKmh), limit)
            : String(format: String(localized: "%1$lld при лимите %2$lld"),
                     Int(hotspot.worstSpeedKmh), limit)
        return head + " · " + speed
    }

    private func smoothnessRow(_ points: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.rounded(15, .bold))
                .foregroundStyle(Theme.warning)
                .frame(width: 32, height: 32)
                .background(Theme.quietFill, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Резкие разгоны и торможения")
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("по трекам поездок периода")
                    .font(.rounded(11))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 8)
            Text(Formatting.points(points))
                .font(.rounded(16, .heavy).monospacedDigit())
                .foregroundStyle(Theme.warning)
        }
        .accessibilityElement(children: .combine)
    }

    private func restRow(title: String, points: Double) -> some View {
        HStack {
            Text(title)
                .font(.rounded(15))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
            Text(Formatting.points(points))
                .font(.rounded(15, .semibold).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
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

    // MARK: - Вклады поездок

    /// Превью крупных вкладов; полный список — отдельным экраном с сортировкой
    /// и фильтром. Двадцать строк по −0,1 балла на первом экране объясняют
    /// ровно ничего, но и прятать их насовсем нельзя — сумма должна сходиться.
    @ViewBuilder private var contributionsCard: some View {
        let items = data.contributions
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(String(localized: "Из чего сложился ваш рейтинг"))
                let shown = Array(items.prefix(AppConfig.breakdownVisibleRows))
                    .filter { $0.points >= AppConfig.breakdownMinPoints }
                if let first = shown.first { ContributionFormula(item: first) }
                ForEach(shown) { item in
                    ContributionRow(item: item, highlighted: highlighted == item.id) {
                        open(item)
                    }
                    .id(item.id)
                }
                // Хвост считаем по ТЕМ ЖЕ строкам, что показали: иначе мелкая
                // строка внутри первой пятёрки съезжала бы в оба списка сразу
                // и блок переставал сходиться к 100 − рейтинг.
                let shownIDs = Set(shown.map(\.id))
                let rest = items.filter { !shownIDs.contains($0.id) }
                if !rest.isEmpty {
                    restRow(title: String(format: String(localized: "Остальные поездки: %lld"),
                                          rest.count),
                            points: rest.reduce(0) { $0 + $1.points })
                }

                Button {
                    path.append(.allContributions)
                } label: {
                    HStack(spacing: 6) {
                        Text(String(format: String(localized: "Все вклады (%lld)"), items.count))
                            .font(.rounded(15, .semibold))
                        Image(systemName: "chevron.right")
                            .font(.rounded(10, .bold))
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())

                if data.unrated > 0 {
                    Text(String(localized: "Ещё \(data.unrated) поездок без известных лимитов и трека — в рейтинг они не вошли"))
                        .font(.rounded(11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .statCard()
        }
    }

    private func open(_ item: RatingContribution) {
        guard item.isTrip else { return }
        path.append(.trip(item.id))
    }

    // MARK: - Понять данные

    /// Методика нужна, но она не должна занимать три карточки над личными
    /// цифрами: кто спросит — раскроет.
    private var understandCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(String(localized: "Шкала"))
                    scaleRow(Theme.success, "90–100", String(localized: "Идеальный стиль"))
                    scaleRow(Theme.success.opacity(0.75), "75–89",
                             String(localized: "Аккуратный водитель"))
                    scaleRow(Theme.warning, "60–74",
                             String(localized: "Уверенный, но с риском"))
                    scaleRow(Theme.danger, "0–59", String(localized: "Рискованный стиль"))
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(String(localized: "Из чего складывается"))
                    componentRow(icon: Icon.cameras, tint: Theme.accent,
                                 title: String(localized: "Скорость у камер"),
                                 text: String(localized: "Каждый проезд камеры с известным лимитом: берём минимальную скорость в 80 м перед камерой — разгон после проезда не считается. Штрафные ступени снижают балл сильнее всего."))
                    componentRow(icon: "waveform.path.ecg", tint: Theme.Types.intelligent,
                                 title: String(localized: "Плавность езды"),
                                 text: String(localized: "Резкие разгоны и торможения по треку поездки снижают балл."))
                    componentRow(icon: "scalemass", tint: Theme.warning,
                                 title: String(localized: "Вес поездки"),
                                 text: String(localized: "Рейтинг периода — среднее баллов, взвешенное по километрам: длинная трасса влияет на него сильнее, чем поездка до магазина."))
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(String(localized: "Как поднять"))
                    tipRow(String(localized: "Проезжайте камеры не выше лимита — уже +6 км/ч попадает в штрафную ступень."))
                    tipRow(String(localized: "Разгоняйтесь и тормозите плавно."))
                    tipRow(String(localized: "Начните с камер из блока «Где теряете баллы» — там теряется больше всего."))
                }
            }
            .padding(.top, 14)
        } label: {
            Text("Понять данные")
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .tint(Theme.accent)
        .statCard()
    }

    private func scaleRow(_ color: Color, _ range: String, _ name: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(range)
                .font(.rounded(14, .bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 64, alignment: .leading)
            Text(name)
                .font(.rounded(14))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
    }

    private func componentRow(icon: String, tint: Color, title: String,
                              text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolIcon(icon, size: 15)
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(Theme.quietFill,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rounded(14, .semibold)).foregroundStyle(Theme.textPrimary)
                Text(text).font(.rounded(15)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.rounded(15))
                .foregroundStyle(Theme.success)
                .padding(.top, 2)
            Text(text)
                .font(.rounded(15))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
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
        Text(String(format: String(localized: "Вклад = недобор балла до 100 × доля пути: %@"), math))
            .font(.rounded(11))
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
                    Text("\(Formatting.distance(item.distanceMeters)) · "
                         + String(format: String(localized: "балл %lld"), item.score))
                        .font(.rounded(11))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Formatting.points(item.points))
                        .font(.rounded(16, .heavy).monospacedDigit())
                        .foregroundStyle(item.points >= 1 ? Theme.danger : Theme.textSecondary)
                    // Откуда взялось именно это число.
                    Text(String(format: String(localized: "%1$lld × %2$lld %%"),
                                item.deficit, Int((item.weightShare * 100).rounded())))
                        .font(.rounded(10, .medium).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
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
        .buttonStyle(.plain)
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
                if let first = shown.first {
                    ContributionFormula(item: first)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        .navigationTitle("Все вклады")
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
                    .buttonStyle(.plain)
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
            .buttonStyle(.plain)
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
