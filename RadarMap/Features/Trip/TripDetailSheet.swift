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
    /// Цвет скорости: если лимит дороги известен — по реальному превышению,
    /// иначе по универсальным порогам города/трассы.
    static func color(speed: Double, limit: Int?) -> Color {
        if let limit {
            let over = speed - Double(limit)
            if over <= 2 { return Theme.success }
            if over <= 12 { return Theme.radar }
            return Theme.danger
        }
        switch speed {
        case ..<90:    return Theme.success
        case 90..<110: return Theme.radar
        default:       return Theme.danger
        }
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
                .font(.rounded(13, .bold))
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
                ZStack {
                    Circle().fill(.white)
                    Circle().strokeBorder(Color(red: 0.85, green: 0.05, blue: 0.1), lineWidth: 2.5)
                    Text("\(limit)")
                        .font(.system(size: limit >= 100 ? 8 : 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(.black)
                }
                .frame(width: 26, height: 26)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(pass.speedKmh)) км/ч")
                    .font(.rounded(15, .bold))
                    .foregroundStyle(PassStyle.color(speed: pass.speedKmh, limit: pass.limitKmh))
                // Превышение попало в штрафную ступень — показываем цену вопроса.
                if let limit = pass.limitKmh {
                    let fine = FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
                    if fine > 0 {
                        Text("риск ≈ \(Formatting.money(fine))")
                            .font(.rounded(10, .medium))
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.rounded(11, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
    }
}

/// Кнопка-строка проезда: если координата камеры сохранена — тап открывает
/// карту проезда; у старых записей без координат остаётся простая строка.
struct PassRowButton: View {
    let pass: PassedCamera
    let onTap: (PassedCamera) -> Void

    var body: some View {
        if pass.coordinate != nil {
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
                Gradient(colors: [Theme.accent, Theme.intelligent]),
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

struct TripDetailSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let record: TripRecord
    var onRoute: ((CLLocationCoordinate2D, String) -> Void)? = nil

    @State private var sharePayload: ShareImagePayload?
    @State private var selectedPass: PassedCamera?
    @State private var appeared = false
    /// Выбранная точка профиля скорости (тап/протяжка по графику).
    @State private var selectedKm: Double?

    var body: some View {
        NavigationStack {
            ScrollView {
                ScrollViewReader { proxy in
                VStack(spacing: 16) {
                    mapSection
                        .entrance(0, appeared)
                    scoreRow
                        .entrance(1, appeared)
                    statsGrid
                        .entrance(2, appeared)
                    speedChartSection
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
                        withAnimation { proxy.scrollTo("chart", anchor: .top) }
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
            .background(Theme.background)
            .navigationTitle(record.startedAt.formatted(date: .abbreviated, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { share() } label: { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: $sharePayload) { payload in
            ActivityShareSheet(image: payload.image)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .sheet(item: $selectedPass) { pass in
            PassMapSheet(pass: pass, track: record.trackPoints)
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
                .stroke(LinearGradient(colors: [Theme.accent, Theme.intelligent],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

                ForEach(record.passed) { pass in
                    if let coordinate = pass.coordinate {
                        Annotation("", coordinate: coordinate, anchor: .center) {
                            ZStack {
                                Circle()
                                    .fill(PassStyle.color(speed: pass.speedKmh, limit: pass.limitKmh))
                                    .frame(width: 22, height: 22)
                                Text("\(Int(pass.speedKmh))")
                                    .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                                    .foregroundStyle(.white)
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
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(18)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
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
        let risk = TripStats.fineRisk(of: record.passed)
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
                            .font(.rounded(12, .semibold))
                            .foregroundStyle(Theme.danger)
                    } else {
                        Label("Без риска штрафов", systemImage: "checkmark.shield.fill")
                            .font(.rounded(12, .semibold))
                            .foregroundStyle(Theme.success)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        }
    }

    // MARK: Метрики

    private var statsGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 12) {
            tile("\(record.camerasPassed)", "камер пройдено", "camera.metering.center.weighted", Theme.accent)
            tile(Formatting.distance(record.distanceMeters), "пройдено пути", "point.topleft.down.to.point.bottomright.curvepath", Theme.success)
            tile("\(Int(record.maxSpeedKmh))", "макс. км/ч", "gauge.with.dots.needle.100percent", Theme.danger)
            tile("\(Int(record.averageSpeedKmh))", "средняя км/ч", "gauge.with.dots.needle.33percent", Theme.radar)
        }
    }

    private func tile(_ value: String, _ label: LocalizedStringKey, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.rounded(18, .bold)).foregroundStyle(color)
            Text(value).font(.rounded(28, .bold)).foregroundStyle(Theme.textPrimary)
            Text(label).font(.rounded(12)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
    }

    // MARK: График скорости по маршруту

    private struct SpeedSample: Identifiable {
        let id: Int
        let km: Double
        let speedKmh: Double
    }

    private struct PassMark: Identifiable {
        let id: UUID
        let km: Double
        let speedKmh: Double
        let color: Color
    }

    /// Профиль скорости: дистанция вдоль трека → скорость (точки трека уже прорежены,
    /// ≤400 штук — считается за долю миллисекунды, график статичный).
    private func speedSamples() -> [SpeedSample] {
        let points = record.trackPoints
        guard points.count >= 2 else { return [] }
        var samples: [SpeedSample] = [SpeedSample(id: 0, km: 0, speedKmh: points[0].speedKmh)]
        samples.reserveCapacity(points.count)
        var meters = 0.0
        for i in 1..<points.count {
            meters += GeoMath.fastDistance(points[i - 1].lat, points[i - 1].lon,
                                           points[i].lat, points[i].lon)
            samples.append(SpeedSample(id: i, km: meters / 1000, speedKmh: points[i].speedKmh))
        }
        return samples
    }

    /// Проезды камер на профиле: точка ставится у ближайшей точки трека
    /// и лежит на самой линии (высота — скорость трека в этом месте),
    /// а цвет — честный, по скорости в момент проезда относительно лимита.
    private func passMarks(on samples: [SpeedSample]) -> [PassMark] {
        let points = record.trackPoints
        guard points.count == samples.count, !points.isEmpty else { return [] }
        return record.passed.compactMap { pass in
            guard let lat = pass.lat, let lon = pass.lon else { return nil }
            var bestIndex = 0
            var bestDistance = Double.greatestFiniteMagnitude
            for (index, point) in points.enumerated() {
                let d = GeoMath.fastDistance(lat, lon, point.lat, point.lon)
                if d < bestDistance { bestDistance = d; bestIndex = index }
            }
            return PassMark(id: pass.id,
                            km: samples[bestIndex].km,
                            speedKmh: samples[bestIndex].speedKmh,
                            color: PassStyle.color(speed: pass.speedKmh, limit: pass.limitKmh))
        }
    }

    @ViewBuilder private var speedChartSection: some View {
        let samples = speedSamples()
        if samples.count >= 8 {
            let topSpeed = samples.map(\.speedKmh).max() ?? 60
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Скорость по маршруту")
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "hand.tap.fill").font(.rounded(9))
                        Text("коснитесь графика").font(.rounded(10))
                    }
                    .foregroundStyle(Theme.textTertiary)
                }

                Chart {
                    ForEach(samples) { sample in
                        AreaMark(x: .value("км", sample.km), y: .value("км/ч", sample.speedKmh))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(
                                LinearGradient(colors: [Theme.accent.opacity(0.30), .clear],
                                               startPoint: .top, endPoint: .bottom)
                            )
                        LineMark(x: .value("км", sample.km), y: .value("км/ч", sample.speedKmh))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .foregroundStyle(
                                LinearGradient(colors: [Theme.accent, Theme.intelligent],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                    }
                    ForEach(passMarks(on: samples)) { mark in
                        PointMark(x: .value("км", mark.km), y: .value("км/ч", mark.speedKmh))
                            .symbol {
                                ZStack {
                                    Circle().fill(mark.color)
                                    Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                                }
                                .frame(width: 11, height: 11)
                            }
                    }
                    // Линейка: тап или протяжка — скорость в этой точке маршрута.
                    if let selectedKm, let sample = nearestSample(to: selectedKm, in: samples) {
                        RuleMark(x: .value("км", sample.km))
                            .foregroundStyle(Theme.textTertiary.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                VStack(spacing: 1) {
                                    Text("\(Int(sample.speedKmh)) км/ч")
                                        .font(.rounded(12, .bold).monospacedDigit())
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(String(format: String(localized: "%.1f км"), locale: .current, sample.km))
                                        .font(.rounded(9, .medium))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Theme.background.opacity(0.92),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Theme.stroke, lineWidth: 1))
                            }
                        PointMark(x: .value("км", sample.km), y: .value("км/ч", sample.speedKmh))
                            .symbolSize(120)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .chartXSelection(value: $selectedKm)
                // Запас сверху — пузырёк линейки не упирается в край графика.
                .chartYScale(domain: 0...max(topSpeed * 1.25, 20))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine().foregroundStyle(Theme.stroke.opacity(0.35))
                        AxisValueLabel {
                            if let km = value.as(Double.self) {
                                Text(String(format: String(localized: "%.0f км"), km))
                            }
                        }
                        .foregroundStyle(Theme.textTertiary)
                        .font(.rounded(9, .medium))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Theme.stroke.opacity(0.6))
                        AxisValueLabel()
                            .foregroundStyle(Theme.textTertiary)
                            .font(.rounded(10, .medium))
                    }
                }
                .frame(height: 150)

                // Точки — проезды камер, цвет по честности относительно лимита.
                HStack(spacing: 12) {
                    chartLegendDot(Theme.success, "в лимите")
                    chartLegendDot(Theme.radar, "слегка выше")
                    chartLegendDot(Theme.danger, "превышение")
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        }
    }

    private func nearestSample(to km: Double, in samples: [SpeedSample]) -> SpeedSample? {
        samples.min { abs($0.km - km) < abs($1.km - km) }
    }

    private func chartLegendDot(_ color: Color, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.rounded(11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var passesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Пройденные камеры")
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(record.passed.reversed()) { pass in
                PassRowButton(pass: pass) { selectedPass = $0 }
            }
        }
    }

    // MARK: Шеринг-карточка

    /// Рендерим карточку в момент тапа — данные всегда свежие, открытие не тормозим.
    private func share() {
        let renderer = ImageRenderer(content: TripShareCard(record: record))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 540, height: 675)
        if let uiImage = renderer.uiImage {
            sharePayload = ShareImagePayload(image: uiImage)
        }
    }
}

/// Карточка для шеринга (рендерится в картинку 1080×1350): неоновый трек на тёмном фоне.
struct TripShareCard: View {
    let record: TripRecord

    var body: some View {
        VStack(spacing: 0) {
            // Шапка
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Theme.accent)
                Text("RadarMap")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)

            // Трек
            TrackCanvas(points: record.trackPoints, passes: record.passed, lineWidth: 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)

            // Метрики
            HStack(spacing: 0) {
                if let score = record.score {
                    cardMetric("\(Int(score))", String(localized: "рейтинг"))
                    cardDivider
                }
                cardMetric(Formatting.duration(record.duration), String(localized: "в пути"))
                cardDivider
                cardMetric(Formatting.distance(record.distanceMeters), String(localized: "путь"))
                cardDivider
                cardMetric("\(record.camerasPassed)", String(localized: "камер"))
                cardDivider
                cardMetric("\(Int(record.maxSpeedKmh))", String(localized: "макс. км/ч"))
            }
            .padding(.vertical, 20)
            .background(.white.opacity(0.06))

            Text("Карта камер и навигатор Узбекистана")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.vertical, 14)
        }
        .frame(width: 540, height: 675)
        .background(
            ZStack {
                Theme.background
                RadialGradient(colors: [Theme.accent.opacity(0.14), .clear],
                               center: .center, startRadius: 40, endRadius: 380)
            }
        )
    }

    private func cardMetric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

    private var cardDivider: some View {
        Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 34)
    }
}
