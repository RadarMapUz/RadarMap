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
    var onRepeat: ((CLLocationCoordinate2D, String) -> Void)?

    /// Свой стек (6.10): поездка и проезд открываются внутри, «Назад»
    /// возвращает в список. Раньше тап закрывал список и открывал деталку
    /// поверх «Итогов» — назад к списку пути не было.
    @State private var path: [Route] = []
    @State private var onlyFined = false
    @State private var months: [TripArchive.Month] = []

    enum Route: Hashable {
        case trip(Double)
        case pass(trip: Double, pass: UUID)
    }

    private struct Key: Equatable {
        let revision: Int
        let onlyFined: Bool
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if env.trip.history.isEmpty {
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
                        if months.isEmpty, onlyFined {
                            Text("Поездок с превышениями среди сохранённых нет")
                                .font(.rounded(15))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.top, 12)
                        }
                    }
                    ForEach(months, id: \.start) { month in
                        Text(month.start.formatted(.dateTime.month(.wide).year()
                                                    .locale(NumberFormat.locale)))
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .textCase(.uppercase)
                            .padding(.top, 8)
                        // Месяц — одной карточкой со строками, как поездки дня в
                        // «Итогах»: без тени у каждой строки.
                        VStack(spacing: 0) {
                            ForEach(Array(month.records.enumerated()), id: \.element.id) { index, record in
                                if index > 0 { Divider().overlay(Theme.stroke).padding(.leading, 14) }
                                row(record)
                            }
                        }
                        .statCard(padding: 0, radius: Theme.cornerMedium)
                    }
                }
                .padding(20)
            }
            .backport.scrollEdgeEffectStyle(.hard, for: .top)
            .background(Theme.screenBackground)
            .onAppear { env.usage.noteScreen("allTrips") }
            .navigationTitle("Все поездки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withMotion(Motion.standard) { onlyFined.toggle() }
                    } label: {
                        Image(systemName: onlyFined ? "exclamationmark.triangle.fill"
                                                    : "exclamationmark.triangle")
                    }
                    .accessibilityLabel(Text("Только с превышениями"))
                    .accessibilityAddTraits(onlyFined ? .isSelected : [])
                }
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
            .navigationDestination(for: Route.self) { destination($0) }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // Группировка — на смену истории или фильтра, не в body.
        .task(id: Key(revision: env.trip.dataRevision, onlyFined: onlyFined)) {
            months = TripArchive.months(env.trip.history, onlyFined: onlyFined)
        }
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case .trip(let id):
            if let record = env.trip.history.first(where: { $0.id == id }) {
                TripDetailContent(record: record,
                                  onRoute: onRepeat.map { repeatRoute in
                                      { coord, name in dismiss(); repeatRoute(coord, name) }
                                  },
                                  onOpenPass: { path.append(.pass(trip: id, pass: $0.id)) })
                    .navigationTitle(Formatting.tripTitle(record.startedAt))
                    .navigationBarTitleDisplayMode(.inline)
            }
        case .pass(let tripID, let passID):
            if let record = env.trip.history.first(where: { $0.id == tripID }),
               let pass = record.passed.first(where: { $0.id == passID }) {
                PassDetailView(pass: pass, track: record.trackPoints, record: record)
            }
        }
    }

    private var retentionNote: some View {
        Label(String(format: String(localized: "Хранятся последние %lld поездок. Итоги за месяцы считаются по дневным сводкам — они не удаляются."),
                     TripHistory.maxHistory),
              systemImage: "internaldrive")
            .font(.rounded(11))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var homeCoordinate: CLLocationCoordinate2D? {
        env.settings.homePlace?.coordinate
            ?? env.learnedPlaces.first { $0.kind == .home }?.coordinate
    }

    private var workCoordinate: CLLocationCoordinate2D? {
        env.settings.workPlace?.coordinate
            ?? env.learnedPlaces.first { $0.kind == .work }?.coordinate
    }

    private func row(_ record: TripRecord) -> some View {
        let finish = TripArchive.finish(record.endCoordinate, home: homeCoordinate, work: workCoordinate)
        return Button {
            path.append(.trip(record.id))
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(record.startedAt.formatted(.dateTime.day().month(.abbreviated)
                                                          .hour().minute()
                                                          .locale(NumberFormat.locale)))
                            .font(.rounded(14, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        // Куда приехали — «→ Работа»: строку узнают по цели,
                        // а не по времени старта.
                        if let finish {
                            Text(finish == .home ? "→ Дом" : "→ Работа")
                                .font(.rounded(12, .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text("\(Formatting.distance(record.distanceMeters)) · \(Formatting.duration(record.duration))")
                        .font(.rounded(13))
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
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onRepeat, let end = record.endCoordinate {
                Button {
                    dismiss()
                    onRepeat(end, String(localized: "Как в прошлый раз"))
                } label: {
                    Label("Повторить маршрут", systemImage: "arrow.triangle.turn.up.right.circle")
                }
            }
        }
    }
}
