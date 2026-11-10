//
//  TripDetailSheet.swift
//  RadarMap
//
//  Деталка поездки: карта трека с проездами камер, метрики, честные скорости
//  с лимитами дорог и шеринг-карточка для мессенджеров.
//

import SwiftUI
import MapKit
import CoreLocation
import Charts

// MARK: - Общие помощники стиля проездов

enum PassStyle {
    /// Состояние проезда. Лимит известен — считает Theme.speedLevel (одно
    /// правило на HUD телефона, панель CarPlay, Итоги и эти строки); лимита
    /// нет — падаем на универсальные пороги города/трассы.
    ///
    /// Цвет и глиф берутся ОТСЮДА оба, а не считаются каждый по-своему:
    /// второй носитель состояния имеет смысл, только пока он говорит то же
    /// самое, что первый.
    static func level(speed: Double, limit: Int?) -> Theme.Level {
        // Лимит известен — три состояния проезда (PassVerdict): границы у
        // штрафной ступени и лестницы баллов, как в итогах и календаре.
        if limit != nil {
            return PassVerdict.of(speedKmh: speed, limitKmh: limit).level
        }
        switch speed {
        case ..<90:    return .normal
        case 90..<110: return .attention
        default:       return .alarm
        }
    }

    static func color(speed: Double, limit: Int?) -> Color {
        Theme.role(level(speed: speed, limit: limit))
    }

    /// Глиф состояния; nil — норма, значок не нужен (см. Theme.symbol).
    static func symbol(speed: Double, limit: Int?) -> String? {
        Theme.symbol(level(speed: speed, limit: limit))
    }
}

/// Строка «пройденная камера» — используется в Итогах и в деталке поездки.
struct PassRow: View {
    let pass: PassedCamera
    /// Стрелка-подсказка: тап по строке открывает карту проезда.
    var showsChevron = false
    /// «риск ≈ …» у строки. Камера со штрафом в поездке одна — сумма уже
    /// стоит в карточке балла над списком (34: та же цифра второй раз).
    var showsRisk = true

    var body: some View {
        HStack(spacing: 12) {
            CameraIcon(kind: pass.kind, side: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(pass.location.isEmpty ? pass.kind.displayName : pass.location)
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(Formatting.clock(pass.date))
                    .font(.rounded(11))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 8)
            // Мини-знак лимита — сразу видно, честно проехал или нет.
            if let limit = pass.limitKmh {
                SpeedLimitSign(limit: limit, diameter: 26)
            }
            VStack(alignment: .trailing, spacing: 2) {
                // Округление, а не усечение: тот же проезд открывается на
                // экране «Проезд камеры», и две разные цифры об одной скорости
                // выглядят как ошибка приложения.
                HStack(spacing: 4) {
                    // Глиф состояния — второй носитель рядом с цветом: красный
                    // и зелёный при дейтеранопии сливаются (см. Theme.symbol).
                    if let symbol = PassStyle.symbol(speed: pass.speedKmh, limit: pass.limitKmh) {
                        Image(systemName: symbol).font(.rounded(12, .bold))
                    }
                    // Десятые у границы (PassVerdict.speedText): «65» бывало и
                    // жёлтым, и красным.
                    Text(String(format: String(localized: "%@ км/ч"),
                                PassVerdict.speedText(speedKmh: pass.speedKmh, limitKmh: pass.limitKmh)))
                        .font(.rounded(15, .bold))
                }
                .foregroundStyle(PassStyle.color(speed: pass.speedKmh, limit: pass.limitKmh))
                // Превышение попало в штрафную ступень — показываем цену
                // вопроса; судьбу штрафа (пришёл / не пришёл) — как отметили
                // на экране возможных штрафов.
                if let limit = pass.limitKmh {
                    let fine = FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
                    if fine > 0, showsRisk || pass.fineOutcome != .pending {
                        switch pass.fineOutcome {
                        case .pending:
                            // У одного проезда — «штраф ≈» (аудит 05.11, п. 3).
                            Text(String(format: String(localized: "штраф ≈ %@"),
                                        Formatting.money(fine)))
                                .font(.rounded(12, .medium))
                                .foregroundStyle(Theme.danger)
                        case .paid:
                            Text(String(localized: "штраф пришёл"))
                                .font(.rounded(12, .medium))
                                .foregroundStyle(Theme.warning)
                        case .dismissed:
                            Text(String(localized: "штраф не пришёл"))
                                .font(.rounded(12, .medium))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.rounded(11, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        // Без своей карточки: строки лежат в общей (passCard) — тень на
        // каждой строке пересчитывалась при прокрутке (6.5).
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

/// Кнопка-строка проезда: если координата камеры сохранена — тап открывает
/// карту проезда; у старых записей без координат остаётся простая строка.
struct PassRowButton: View {
    let pass: PassedCamera
    var onTap: ((PassedCamera) -> Void)?
    var showsRisk = true

    var body: some View {
        if pass.coordinate != nil, let onTap {
            Button { onTap(pass) } label: {
                PassRow(pass: pass, showsChevron: true, showsRisk: showsRisk)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            PassRow(pass: pass, showsRisk: showsRisk)
        }
    }
}

// MARK: - Силуэт трека (Canvas): деталка-плейсхолдер, спарклайны, шеринг-карточка

struct TrackCanvas: View {
    let points: [TrackPoint]
    var passes: [PassedCamera] = []
    var lineWidth: CGFloat = 3
    var endpointSize: CGFloat = 9

    /// Каждая N-я точка, первая и последняя — всегда. Для силуэта в 44 pt
    /// четыреста точек трека неотличимы от восьмидесяти.
    static func thinned(_ points: [TrackPoint], to limit: Int) -> [TrackPoint] {
        guard points.count > limit, limit >= 2 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { points[Int((Double($0) * step).rounded())] }
    }

    var body: some View {
        Canvas { context, size in
            guard points.count >= 2 else { return }
            let lats = points.map(\.lat), lons = points.map(\.lon)
            guard let minLat = lats.min(), let maxLat = lats.max(),
                  let minLon = lons.min(), let maxLon = lons.max() else { return }
            // Общий масштаб по обеим осям — трек не искажается.
            let midLat = (minLat + maxLat) / 2
            let lonScale = cos(midLat * .pi / 180)
            let spanLat = max(maxLat - minLat, 1e-5)
            let spanLon = max((maxLon - minLon) * lonScale, 1e-5)
            let pad = 0.12 * min(size.width, size.height)
            let scale = min((size.width - 2 * pad) / spanLon, (size.height - 2 * pad) / spanLat)

            func project(_ lat: Double, _ lon: Double) -> CGPoint {
                CGPoint(
                    x: size.width / 2 + ((lon - (minLon + maxLon) / 2) * lonScale) * scale,
                    y: size.height / 2 - (lat - midLat) * scale
                )
            }

            var path = Path()
            path.move(to: project(points[0].lat, points[0].lon))
            for p in points.dropFirst() { path.addLine(to: project(p.lat, p.lon)) }
            // Один цвет маршрута, как на всех картах приложения. Градиент
            // синий→индиго остался от старой карты Apple и спорил с маршрутом.
            context.stroke(path, with: .color(Theme.route),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            // Старт и финиш — как на картах (TripEndpoints): старт белый с
            // кольцом маршрута, финиш — точка маршрута с белым кольцом.
            let d = endpointSize, r = d / 2
            let start = project(points[0].lat, points[0].lon)
            let startDot = Path(ellipseIn: CGRect(x: start.x - r, y: start.y - r, width: d, height: d))
            context.fill(startDot, with: .color(.white))
            context.stroke(startDot, with: .color(Theme.route), lineWidth: max(1.5, d * 0.2))
            let end = project(points[points.count - 1].lat, points[points.count - 1].lon)
            let endDot = Path(ellipseIn: CGRect(x: end.x - r, y: end.y - r, width: d, height: d))
            context.fill(endDot, with: .color(Theme.route))
            context.stroke(endDot, with: .color(.white), lineWidth: max(1.5, d * 0.18))

            // Проезды камер — цвет по честности проезда.
            for pass in passes {
                guard let lat = pass.lat, let lon = pass.lon else { continue }
                let pt = project(lat, lon)
                let color = PassStyle.color(speed: pass.speedKmh, limit: pass.limitKmh)
                context.fill(Path(ellipseIn: CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)),
                             with: .color(color))
                context.stroke(Path(ellipseIn: CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)),
                               with: .color(.white.opacity(0.85)), lineWidth: 1.5)
            }
        }
    }
}

// MARK: - Деталка поездки

/// Связь поездки с рейтингом периода — показывается, когда деталка открыта из
/// разбора рейтинга. Без неё «−12,6» в списке вкладов и «балл 55» на этом
/// экране остаются двумя не связанными числами.
struct TripRatingContext {
    let contribution: RatingContribution
    /// «за неделю» — окно, у которого поездка отняла баллы.
    let periodCaption: String
    /// Километры всего окна: доля веса становится проверяемой.
    let periodDistance: Double
    /// Окно — для «сняла с рейтинга недели / месяца».
    var period: StatsPeriod = .week
}

/// Шит-обёртка: из истории деталка открывается ровно как раньше.
struct TripDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let record: TripRecord
    var onRoute: ((CLLocationCoordinate2D, String) -> Void)? = nil

    @State private var selectedPass: PassedCamera?

    var body: some View {
        NavigationStack {
            TripDetailContent(record: record, onRoute: onRoute) { selectedPass = $0 }
                .navigationTitle(Formatting.tripTitle(record.startedAt))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: $selectedPass) { pass in
            PassMapSheet(pass: pass, track: record.trackPoints, record: record)
        }
        #if DEBUG
        // Скриншот-хук: `-openFirstPass` открывает первый проезд поездки.
        .onAppear {
            guard ProcessInfo.processInfo.arguments.contains("-openFirstPass") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { selectedPass = record.passed.first }
        }
        #endif
    }
}

/// Содержимое деталки без собственной навигации — чтобы её можно было и
/// показать шитом, и втолкнуть в стек разбора рейтинга. Во втором случае
/// «Назад» возвращает в разложение, а не выбрасывает на экран Итогов, как
/// делал шит поверх шита.
struct TripDetailContent: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    let record: TripRecord
    /// Открыто из разбора рейтинга — показываем, что поездка отняла у периода.
    var rating: TripRatingContext? = nil
    var onRoute: ((CLLocationCoordinate2D, String) -> Void)? = nil
    /// Тап по камере: шит показывает карту проезда, стек разбора — толкает её
    /// следующим уровнем.
    var onOpenPass: ((PassedCamera) -> Void)? = nil

    @State private var shareSubject: ShareSubjectBox?
    @State private var gpxFile: ShareFilePayload?
    @State private var appeared = false
    @State private var calmExpanded = false

    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
            VStack(spacing: 16) {
                // Порядок (аудит 05.11): карта → балл → камеры → метрики →
                // график → расходы → остановки. Камеры — сразу за баллом: это
                // ответ на «за что сняли», а метрики — справка.
                // «Повторить маршрут» — в шапке.
                mapSection
                    .entrance(0, appeared)
                scoreCard
                    .entrance(1, appeared)
                ratingCard
                    .entrance(1, appeared)
                if !record.passed.isEmpty {
                    passesSection
                        .entrance(2, appeared)
                }
                metricsCard
                    .entrance(2, appeared)
                SpeedProfileChart(record: record)
                    .entrance(3, appeared)
                    .id("chart")
                // Во что обошлась дорога (21.4): электричество и бензин по
                // дням, «как посчитано» — раскрывается.
                TripEnergyCard(record: record)
                    .entrance(3, appeared)
                    .id("energy")
                TripStopsSection(record: record) { dismiss() }
                    .entrance(4, appeared)
            }
            .padding(20)
            #if DEBUG
            .onAppear {
                // Скриншот-автоматизация: прокрутить к графику скорости.
                let args = ProcessInfo.processInfo.arguments
                // `-scrollEnergy` — к стоимости поездки (21.4).
                let target = args.contains("-scrollEnergy") ? "energy" : "chart"
                guard args.contains("-scrollChart") || args.contains("-scrollEnergy") else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withMotion { proxy.scrollTo(target, anchor: .top) }
                }
            }
            #endif
            }
        }
        .onAppear {
            appeared = true
            #if DEBUG
            // Скриншот-автоматизация: сразу открыть системный шэр.
            if ProcessInfo.processInfo.arguments.contains("-shareTrip") { share() }
            #endif
        }
        // Тот же жёсткий край прокрутки, что и в Итогах: карта поездки
        // не должна просвечивать сквозь панель с заголовком.
        .backport.scrollEdgeEffectStyle(.hard, for: .top)
        .background(Theme.background)
        .toolbar {
            if let onRoute, let end = record.endCoordinate {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        dismiss()
                        onRoute(end, String(localized: "Как в прошлый раз"))
                    } label: {
                        Image(systemName: "arrow.triangle.turn.up.right.circle")
                    }
                    .accessibilityLabel(Text("Повторить маршрут"))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                // Карточка — для людей, GPX — для разбора видео регистратора
                // и редакторов OSM. Трек уходит с телефона только так, руками.
                Menu {
                    Button { share() } label: {
                        Label("Поделиться поездкой", systemImage: "photo")
                    }
                    if record.hasTrack {
                        Button {
                            if let url = TimedTrackStore.gpxFile(for: record) {
                                gpxFile = ShareFilePayload(url: url)
                            }
                        } label: {
                            Label("Трек GPX", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(Text("Поделиться поездкой"))
            }
        }
        .sheet(item: $shareSubject) { box in
            SharePreviewSheet(subject: box.subject)
        }
        .sheet(item: $gpxFile) { payload in
            ActivityFileSheet(url: payload.url)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Вклад в рейтинг периода

    /// Что поездка сняла с рейтинга окна — словами, без «недобор × доля»
    /// (формула — в «Как считаем рейтинг»). Видно, почему короткая поездка с
    /// баллом 55 сняла меньше длинной с 70.
    @ViewBuilder private var ratingCard: some View {
        if let rating {
            let item = rating.contribution
            HStack(spacing: 12) {
                IconBadge(symbol: Icon.contribution, tint: Theme.danger, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.contributionTitle(rating.period))
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(String(format: String(localized: "длинные поездки весят больше: %1$@ из %2$@ %3$@"),
                                Formatting.distance(item.distanceMeters),
                                Formatting.distance(rating.periodDistance),
                                rating.periodCaption))
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(Formatting.points(item.points))
                    .font(.numeral(19, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.danger)
            }
            .statCard()
            .accessibilityElement(children: .combine)
        }
    }

    static func contributionTitle(_ period: StatsPeriod) -> String {
        switch period {
        case .day:   return String(localized: "Сняла с рейтинга дня")
        case .week:  return String(localized: "Сняла с рейтинга недели")
        case .month: return String(localized: "Сняла с рейтинга месяца")
        }
    }

    // MARK: Карта трека

    @ViewBuilder private var mapSection: some View {
        let points = record.trackPoints
        if points.count >= 2 {
            // Картинка, а не живая карта: жестов здесь не было и раньше, а
            // полсотни SwiftUI-кружков с цифрами стоили прокрутке как карта.
            // Легенда — под картинкой, а не на ней: капсулой в углу она
            // накрывала подписи самой карты («…ашкент», снимок этапа 31), а
            // подписи снимка рисует MapKit, и отодвинуть их нельзя.
            VStack(alignment: .leading, spacing: 8) {
                MapPictureView(key: "trip|\(record.id)|\(record.passed.count)",
                               picture: tripPicture(points), height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1))
                mapLegend
                    .padding(.horizontal, 4)
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
                    .foregroundStyle(Theme.textTertiary)
                Text("Трек не записан — появится у новых поездок")
                    .font(.rounded(15))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .statCard(padding: 18, radius: Theme.cornerMedium)
        }
    }

    /// Трек одним цветом маршрута; чистые проезды — маленькие зелёные точки,
    /// превышения — крупные, со скоростью внутри и поверх всего. Полсотни
    /// одинаковых кружков с цифрами лежали кучей, и найти в ней превышение
    /// было нельзя, а превышение — ровно то, ради чего на карту смотрят.
    private func tripPicture(_ points: [TrackPoint]) -> MapPicture {
        var picture = MapPicture()
        picture.lines = [.init(coordinates: points.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }, color: Theme.route, width: 4.5, casing: Theme.routeCasing, casingWidth: 8)]
        var over: [MapPicture.Dot] = []
        for pass in record.passed {
            guard let coordinate = pass.coordinate else { continue }
            // Лимит неизвестен — серая точка, как на карте периода и в Итогах:
            // ни «в лимите», ни «превышение» про неё сказать нельзя.
            if pass.limitKmh == nil {
                picture.dots.append(.init(coordinate: coordinate, diameter: 9,
                                          fill: Theme.textTertiary, ringWidth: 1.5))
            } else if pass.verdict != .clean {
                // «На грани» и превышение — со скоростью, цветом состояния.
                over.append(.init(coordinate: coordinate, diameter: pass.verdict == .over ? 24 : 21,
                                  fill: PassStyle.color(speed: pass.speedKmh, limit: pass.limitKmh),
                                  ringWidth: 2, label: "\(Int(pass.speedKmh.rounded()))",
                                  labelColor: Theme.background))
            } else {
                picture.dots.append(.init(coordinate: coordinate, diameter: 9,
                                          fill: Theme.success, ringWidth: 1.5))
            }
        }
        if let start = points.first, let finish = points.last {
            picture.dots += TripEndpoints.dots(
                start: CLLocationCoordinate2D(latitude: start.lat, longitude: start.lon),
                finish: CLLocationCoordinate2D(latitude: finish.lat, longitude: finish.lon))
        }
        picture.dots += over
        return picture
    }

    /// Легенда на самой карте: без неё зелёная точка и красный круг с числом
    /// — догадка, а не знание.
    @ViewBuilder private var mapLegend: some View {
        // Три состояния (PassVerdict) — те же слова, что в списке камер ниже:
        // «превышений: 2» над списком «Без штрафа» читались про разное.
        let tally = record.cameraTally
        if !record.passed.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { legendKeys(tally) }
                VStack(alignment: .leading, spacing: 4) { legendKeys(tally) }
            }
        }
    }

    @ViewBuilder private func legendKeys(_ tally: PassVerdict.Tally) -> some View {
        if tally.clean > 0 {
            legendDot(PassVerdict.clean.tint, String(format: String(localized: "в лимите: %lld"), tally.clean))
        }
        if tally.edge > 0 {
            legendDot(PassVerdict.edge.tint, String(format: String(localized: "на грани: %lld"), tally.edge))
        }
        if tally.over > 0 {
            legendDot(PassVerdict.over.tint, String(format: String(localized: "превышений: %lld"), tally.over))
        }
        if tally.unknown > 0 {
            legendDot(Theme.textTertiary, String(format: String(localized: "лимит неизвестен: %lld"), tally.unknown))
        }
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(.rounded(12, .semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Рейтинг поездки и риск штрафов

    /// Балл поездки и то, из чего он сложился, — одна карточка, как герой
    /// Итогов: число и его объяснение не должны жить в разных коробках.
    /// Внизу — сама арифметика «100 − 10 = 90»: разбор проверяется сложением.
    @ViewBuilder private var scoreCard: some View {
        let risk = TripHistory.fineRisk(of: record.passed)
        if record.score != nil || risk > 0 {
            let items = record.score == nil ? [] : DrivingScore.breakdown(
                passed: record.passed, trackSpeeds: record.trackPoints.map(\.speedKmh),
                score: record.score)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    if let score = record.score {
                        RatingRing(rating: Int(score), compact: true)
                            .frame(width: 56, height: 56)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        // «Балл поездки», не рейтинг (аудит, п. 4).
                        if let score = record.score {
                            Text("балл поездки")
                                .font(.rounded(12, .medium))
                                .foregroundStyle(Theme.textSecondary)
                            Text(ItogiRating.Level(rating: Int(score)).title)
                                .font(.rounded(19, .bold))
                                .foregroundStyle(Theme.score(Int(score)))
                        }
                        if risk > 0 {
                            Label(String(format: String(localized: "Могут прийти ≈ %@ · оценка, не постановления"),
                                         Formatting.money(risk)),
                                  systemImage: PassVerdict.over.symbol)
                                .font(.rounded(13, .semibold))
                                .foregroundStyle(Theme.danger)
                        } else if record.cameraTally.edge > 0 {
                            Label(String(format: String(localized: "Штрафа нет, но на грани у камер: %lld"),
                                         record.cameraTally.edge),
                                  systemImage: PassVerdict.edge.symbol)
                                .font(.rounded(13, .semibold))
                                .foregroundStyle(PassVerdict.edge.tint)
                        } else {
                            Label("Без штрафуемых превышений", systemImage: "checkmark.shield.fill")
                                .font(.rounded(13, .semibold))
                                .foregroundStyle(Theme.success)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                if !items.isEmpty {
                    Divider().overlay(Theme.stroke)
                    // «Сняли 10 за …» словами; формула «100 − 10 = 90» —
                    // только в «Как считаем рейтинг» (аудит, п. 4).
                    let taken = items.reduce(0) { $0 + $1.points }
                    Text(taken > 0 ? String(localized: "Сняли \(taken) баллов — за что") : String(localized: "За что сняли"))
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    ForEach(items) { item in
                        penaltyRow(item)
                    }
                }
            }
            .statCard()
        }
    }

    /// Строка снятых баллов. Если снял конкретный проезд — строка ведёт к нему:
    /// «−25 за Юнусабад» без возможности посмотреть сам проезд остаётся
    /// утверждением, которое нечем проверить.
    @ViewBuilder private func penaltyRow(_ item: DrivingScore.Penalty) -> some View {
        let pass = item.passID.flatMap { id in record.passed.first { $0.id == id } }
        if let pass, let onOpenPass {
            Button {
                onOpenPass(pass)
            } label: {
                penaltyContent(item, openable: true)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
        } else {
            // Не кнопка: выключенная кнопка рисуется системой бледной, и
            // строка «Резкие разгоны» читалась как недоступная, а не как факт.
            penaltyContent(item, openable: false)
                .accessibilityElement(children: .combine)
        }
    }

    private func penaltyContent(_ item: DrivingScore.Penalty, openable: Bool) -> some View {
        // Отрицательные баллы = «вернули» (потолок штрафа) — зелёный плюс.
        let returned = item.points < 0
        let tint = returned ? Theme.success : Theme.danger
        return HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: item.icon, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if let detail = item.detail {
                    Text(detail)
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(returned ? "+\(-item.points)" : "−\(item.points)")
                .font(.rounded(15, .heavy).monospacedDigit())
                .foregroundStyle(tint)
                .padding(.top, 5)
            if openable {
                Image(systemName: "chevron.right")
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 7)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: Метрики

    /// Шесть чисел одной карточкой в две колонки. Было четыре-пять плиток
    /// с крупной иконкой своего цвета у каждой: цвет ничего не значил, а
    /// плитки занимали экран ради четырёх цифр.
    private var metricsCard: some View {
        var items: [MetricsCard.Item] = [
            .init(value: Formatting.duration(record.duration), label: String(localized: "в пути"),
                  icon: "clock"),
            .init(value: Formatting.distance(record.distanceMeters), label: String(localized: "пройдено"),
                  icon: "point.topleft.down.to.point.bottomright.curvepath"),
            .init(value: "\(record.camerasPassed)", label: Formatting.passesLabel(record.camerasPassed),
                  icon: Icon.cameras),
            .init(value: "\(Int(record.maxSpeedKmh))", label: String(localized: "максимум, км/ч"),
                  icon: "gauge.with.dots.needle.100percent"),
            .init(value: "\(Int(record.averageSpeedKmh))", label: String(localized: "средняя, км/ч"),
                  icon: "gauge.with.dots.needle.33percent"),
        ]
        // Стоимость дороги — отдельной карточкой ниже (TripEnergyCard, 21.4):
        // в плитку не помещалось «27 км на электричестве · ≈ 4,3 кВт·ч».
        // Цена поездки в заряде — цифрой, а не верой (есть не у всех записей).
        if let drop = record.batteryDropPercent {
            items.append(.init(value: "−\(drop) %", label: String(localized: "заряда за поездку"),
                               icon: "battery.75percent"))
        }
        return MetricsCard(items: items)
    }

    /// Превышения и «на грани» — раскрыты, остальные свёрнуты одной строкой
    /// (6.5): из двадцати камер поездки смотрят те, что стоили баллов.
    /// Строки — в одной карточке, без своей тени у каждой.
    private var passesSection: some View {
        let passes = Array(record.passed.reversed())
        let costly = passes.filter { $0.verdict == .over || $0.verdict == .edge }
        let calm = passes.filter { $0.verdict == .clean || $0.verdict == .unknown }
        let allClean = calm.allSatisfy { $0.verdict == .clean }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(String(localized: "Пройденные камеры"))
            if !costly.isEmpty { passCard(costly) }
            if !calm.isEmpty {
                // Без снятых баллов свёрнутому списку нечего уступать.
                if costly.isEmpty || calmExpanded {
                    passCard(calm)
                }
                if !costly.isEmpty {
                    Button {
                        withMotion(Motion.standard) { calmExpanded.toggle() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: allClean ? PassVerdict.clean.symbol : "list.bullet")
                                .foregroundStyle(allClean ? PassVerdict.clean.tint : Theme.textSecondary)
                            Text(allClean
                                 ? String(format: String(localized: "В лимите: %lld"), calm.count)
                                 : String(format: String(localized: "Остальные камеры: %lld"), calm.count))
                                .font(.rounded(15, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.down")
                                .font(.rounded(12, .bold))
                                .foregroundStyle(Theme.textTertiary)
                                .rotationEffect(.degrees(calmExpanded ? 180 : 0))
                        }
                        .statCard(padding: 12, radius: Theme.cornerMedium)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func passCard(_ passes: [PassedCamera]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(passes.enumerated()), id: \.element.id) { index, pass in
                if index > 0 { Divider().overlay(Theme.stroke).padding(.leading, 58) }
                PassRowButton(pass: pass, onTap: onOpenPass,
                              showsRisk: record.passed.filter(Self.isFined).count > 1)
            }
        }
        .statCard(padding: 0, radius: Theme.cornerMedium)
    }

    /// Штрафуемый проезд: лимит известен и превышение дошло до ступени штрафа.
    nonisolated static func isFined(_ pass: PassedCamera) -> Bool {
        guard pass.limitIsCertain, let limit = pass.limitKmh else { return false }
        return FineSchedule.fine(overKmh: pass.speedKmh - Double(limit)) > 0
    }

    // MARK: Шеринг-карточка

    /// Готовим тему для превью: снимаем карту с треком (виден район и улицы),
    /// а саму карточку рисует SharePreviewSheet — там же выбирается формат.
    /// Карта не загрузилась (офлайн) — фолбэк на неоновый трек внутри карточки.
    private func share() {
        Task {
            let map = await TripMapSnapshot.render(track: record.trackPoints,
                                                   passes: record.passed,
                                                   size: CGSize(width: 1032, height: 840))
            shareSubject = ShareSubjectBox(subject: .trip(record, map: map))
        }
    }
}
