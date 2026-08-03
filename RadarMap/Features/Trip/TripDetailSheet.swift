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
    /// Цвет скорости: если лимит дороги известен — по штрафным ступеням КоАО
    /// (жёлтый — выше лимита, но в допуске; красный — уже штраф),
    /// иначе по универсальным порогам города/трассы.
    static func color(speed: Double, limit: Int?) -> Color {
        if let limit {
            let over = speed - Double(limit)
            if over <= 2 { return Theme.success }
            if FineSchedule.fine(overKmh: over) == 0 { return Theme.radar }
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
                SpeedLimitSign(limit: limit, diameter: 26)
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
        .statCard(padding: 12, radius: Theme.cornerMedium)
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
                        .accessibilityLabel(Text("Поделиться поездкой"))
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
            .statCard()
        }
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
                     icon: "gauge.with.dots.needle.33percent", color: Theme.radar)
        }
    }

    private var passesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(String(localized: "Пройденные камеры"))
            ForEach(record.passed.reversed()) { pass in
                PassRowButton(pass: pass) { selectedPass = $0 }
            }
        }
    }

    // MARK: Шеринг-карточка

    /// Рендерим карточку в момент тапа — данные всегда свежие, открытие не тормозим.
    /// Сначала асинхронно снимаем карту с треком (информативно: виден район и улицы),
    /// затем карточку в картинку. Карта не загрузилась (офлайн) — фолбэк на неоновый трек.
    private func share() {
        Task {
            let map = await TripMapSnapshot.render(track: record.trackPoints,
                                                   passes: record.passed,
                                                   size: CGSize(width: 1032, height: 840))
            let renderer = ImageRenderer(content: TripShareCard(record: record, mapImage: map))
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(width: 540, height: 675)
            if let uiImage = renderer.uiImage {
                sharePayload = ShareImagePayload(image: uiImage)
            }
        }
    }
}

/// Карточка для шеринга (рендерится в картинку 1080×1350): настоящая карта с треком,
/// при офлайне — неоновый трек на тёмном фоне.
struct TripShareCard: View {
    let record: TripRecord
    var mapImage: UIImage? = nil

    var body: some View {
        ShareCardShell(subtitle: record.startedAt.formatted(date: .abbreviated, time: .shortened)) {
            Group {
                if let mapImage {
                    Image(uiImage: mapImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    TrackCanvas(points: record.trackPoints, passes: record.passed, lineWidth: 5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1))
            // Рейтинг — бейджем на карте: главная цифра поездки видна сразу.
            .overlay(alignment: .topTrailing) {
                if let score = record.score { scoreBadge(Int(score)) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

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
                            icon: "camera.fill", tint: Theme.camera)
                ShareMetricDivider()
                ShareMetric(value: "\(Int(record.maxSpeedKmh))",
                            label: String(localized: "макс. км/ч"),
                            icon: "gauge.with.dots.needle.67percent", tint: Theme.radar)
            }
            .shareMetricsTile()
            .padding(.bottom, 4)
        }
    }

    /// Круглый бейдж рейтинга в углу карты (зелёный/жёлтый/красный по величине).
    private func scoreBadge(_ score: Int) -> some View {
        let tint: Color = score >= 80 ? Theme.success : score >= 55 ? Theme.radar : Theme.danger
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
