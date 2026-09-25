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
        if limit != nil {
            return Theme.speedLevel(speedKmh: speed, limitKmh: limit)
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pass.kind.symbolName)
                .font(.rounded(15, .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(pass.kind.tint.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(pass.location.isEmpty ? pass.kind.displayName : pass.location)
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(pass.date.formatted(date: .omitted, time: .shortened))
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
                    Text("\(Int(pass.speedKmh.rounded())) км/ч")
                        .font(.rounded(15, .bold))
                }
                .foregroundStyle(PassStyle.color(speed: pass.speedKmh, limit: pass.limitKmh))
                // Превышение попало в штрафную ступень — показываем цену
                // вопроса; судьбу штрафа (пришёл / не пришёл) — как отметили
                // на экране возможных штрафов.
                if let limit = pass.limitKmh {
                    let fine = FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
                    if fine > 0 {
                        switch pass.fineOutcome {
                        case .pending:
                            Text(String(format: String(localized: "риск ≈ %@"),
                                        Formatting.money(fine)))
                                .font(.rounded(10, .medium))
                                .foregroundStyle(Theme.danger)
                        case .paid:
                            Text(String(localized: "штраф пришёл"))
                                .font(.rounded(10, .medium))
                                .foregroundStyle(Theme.warning)
                        case .dismissed:
                            Text(String(localized: "штраф не пришёл"))
                                .font(.rounded(10, .medium))
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
        .statCard(padding: 12, radius: Theme.cornerMedium)
    }
}

/// Кнопка-строка проезда: если координата камеры сохранена — тап открывает
/// карту проезда; у старых записей без координат остаётся простая строка.
struct PassRowButton: View {
    let pass: PassedCamera
    var onTap: ((PassedCamera) -> Void)?

    var body: some View {
        if pass.coordinate != nil, let onTap {
            Button { onTap(pass) } label: {
                PassRow(pass: pass, showsChevron: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            PassRow(pass: pass)
        }
    }
}

// MARK: - Силуэт трека (Canvas): деталка-плейсхолдер, спарклайны, шеринг-карточка

struct TrackCanvas: View {
    let points: [TrackPoint]
    var passes: [PassedCamera] = []
    var lineWidth: CGFloat = 3

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
            context.stroke(path, with: .linearGradient(
                Gradient(colors: [Theme.accent, Theme.Types.intelligent]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            // Старт и финиш.
            let start = project(points[0].lat, points[0].lon)
            context.fill(Path(ellipseIn: CGRect(x: start.x - 4, y: start.y - 4, width: 8, height: 8)),
                         with: .color(Theme.success))
            let end = project(points[points.count - 1].lat, points[points.count - 1].lon)
            context.fill(Path(ellipseIn: CGRect(x: end.x - 4, y: end.y - 4, width: 8, height: 8)),
                         with: .color(.white))

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
                .navigationTitle(record.startedAt.formatted(date: .abbreviated,
                                                            time: .shortened))
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
    }
}

/// Содержимое деталки без собственной навигации — чтобы её можно было и
/// показать шитом, и втолкнуть в стек разбора рейтинга. Во втором случае
/// «Назад» возвращает в разложение, а не выбрасывает на экран Итогов, как
/// делал шит поверх шита.
struct TripDetailContent: View {
    @Environment(\.dismiss) private var dismiss
    let record: TripRecord
    /// Открыто из разбора рейтинга — показываем, что поездка отняла у периода.
    var rating: TripRatingContext? = nil
    var onRoute: ((CLLocationCoordinate2D, String) -> Void)? = nil
    /// Тап по камере: шит показывает карту проезда, стек разбора — толкает её
    /// следующим уровнем.
    var onOpenPass: ((PassedCamera) -> Void)? = nil

    @State private var shareSubject: ShareSubjectBox?
    @State private var appeared = false

    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
            VStack(spacing: 16) {
                mapSection
                    .entrance(0, appeared)
                ratingCard
                    .entrance(0, appeared)
                scoreRow
                    .entrance(1, appeared)
                scoreBreakdown
                    .entrance(1, appeared)
                statsGrid
                    .entrance(2, appeared)
                TripStopsSection(record: record) { dismiss() }
                    .entrance(3, appeared)
                SpeedProfileChart(record: record)
                    .entrance(3, appeared)
                    .id("chart")
                if !record.passed.isEmpty {
                    passesSection
                        .entrance(4, appeared)
                }
                if let onRoute, let end = record.endCoordinate {
                    PrimaryButton(title: "Повторить маршрут",
                                  systemImage: "arrow.triangle.turn.up.right.circle.fill") {
                        dismiss()
                        onRoute(end, String(localized: "Как в прошлый раз"))
                    }
                    .entrance(4, appeared)
                }
            }
            .padding(20)
            #if DEBUG
            .onAppear {
                // Скриншот-автоматизация: прокрутить к графику скорости.
                guard ProcessInfo.processInfo.arguments.contains("-scrollChart") else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withMotion { proxy.scrollTo("chart", anchor: .top) }
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
        .background(Theme.screenBackground)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { share() } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel(Text("Поделиться поездкой"))
            }
        }
        .sheet(item: $shareSubject) { box in
            SharePreviewSheet(subject: box.subject)
        }
    }

    // MARK: Вклад в рейтинг периода

    /// Смыкает уровни разбора: та же арифметика «недобор × доля», что в списке
    /// вкладов, но здесь рядом с самой поездкой.
    @ViewBuilder private var ratingCard: some View {
        if let rating {
            let item = rating.contribution
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "chart.pie.fill")
                        .font(.rounded(15, .bold))
                        .foregroundStyle(Theme.danger)
                        .frame(width: 32, height: 32)
                        .background(Theme.danger.opacity(0.12), in: Circle())
                    Text(String(format: String(localized: "Вклад в рейтинг %@"),
                                rating.periodCaption))
                        .font(.rounded(15, .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 8)
                    Text(Formatting.points(item.points))
                        .font(.rounded(20, .heavy).monospacedDigit())
                        .foregroundStyle(Theme.danger)
                }
                Text(String(format: String(localized: "Недобор %1$lld баллов × доля %2$lld %% (%3$@ из %4$@ %5$@)"),
                            item.deficit, Int((item.weightShare * 100).rounded()),
                            Formatting.distance(item.distanceMeters),
                            Formatting.distance(rating.periodDistance),
                            rating.periodCaption))
                    .font(.rounded(11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .statCard()
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Карта трека

    @ViewBuilder private var mapSection: some View {
        let points = record.trackPoints
        if points.count >= 2 {
            Map(initialPosition: .rect(trackRect(points))) {
                MapPolyline(coordinates: points.map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                })
                .stroke(LinearGradient(colors: [Theme.accent, Theme.Types.intelligent],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

                ForEach(record.passed) { pass in
                    if let coordinate = pass.coordinate {
                        Annotation("", coordinate: coordinate, anchor: .center) {
                            // Второй носитель на карте — ФОРМА, а не значок:
                            // точка 22 pt мала для глифа, но кольцо от
                            // залитого круга отличается и в оттенках серого.
                            // Залито — превышение, кольцо — чистый проезд.
                            ZStack {
                                let over = PassStyle.symbol(speed: pass.speedKmh,
                                                            limit: pass.limitKmh) != nil
                                let tint = PassStyle.color(speed: pass.speedKmh,
                                                           limit: pass.limitKmh)
                                Circle()
                                    .fill(over ? AnyShapeStyle(tint)
                                               : AnyShapeStyle(Theme.background.opacity(0.85)))
                                    .frame(width: 22, height: 22)
                                Circle()
                                    .stroke(tint, lineWidth: over ? 0 : 3)
                                    .frame(width: 22, height: 22)
                                Text("\(Int(pass.speedKmh.rounded()))")
                                    .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                                    .foregroundStyle(over ? .white : tint)
                            }
                            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
            .frame(height: 250)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1))
            .allowsHitTesting(false)   // статичная витрина: жесты не крадём у скролла
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

    private func trackRect(_ points: [TrackPoint]) -> MKMapRect {
        var rect = MKMapRect.null
        for p in points {
            let mp = MKMapPoint(CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon))
            rect = rect.union(MKMapRect(origin: mp, size: MKMapSize()))
        }
        return rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.15)
    }

    // MARK: Рейтинг поездки и риск штрафов

    @ViewBuilder private var scoreRow: some View {
        let risk = TripHistory.fineRisk(of: record.passed)
        if record.score != nil || risk > 0 {
            HStack(spacing: 14) {
                if let score = record.score {
                    RatingRing(rating: Int(score), compact: true)
                        .frame(width: 56, height: 56)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let score = record.score {
                        Text(DrivingScore.level(for: Int(score)))
                            .font(.rounded(15, .bold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    if risk > 0 {
                        Label("возможные штрафы ≈ \(Formatting.money(risk))",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.danger)
                    } else {
                        Label("Без риска штрафов", systemImage: "checkmark.shield.fill")
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.success)
                    }
                }
                Spacer(minLength: 0)
            }
            .statCard()
        }
    }

    // MARK: Из чего сложился балл

    /// «Почему 68?» — самый частый вопрос к деталке. Раскладываем балл по
    /// строкам: каждая камера со снятыми баллами, потолок, плавность.
    @ViewBuilder private var scoreBreakdown: some View {
        let items = DrivingScore.breakdown(passed: record.passed,
                                           trackSpeeds: record.trackPoints.map(\.speedKmh))
        if record.score != nil, !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(String(localized: "Из чего сложился балл"))
                ForEach(items) { item in
                    penaltyRow(item)
                }
            }
            .statCard()
        }
    }

    /// Строка снятых баллов. Если снял конкретный проезд — строка ведёт к нему:
    /// «−25 за Юнусабад» без возможности посмотреть сам проезд остаётся
    /// утверждением, которое нечем проверить.
    private func penaltyRow(_ item: DrivingScore.Penalty) -> some View {
        // Отрицательные баллы = «вернули» (потолок штрафа) — зелёный плюс.
        let returned = item.points < 0
        let pass = item.passID.flatMap { id in record.passed.first { $0.id == id } }
        let openable = pass != nil && onOpenPass != nil
        return Button {
            if let pass { onOpenPass?(pass) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.rounded(15, .bold))
                    .foregroundStyle(returned ? Theme.success : Theme.danger)
                    .frame(width: 30, height: 30)
                    .background((returned ? Theme.success : Theme.danger).opacity(0.12),
                                in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let detail = item.detail {
                        Text(detail)
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(returned ? "+\(-item.points)" : "−\(item.points)")
                    .font(.rounded(15, .heavy).monospacedDigit())
                    .foregroundStyle(returned ? Theme.success : Theme.danger)
                if openable {
                    Image(systemName: "chevron.right")
                        .font(.rounded(11, .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!openable)
        .accessibilityElement(children: .combine)
    }

    // MARK: Метрики

    private var statsGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 12) {
            StatTile(value: "\(record.camerasPassed)", label: "камер пройдено",
                     icon: "camera.metering.center.weighted", color: Theme.accent)
            StatTile(value: Formatting.distance(record.distanceMeters), label: "пройдено пути",
                     icon: "point.topleft.down.to.point.bottomright.curvepath", color: Theme.success)
            StatTile(value: "\(Int(record.maxSpeedKmh))", label: "макс. км/ч",
                     icon: "gauge.with.dots.needle.100percent", color: Theme.danger)
            StatTile(value: "\(Int(record.averageSpeedKmh))", label: "средняя км/ч",
                     icon: "gauge.with.dots.needle.33percent", color: Theme.warning)
            // Цена поездки в заряде — цифрой, а не верой (есть не у всех записей).
            if let drop = record.batteryDropPercent {
                StatTile(value: "−\(drop) %", label: "заряда за поездку",
                         icon: "battery.75percent", color: Theme.success)
            }
        }
    }

    private var passesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(String(localized: "Пройденные камеры"))
            ForEach(record.passed.reversed()) { pass in
                PassRowButton(pass: pass, onTap: onOpenPass)
            }
        }
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

/// Карточка для шеринга (рендерится в картинку 1080×1350): настоящая карта с треком,
/// при офлайне — неоновый трек на тёмном фоне.
struct TripShareCard: View {
    let record: TripRecord
    var mapImage: UIImage? = nil
    var format: ShareFormat = .feed

    var body: some View {
        ShareCardShell(subtitle: record.startedAt.formatted(date: .abbreviated, time: .shortened),
                       format: format) {
            Group {
                if let mapImage {
                    ShareMapFrame(image: mapImage, height: format == .story ? 430 : 300)
                } else {
                    TrackCanvas(points: record.trackPoints, passes: record.passed, lineWidth: 5)
                        .frame(maxWidth: .infinity)
                        .frame(height: format == .story ? 430 : 300)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1))
                }
            }
            // Рейтинг — бейджем на карте: главная цифра поездки видна сразу.
            .overlay(alignment: .topTrailing) {
                if let score = record.score { scoreBadge(Int(score)) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            // Вывод одной строкой: четыре равнозначных числа ничего не
            // рассказывают, а «все камеры в лимите» — рассказывает. Тот же
            // приём, что у карточки периода: сначала итог, потом цифры.
            Spacer(minLength: 12)

            verdictChip
                .padding(.bottom, 16)

            HStack(spacing: 0) {
                ShareMetric(value: Formatting.duration(record.duration),
                            label: String(localized: "в пути"),
                            icon: "clock.fill", tint: Theme.accent)
                ShareMetricDivider()
                ShareMetric(value: Formatting.distance(record.distanceMeters),
                            label: String(localized: "путь"),
                            icon: "point.topleft.down.to.point.bottomright.curvepath",
                            tint: Theme.success)
                ShareMetricDivider()
                ShareMetric(value: "\(record.camerasPassed)",
                            label: String(localized: "камер"),
                            icon: "camera.fill", tint: Theme.Types.camera)
                // Максимальной скорости здесь больше нет: карточкой хвастаются,
                // а «104 км/ч» — это не достижение приложения про штрафы.
                // В деталке поездки она осталась, там это факт, а не витрина.
            }
            .shareMetricsTile()
            .padding(.bottom, 4)
        }
    }

    /// «Все камеры в лимите» или «Риск ≈ … · место» — главный вывод поездки.
    @ViewBuilder private var verdictChip: some View {
        let risk = TripHistory.fineRisk(of: record.passed)
        if risk > 0 {
            let worst = TripHistorySection.worstPenalty(record)
            chip(icon: "exclamationmark.triangle.fill",
                 text: worst.map {
                     String(format: String(localized: "Риск ≈ %1$@ · %2$@"),
                            Formatting.money(risk), $0.place)
                 } ?? String(format: String(localized: "Риск ≈ %@"), Formatting.money(risk)),
                 tint: Theme.danger)
        } else if record.camerasPassed > 0 {
            chip(icon: "checkmark.seal.fill",
                 text: String(localized: "Все камеры в лимите"),
                 tint: Theme.success)
        }
    }

    private func chip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
            Text(text)
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(tint.opacity(0.12), in: Capsule())
    }

    /// Круглый бейдж рейтинга в углу карты (зелёный/жёлтый/красный по величине).
    private func scoreBadge(_ score: Int) -> some View {
        let tint = Theme.score(score)
        return VStack(spacing: 0) {
            Text("\(score)")
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text("рейтинг")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(width: 64, height: 64)
        .background(tint.opacity(0.92), in: Circle())
        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .padding(12)
    }
}
