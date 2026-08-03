//
//  TripStopsSection.swift
//  RadarMap
//
//  Остановки склеенной поездки в деталке. Показать их обязательно: приложение
//  само решило, что заезд в магазин — та же поездка, и водитель должен видеть
//  это решение и уметь его отменить одним тапом («Разделить здесь»).
//
//  Названия мест подтягиваются обратным геокодированием лениво, только когда
//  деталку открыли: в поездке это была бы сетевая работа на горячем пути.
//

import SwiftUI
import CoreLocation
import os

struct TripStopsSection: View {
    @Environment(AppEnvironment.self) private var env
    let record: TripRecord
    /// Вызывается после разделения — деталку надо закрыть, записи больше нет.
    let onSplit: () -> Void

    @State private var titles: [UUID: String] = [:]
    @State private var splitCandidate: TripStop?

    private var stops: [TripStop] { record.stops ?? [] }

    var body: some View {
        if !stops.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    ForEach(stops) { stop in
                        row(stop)
                        if stop.id != stops.last?.id {
                            Rectangle()
                                .fill(Theme.textTertiary.opacity(0.18))
                                .frame(height: 1)
                        }
                    }
                }
            }
            .task { await loadTitles() }
            .confirmationDialog("Разделить поездку на две?",
                                isPresented: .constant(splitCandidate != nil),
                                titleVisibility: .visible) {
                Button("Разделить", role: .destructive) {
                    guard let stop = splitCandidate else { return }
                    splitCandidate = nil
                    env.trip.splitRecord(id: record.id, at: stop)
                    onSplit()
                }
                Button("Отмена", role: .cancel) { splitCandidate = nil }
            } message: {
                Text("Всё до этой остановки станет одной поездкой, всё после — другой.")
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Остановки в пути", systemImage: "pause.circle.fill")
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("\(stops.count)")
                .font(.rounded(13, .bold))
                .foregroundStyle(Theme.accent)
        }
    }

    private func row(_ stop: TripStop) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(Formatting.duration(stop.duration))
                    .font(.rounded(17, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Разделить здесь") { splitCandidate = stop }
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(PressableStyle())
            }
            Text(subtitle(for: stop))
                .font(.rounded(12))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private func subtitle(for stop: TripStop) -> String {
        let window = stop.from.formatted(date: .omitted, time: .shortened)
            + " – " + stop.to.formatted(date: .omitted, time: .shortened)
        guard let place = titles[stop.id], !place.isEmpty else { return window }
        return "\(place) · \(window)"
    }

    /// Обратное геокодирование ≤6 остановок (потолок склейки) — по одной,
    /// последовательно: CLGeocoder не любит параллельные запросы.
    private func loadTitles() async {
        let geocoder = CLGeocoder()
        for stop in stops where titles[stop.id] == nil {
            let location = CLLocation(latitude: stop.lat, longitude: stop.lon)
            do {
                let marks = try await geocoder.reverseGeocodeLocation(location)
                guard let mark = marks.first else { continue }
                let name = mark.name ?? [mark.thoroughfare, mark.subThoroughfare]
                    .compactMap(\.self).joined(separator: ", ")
                if !name.isEmpty { titles[stop.id] = name }
            } catch {
                // Нет сети или лимит геокодера — покажем только время, это не ошибка.
                Log.trips.debug("геокодер остановки: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
