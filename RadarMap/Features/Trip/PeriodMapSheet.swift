//
//  PeriodMapSheet.swift
//  RadarMap
//
//  «Где я превышал» — полноэкранная интерактивная карта периода: все треки,
//  все пройденные камеры (зелёная — в лимите, красная — с превышением, размер
//  и цифра по числу проездов). Тап по маркеру — карточка места: сколько раз
//  проезжал, макс скорость против лимита. Зона риска в Итогах открывает эту
//  карту сразу сфокусированной на «своей» камере.
//
//  Данные приходят готовыми из TripHistory (треки и маркеры) — вьюха не
//  считает ничего, кроме рамки камеры.
//

import SwiftUI
import MapKit
import CoreLocation

struct PeriodMapSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Треки, камеры и слой частоты — ровно то же, что показывает превью Итогов
    /// (включая режим одной выбранной поездки).
    let data: PeriodMapData
    /// Открыть сразу с выбранной камерой (тап по зоне риска).
    var focus: PassMarker? = nil
    /// Окно, за которое карта: «19–25 октября» под заголовком (6.8) — на
    /// полноэкранной карте период из шапки «Итогов» уже не виден.
    var periodTitle: String? = nil

    @State private var selected: PassMarker?
    /// «Только превышения»: из полусотни зелёных точек найти три красные.
    @State private var onlyViolations = false
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                map
                if let marker = selected {
                    markerCard(marker)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .motionAnimation(Motion.standard, value: selected)
            .navigationTitle("Карта проездов")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let periodTitle {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text("Карта проездов").font(.rounded(15, .semibold))
                            Text(periodTitle)
                                .font(.rounded(11))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                if data.markers.contains(where: \.hasViolation),
                   data.markers.contains(where: { !$0.hasViolation }) {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            withMotion(Motion.standard) {
                                onlyViolations.toggle()
                                if onlyViolations, selected?.hasViolation == false { selected = nil }
                            }
                        } label: {
                            Image(systemName: onlyViolations ? "exclamationmark.triangle.fill"
                                                             : "exclamationmark.triangle")
                        }
                        .accessibilityLabel(Text("Только превышения"))
                        .accessibilityAddTraits(onlyViolations ? .isSelected : [])
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            selected = focus
            if let focus {
                // Фокус на зоне риска: близко, чтобы было видно улицу.
                position = .region(MKCoordinateRegion(
                    center: focus.coordinate,
                    latitudinalMeters: 1200, longitudinalMeters: 1200))
            } else if let rect = Self.boundingRect(tracks: data.tracks, markers: data.markers) {
                position = .rect(rect)
            }
        }
    }

    private var map: some View {
        Map(position: $position) {
            // Слой частоты: постоянный коридор ярче и толще разовой поездки.
            // Пусто (одна выбранная поездка) — рисуем её трек в полную яркость.
            if data.heat.isEmpty {
                ForEach(Array(data.tracks.enumerated()), id: \.offset) { _, track in
                    MapPolyline(coordinates: track.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                    })
                    .stroke(Theme.background.opacity(0.8), style: Self.stroke(width: 9))
                }
                ForEach(Array(data.tracks.enumerated()), id: \.offset) { _, track in
                    MapPolyline(coordinates: track.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                    })
                    .stroke(Theme.route, style: Self.stroke(width: 4.5))
                }
            } else {
                ForEach(data.heat) { line in
                    if line.tier > 0 {
                        MapPolyline(coordinates: line.coordinates)
                            .stroke(Theme.background.opacity(0.7),
                                    style: Self.stroke(width: line.tier == 2 ? 9 : 7))
                    }
                }
                ForEach(data.heat) { line in
                    MapPolyline(coordinates: line.coordinates)
                        .stroke(Theme.route.opacity(line.tier == 2 ? 1
                                                     : line.tier == 1 ? 0.75 : 0.55),
                                style: Self.stroke(width: line.tier == 2 ? 5.5
                                                          : line.tier == 1 ? 4 : 2.5))
                }
            }
            ForEach(onlyViolations ? data.markers.filter(\.hasViolation) : data.markers) { marker in
                Annotation("", coordinate: marker.coordinate, anchor: .center) {
                    markerDot(marker, isSelected: selected?.id == marker.id)
                        // Кружок от 20 pt, а палец — 44: мишень растёт, рисунок
                        // нет. И это кнопка (открывает карточку) — VoiceOver
                        // должен так её и назвать, а не читать как картинку.
                        .tapTarget()
                        .onTapGesture {
                            selected = selected?.id == marker.id ? nil : marker
                        }
                        .accessibilityAddTraits(selected?.id == marker.id
                                                ? [.isButton, .isSelected] : .isButton)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll,
                            showsTraffic: false))
    }

    /// Размер кружка растёт с числом проездов: где катаешься чаще — виднее.
    private func markerDot(_ marker: PassMarker, isSelected: Bool) -> some View {
        let size = min(34.0, 20 + Double(marker.times) * 2.5)
        return ZStack {
            Circle()
                .fill(Self.tint(marker))
                .frame(width: size, height: size)
            if marker.times > 1 {
                Text("\(marker.times)")
                    .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                    // Заливки состояний ночью светлые — белая цифра на них не
                    // читалась бы; Theme.background контрастен в обеих темах.
                    .foregroundStyle(Theme.background)
            }
        }
        .overlay(Circle().stroke(.white.opacity(isSelected ? 1 : 0.85),
                                 lineWidth: isSelected ? 3 : 1.5))
        .scaleEffect(isSelected ? 1.25 : 1)
        // Без тени: белое кольцо и так отделяет точку от подложки, а тень на
        // составном маркере размывала отдельно круг и цифру — по два прохода
        // на каждую из сотен точек при каждом сдвиге карты.
        // Цвет маркера — единственное, что говорит о превышении; имя места
        // без этого не отвечает на вопрос, ради которого открыли карту.
        .accessibilityLabel(marker.hasViolation
            ? Text("\(marker.location), превышений: \(marker.overTimes) из \(marker.times)")
            : marker.limitUnknown
                ? Text("\(marker.location), лимит неизвестен, проездов: \(marker.times)")
                : Text("\(marker.location), без превышений, проездов: \(marker.times)"))
    }

    /// Красный — превышение, зелёный — в лимите, серый — лимит неизвестен:
    /// зелёным такую точку красить нельзя, «в лимите» мы о ней не знаем.
    static func tint(_ marker: PassMarker) -> Color {
        if marker.hasViolation { return Theme.danger }
        return marker.limitUnknown ? Theme.textTertiary : Theme.success
    }

    /// Карточка выбранной камеры: место, проезды, макс скорость против лимита.
    private func markerCard(_ marker: PassMarker) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(marker.location.isEmpty ? String(localized: "Камера") : marker.location)
                            .font(.rounded(15, .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        Text(passCount(marker))
                            .font(.rounded(15))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        selected = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.rounded(20))
                            .foregroundStyle(Theme.textTertiary)
                            .tapTarget()
                    }
                    .accessibilityLabel(Text("Закрыть"))
                }
                HStack(spacing: 10) {
                    speedBadge(marker)
                    if marker.hasViolation {
                        Label(String(format: String(localized: "превышений: %lld"),
                                     marker.overTimes),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.danger)
                    } else if marker.limitUnknown {
                        Label("лимит неизвестен", systemImage: "questionmark.circle.fill")
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Label("все проезды в лимите", systemImage: "checkmark.seal.fill")
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.success)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// «макс 82 · лимит 60» — суть проезда одним взглядом.
    private func speedBadge(_ marker: PassMarker) -> some View {
        HStack(spacing: 5) {
            Text("\(Int(marker.maxSpeedKmh.rounded()))")
                .font(.rounded(17, .heavy).monospacedDigit())
                .foregroundStyle(marker.limitUnknown ? Theme.textPrimary : Self.tint(marker))
            if let limit = marker.limitKmh {
                Text("/ \(limit)")
                    .font(.rounded(15, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            Text("км/ч")
                .font(.rounded(10, .medium))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Self.tint(marker).opacity(0.12), in: Capsule())
    }

    private func passCount(_ marker: PassMarker) -> String {
        String(format: String(localized: "Проездов за период: %lld"), marker.times)
    }

    private static func stroke(width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    /// Общая рамка всех треков и маркеров периода. nil — рисовать нечего.
    static func boundingRect(tracks: [[TrackPoint]], markers: [PassMarker]) -> MKMapRect? {
        var rect = MKMapRect.null
        for track in tracks {
            for point in track {
                let mp = MKMapPoint(CLLocationCoordinate2D(latitude: point.lat,
                                                           longitude: point.lon))
                rect = rect.union(MKMapRect(origin: mp, size: MKMapSize()))
            }
        }
        for marker in markers {
            rect = rect.union(MKMapRect(origin: MKMapPoint(marker.coordinate),
                                        size: MKMapSize()))
        }
        guard !rect.isNull else { return nil }
        // Совсем короткая поездка вырождается в точку — не даём карте уйти в бесконечный зум.
        let padX = max(rect.width * 0.15, 400)
        let padY = max(rect.height * 0.15, 400)
        return rect.insetBy(dx: -padX, dy: -padY)
    }
}
