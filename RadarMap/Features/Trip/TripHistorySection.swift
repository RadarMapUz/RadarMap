//
//  TripHistorySection.swift
//  RadarMap
//
//  Список поездок на экране Итогов: записи с баллом и мини-треком,
//  сгруппированные по дням. Выборку и заголовок задаёт экран (список подчиняется
//  фильтру периода), здесь только разметка и действия наверх (тап, повтор,
//  удаление).
//

import SwiftUI
import CoreLocation

struct TripHistorySection: View {
    /// «Поездки за неделю» / «за месяц» / «Последние поездки» — приходит сверху.
    let title: String
    let records: [TripRecord]
    let onSelect: (TripRecord) -> Void
    let onRepeat: ((CLLocationCoordinate2D, String) -> Void)?
    let onDelete: (TripRecord) -> Void

    // Недельной карточки-сводки здесь больше нет: те же цифры (и глубже) даёт
    // герой периода наверху Итогов — двух источников правды быть не должно.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title) {
                Text(String(format: String(localized: "Всего: %lld"), records.count))
                    .font(.rounded(12, .medium))
                    .foregroundStyle(Theme.textTertiary)
            }

            ForEach(TripHistory.dayGroups(records), id: \.day) { group in
                Text(Formatting.dayTitle(group.day))
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                ForEach(group.records) { record in
                    row(record)
                }
            }
        }
    }

    /// «1 остановка» / «3 остановки» — русские формы через словарь каталога.
    private func stopsLabel(_ count: Int) -> String {
        String(format: String(localized: "Остановок в пути: %lld"), count)
    }

    private func row(_ record: TripRecord) -> some View {
        Button {
            onSelect(record)   // тап — деталка: карта трека, проезды, шеринг
        } label: {
            HStack(spacing: 12) {
                trackThumbnail(record)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    // Километры, время и камеры одной строкой: справа остаются
                    // только балл и шеврон — раньше там теснились три элемента.
                    HStack(spacing: 6) {
                        Text("\(Formatting.distance(record.distanceMeters)) · \(Formatting.duration(record.duration))")
                            .font(.rounded(12))
                            .foregroundStyle(Theme.textSecondary)
                        if record.camerasPassed > 0 {
                            Label("\(record.camerasPassed)", systemImage: "camera.fill")
                                .font(.rounded(11, .semibold))
                                .foregroundStyle(Theme.accent)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    // Склеенная поездка: сразу видно, что внутри был заезд по пути.
                    if let stops = record.stops, !stops.isEmpty {
                        Label(stopsLabel(stops.count), systemImage: "pause.circle.fill")
                            .font(.rounded(11, .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 8)
                // Балл поездки — цвет по зоне, поездки сравниваешь с одного взгляда.
                if let score = record.score {
                    Text("\(Int(score))")
                        .font(.rounded(14, .heavy).monospacedDigit())
                        .foregroundStyle(Self.scoreColor(Int(score)))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Self.scoreColor(Int(score)).opacity(0.14), in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .statCard(padding: 14, radius: Theme.cornerMedium)
        }
        .buttonStyle(.plain)
        // Лёгкое «проявление» строк при прокрутке — живо, но не мешает.
        .scrollTransition(.interactive(timingCurve: .easeOut)) { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.4)
                .scaleEffect(phase.isIdentity ? 1 : 0.96)
        }
        .contextMenu {
            if let onRepeat, let end = record.endCoordinate {
                Button {
                    onRepeat(end, String(localized: "Как в прошлый раз"))
                } label: {
                    Label("Повторить маршрут", systemImage: "arrow.triangle.turn.up.right.circle")
                }
            }
            Button(role: .destructive) {
                onDelete(record)
            } label: {
                Label("Удалить запись", systemImage: "trash")
            }
        }
    }

    /// Мини-силуэт трека — поездку узнаёшь с одного взгляда.
    @ViewBuilder private func trackThumbnail(_ record: TripRecord) -> some View {
        Group {
            if record.trackPoints.count >= 2 {
                TrackCanvas(points: record.trackPoints, lineWidth: 2)
            } else {
                Image(systemName: "car.side")
                    .font(.rounded(15))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: 44, height: 44)
        .background(Theme.background.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    static func scoreColor(_ score: Int) -> Color {
        switch DrivingScore.tier(for: score) {
        case 2: return Theme.success
        case 1: return Theme.radar
        default: return Theme.danger
        }
    }
}
