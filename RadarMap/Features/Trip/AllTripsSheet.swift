//
//  AllTripsSheet.swift
//  RadarMap
//
//  Все сохранённые поездки, сгруппированные по месяцам.
//
//  Появился вместе с уходом сегмента «Всё время» из фильтра периода: тот
//  обещал показать всю историю, а показывал последние 50 записей — данные
//  чистятся (треки через неделю, записи через 30 дней). Здесь честная
//  формулировка: это то, что реально хранится, а пожизненные цифры — рядом,
//  в блоке «За всё время».
//

import SwiftUI
import CoreLocation

struct AllTripsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var onOpenDetail: (TripRecord) -> Void
    var onRepeat: ((CLLocationCoordinate2D, String) -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if months.isEmpty {
                        // История очищена или её ещё нет: экран, открывшийся
                        // пустым, читается как сбой, а не как «поездок нет».
                        VStack(spacing: 8) {
                            Image(systemName: "car.side")
                                .font(.rounded(34))
                                .foregroundStyle(Theme.textTertiary)
                            Text("Поездок пока нет")
                                .font(.rounded(17, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Первая появится здесь сразу после того, как вы доедете.")
                                .font(.rounded(15))
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        retentionNote
                    }
                    ForEach(months, id: \.title) { month in
                        Text(month.title)
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .textCase(.uppercase)
                            .padding(.top, 8)
                        ForEach(month.records) { record in
                            row(record)
                        }
                    }
                }
                .padding(20)
            }
            .backport.scrollEdgeEffectStyle(.hard, for: .top)
            .background(Theme.screenBackground)
            .navigationTitle("Все поездки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// Честно говорим, почему список не бесконечный, — иначе это выглядит багом.
    private var retentionNote: some View {
        Label(String(format: String(localized: "Хранятся последние %lld поездок. Итоги за месяцы считаются по дневным сводкам — они не удаляются."),
                     TripHistory.maxHistory),
              systemImage: "internaldrive")
            .font(.rounded(11))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private struct Month {
        let title: String
        let records: [TripRecord]
    }

    /// Группировка по календарным месяцам, порядок истории (новые сверху).
    private var months: [Month] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byMonth: [Date: [TripRecord]] = [:]
        for record in env.trip.history {
            let key = calendar.dateInterval(of: .month, for: record.startedAt)?.start
                ?? calendar.startOfDay(for: record.startedAt)
            if byMonth[key] == nil { order.append(key) }
            byMonth[key, default: []].append(record)
        }
        return order.map { key in
            Month(title: key.formatted(.dateTime.month(.wide).year()),
                  records: byMonth[key] ?? [])
        }
    }

    private func row(_ record: TripRecord) -> some View {
        Button {
            onOpenDetail(record)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(Formatting.distance(record.distanceMeters)) · \(Formatting.duration(record.duration))")
                        .font(.rounded(15))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                if let score = record.score {
                    Text("\(Int(score))")
                        .font(.rounded(14, .heavy).monospacedDigit())
                        .foregroundStyle(TripHistorySection.scoreColor(Int(score)))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(TripHistorySection.scoreColor(Int(score)).opacity(0.14),
                                    in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .statCard(padding: 14, radius: Theme.cornerMedium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onRepeat, let end = record.endCoordinate {
                Button {
                    onRepeat(end, String(localized: "Как в прошлый раз"))
                } label: {
                    Label("Повторить маршрут", systemImage: "arrow.triangle.turn.up.right.circle")
                }
            }
        }
    }
}
