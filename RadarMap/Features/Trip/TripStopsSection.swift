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
            // `.statCard()`, а не `GlassCard`: это единственный блок деталки,
            // который заворачивался в стекло, а `GlassCard` внутренних отступов
            // НЕ ДАЁТ вовсе — он только рисует подложку и кромку. Отсюда текст
            // вплотную к границам и обрезанное «Разделить здесь». Соседние
            // карточки Итогов идут через statCard, у которого padding и фон
            // общие для всех, — ровно ради этого он и заведён.
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .statCard()
            .task { await loadTitles() }
            // Живой Binding, не .constant: закрытие диалога системой (тап мимо,
            // свайп) пишет false именно в биндинг, и с .constant кандидат
            // оставался непустым — диалог залипал и переоткрывался.
            .confirmationDialog("Разделить поездку на две?",
                                isPresented: Binding(
                                    get: { splitCandidate != nil },
                                    set: { if !$0 { splitCandidate = nil } }),
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
                .font(.rounded(15, .bold))
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
                Button {
                    splitCandidate = stop
                } label: {
                    // Мишень внутри label: модификаторы снаружи кнопки область
                    // касания не растят, и строка в 15 pt оставалась ~20 pt.
                    Text("Разделить здесь")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.accent)
                        .tapTarget()
                }
                .buttonStyle(PressableStyle())
            }
            Text(subtitle(for: stop))
                .font(.rounded(15))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private func subtitle(for stop: TripStop) -> String {
        let window = Formatting.clock(stop.from)
            + " – " + Formatting.clock(stop.to)
        guard let place = titles[stop.id], !place.isEmpty else { return window }
        return "\(place) · \(window)"
    }

    /// Название остановки — сначала из своего адресника на языке приложения
    /// (как булавка «Мои места» и поиск, 6.5), Apple — только если своего
    /// дома рядом нет и есть сеть. ≤6 остановок (потолок склейки) — по одной,
    /// последовательно: CLGeocoder не любит параллельные запросы.
    private func loadTitles() async {
        let geocoder = CLGeocoder()
        for stop in stops where titles[stop.id] == nil {
            let point = CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)
            if let book = await env.roads.addressBook(for: point),
               let address = book.nearest(to: point, within: AppConfig.placePickerAddressMeters) {
                let street = StreetName.display(address.street, language: env.settings.appLanguage.mapCode)
                titles[stop.id] = address.house.isEmpty ? street : "\(street), \(address.house)"
                continue
            }
            guard env.network.isOnline else { continue }
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
