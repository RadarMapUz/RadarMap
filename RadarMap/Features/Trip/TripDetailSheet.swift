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
            Text("\(Int(pass.speedKmh)) км/ч")
                .font(.rounded(15, .bold))
                .foregroundStyle(PassStyle.color(speed: pass.speedKmh, limit: pass.limitKmh))
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
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

    @State private var shareImage: Image?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    mapSection
                    statsGrid
                    if !record.passed.isEmpty { passesSection }
                    if let onRoute, let end = record.endCoordinate {
                        PrimaryButton(title: "Повторить маршрут",
                                      systemImage: "arrow.triangle.turn.up.right.circle.fill") {
                            dismiss()
                            onRoute(end, String(localized: "Как в прошлый раз"))
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle(record.startedAt.formatted(date: .abbreviated, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if let shareImage {
                        ShareLink(item: shareImage,
                                  preview: SharePreview(String(localized: "Поездка RadarMap"),
                                                        image: shareImage)) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .task { renderShareCard() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
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

    private var passesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Пройденные камеры")
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(record.passed.reversed()) { pass in
                PassRow(pass: pass)
            }
        }
    }

    // MARK: Шеринг-карточка

    private func renderShareCard() {
        let renderer = ImageRenderer(content: TripShareCard(record: record))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 540, height: 675)
        if let uiImage = renderer.uiImage {
            shareImage = Image(uiImage: uiImage)
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
