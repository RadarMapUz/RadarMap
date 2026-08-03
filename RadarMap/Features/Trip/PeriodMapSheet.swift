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
    let tracks: [[TrackPoint]]
    let markers: [PassMarker]
    /// Открыть сразу с выбранной камерой (тап по зоне риска).
    var focus: PassMarker? = nil

    @State private var selected: PassMarker?
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
            .animation(.spring(duration: 0.3), value: selected)
            .navigationTitle("Карта проездов")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
            } else if let rect = Self.boundingRect(tracks: tracks, markers: markers) {
                position = .rect(rect)
            }
        }
    }

    private var map: some View {
        Map(position: $position) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                MapPolyline(coordinates: track.map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                })
                .stroke(Theme.accent.opacity(0.75),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            ForEach(markers) { marker in
                Annotation("", coordinate: marker.coordinate, anchor: .center) {
                    markerDot(marker, isSelected: selected?.id == marker.id)
                        .onTapGesture {
                            selected = selected?.id == marker.id ? nil : marker
                        }
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
                .fill(marker.hasViolation ? Theme.danger : Theme.success)
                .frame(width: size, height: size)
            if marker.times > 1 {
                Text("\(marker.times)")
                    .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .overlay(Circle().stroke(.white.opacity(isSelected ? 1 : 0.85),
                                 lineWidth: isSelected ? 3 : 1.5))
        .scaleEffect(isSelected ? 1.25 : 1)
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        .accessibilityLabel(Text(marker.location))
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
                            .font(.rounded(12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        selected = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.rounded(20))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .accessibilityLabel(Text("Закрыть"))
                }
                HStack(spacing: 10) {
                    speedBadge(marker)
                    if marker.hasViolation {
                        Label(String(format: String(localized: "превышений: %lld"),
                                     marker.overTimes),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.rounded(12, .semibold))
                            .foregroundStyle(Theme.danger)
                    } else {
                        Label("все проезды в лимите", systemImage: "checkmark.seal.fill")
                            .font(.rounded(12, .semibold))
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
                .foregroundStyle(marker.hasViolation ? Theme.danger : Theme.success)
            if let limit = marker.limitKmh {
                Text("/ \(limit)")
                    .font(.rounded(13, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            Text("км/ч")
                .font(.rounded(10, .medium))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background((marker.hasViolation ? Theme.danger : Theme.success).opacity(0.12),
                    in: Capsule())
    }

    private func passCount(_ marker: PassMarker) -> String {
        String(format: String(localized: "Проездов за период: %lld"), marker.times)
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
