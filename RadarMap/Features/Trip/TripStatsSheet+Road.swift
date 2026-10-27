//
//  TripStatsSheet+Road.swift
//  RadarMap
//
//  Итоги (31E): «Дорога» — время в пробках и путь выше лимита вне камер.
//  Две строки под деньгами периода; тап — расшифровка «где и когда».
//
//  Всё здесь — своё, с телефона: пробки — по собственным трекам
//  (TrafficTime), превышения — по лимиту дороги, который и так считается в
//  поездке (OverLimit). Слова «штраф» тут нет нарочно: у камер своя карточка.
//

import SwiftUI
import CoreLocation

/// Какую расшифровку открыть — и данные, с которыми её открыли (правило 14:
/// шит объясняет ровно то число, по которому тапнули).
struct RoadHabitPayload: Identifiable {
    enum Kind { case jams, overLimit }
    let id = UUID()
    let kind: Kind
    let summary: PeriodSummary
    let jams: TrafficTime.Period
    let places: [OverLimit.Place]
    let periodTitle: String
}

extension TripStatsSheet {

    /// Строки «Дороги» — только когда есть что сказать: пробок за период
    /// меньше пяти минут или пути с известным лимитом меньше пяти километров
    /// — строки нет, а не «0».
    @ViewBuilder
    func roadRows(_ itogi: ItogiScreen) -> some View {
        let summary = itogi.summary
        if let jam = summary.jamSeconds, jam >= AppConfig.jamMinPeriodSeconds {
            compactRow(symbol: Icon.trafficLayer, tint: Theme.warning,
                       title: String(format: String(localized: "В пробках: %@"), Formatting.duration(jam)),
                       caption: jamCaption(summary: summary, jams: itogi.jams)) {
                roadHabit = payload(.jams, itogi)
            }
            .accessibilityHint(Text("Где и когда"))
        }
        if let share = summary.overLimitShare {
            let clean = summary.overLimitMeters < 1
            compactRow(symbol: "gauge.with.dots.needle.67percent",
                       tint: clean ? Theme.success : Theme.warning,
                       title: clean ? String(localized: "Вне камер — в лимите")
                                    : String(format: String(localized: "Выше лимита вне камер: %@ пути"),
                                             Self.percentText(share)),
                       caption: String(localized: "На 10 км/ч и больше, где лимит дороги известен")) {
                roadHabit = payload(.overLimit, itogi)
            }
            .accessibilityHint(Text("Где чаще"))
        }
    }

    private func payload(_ kind: RoadHabitPayload.Kind, _ itogi: ItogiScreen) -> RoadHabitPayload {
        RoadHabitPayload(kind: kind, summary: itogi.summary, jams: itogi.jams, places: itogi.overLimitPlaces,
                         periodTitle: period.rangeTitle(containing: anchor))
    }

    /// «8 % времени в пути · чаще 08:00–12:00».
    private func jamCaption(summary: PeriodSummary, jams: TrafficTime.Period) -> String {
        var parts: [String] = []
        if summary.movingDuration > 0, let jam = summary.jamSeconds {
            parts.append(String(format: String(localized: "%@ времени в пути"),
                                Self.percentText(min(1, jam / summary.movingDuration))))
        }
        if let peak = jams.peakBlock, peak.share >= AppConfig.insightPeakShare {
            parts.append(String(format: String(localized: "чаще %@"),
                                PeakBlock(index: peak.index, count: 0, share: peak.share).title))
        }
        return parts.joined(separator: " · ")
    }

    /// «6 %», «<1 %»: доля целыми процентами, а ноль с хвостом — не ноль.
    nonisolated static func percentText(_ share: Double) -> String {
        let percent = Int((share * 100).rounded())
        if percent == 0, share > 0 { return String(localized: "меньше 1 %") }
        return "\(percent)\u{00A0}%"
    }

    /// Компактная строка-кнопка «Итогов» — как «Ждут ответа» и «Штрафы».
    func compactRow(symbol: String, tint: Color, title: String, caption: String,
                    action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: symbol, tint: tint, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !caption.isEmpty {
                        Text(caption)
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.rounded(15, .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .statCard(padding: 12, radius: Theme.cornerMedium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// Расшифровка строки «Дороги»: места с названием улицы из своего адресника
/// (без сети, если файл клетки уже скачан), часы и как считали.
struct RoadHabitSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let payload: RoadHabitPayload

    /// Улицы мест — по индексу места; nil — улицу не назвать.
    @State private var streets: [Int: String] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headline
                    placesCard
                    if payload.kind == .jams { hoursCard }
                    explanation
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle(payload.kind == .jams ? String(localized: "Время в пробках")
                                                   : String(localized: "Выше лимита вне камер"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
            .task { await loadStreets() }
        }
        .presentationDetents([.large])
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(payload.periodTitle)
                .font(.rounded(13))
                .foregroundStyle(Theme.textSecondary)
            Text(headlineValue)
                .font(.numeral(30, .heavy))
                .foregroundStyle(Theme.textPrimary)
            Text(headlineCaption)
                .font(.rounded(13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .statCard()
        .accessibilityElement(children: .combine)
    }

    private var headlineValue: String {
        switch payload.kind {
        case .jams:
            return Formatting.duration(payload.summary.jamSeconds ?? 0)
        case .overLimit:
            return payload.summary.overLimitShare.map(TripStatsSheet.percentText) ?? "—"
        }
    }

    private var headlineCaption: String {
        switch payload.kind {
        case .jams:
            return String(format: String(localized: "Стояли и ползли медленнее 10 км/ч, из %@ в пути"),
                          Formatting.duration(payload.summary.movingDuration))
        case .overLimit:
            return String(format: String(localized: "%1$@ из %2$@ пути с известным лимитом"),
                          Formatting.distance(payload.summary.overLimitMeters),
                          Formatting.distance(payload.summary.limitKnownMeters))
        }
    }

    @ViewBuilder
    private var placesCard: some View {
        let rows = placeRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(payload.kind == .jams ? String(localized: "Где стояли дольше всего")
                                                    : String(localized: "Где чаще"))
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        if index > 0 { Divider().overlay(Theme.stroke) }
                        HStack(alignment: .firstTextBaseline) {
                            Text(streets[index] ?? String(localized: "Улица не определена"))
                                .font(.rounded(15, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text(rows[index].value)
                                .font(.rounded(15, .bold).monospacedDigit())
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .padding(.vertical, 10)
                        Text(rows[index].caption)
                            .font(.rounded(13))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.bottom, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .statCard(padding: 14, radius: Theme.cornerMedium)
            }
        }
    }

    private struct PlaceRow {
        let coordinate: CLLocationCoordinate2D
        let value: String
        let caption: String
    }

    private var placeRows: [PlaceRow] {
        switch payload.kind {
        case .jams:
            return payload.jams.places.map { place in
                PlaceRow(coordinate: place.coordinate, value: Formatting.duration(place.seconds),
                         caption: String(localized: "Вставали в пробку: \(place.times) раз"))
            }
        case .overLimit:
            return payload.places.map { place in
                PlaceRow(coordinate: place.coordinate,
                         value: String(format: String(localized: "лимит %lld"), place.limitKmh),
                         caption: String(format: String(localized: "%1$@ · до %2$lld км/ч"),
                                         String(localized: "\(place.times) раз"), Int(place.maxKmh.rounded())))
            }
        }
    }

    @ViewBuilder
    private var hoursCard: some View {
        if let peak = payload.jams.peakBlock {
            HStack(spacing: 12) {
                IconBadge(symbol: "clock.fill", tint: Theme.Icon.time, size: 30)
                Text(String(format: String(localized: "Больше всего — %1$@: %2$@ всех пробок"),
                            PeakBlock(index: peak.index, count: 0, share: peak.share).title,
                            TripStatsSheet.percentText(peak.share)))
                    .font(.rounded(15, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .statCard(padding: 14, radius: Theme.cornerMedium)
            .accessibilityElement(children: .combine)
        }
    }

    private var explanation: some View {
        Text(payload.kind == .jams
             ? String(localized: "Считаем по вашим трекам на телефоне: три минуты подряд медленнее 10 км/ч — пробка, короткий светофор — нет. Заезды по пути (магазин, заправка) не входят. Места и часы — по поездкам последних 30 дней.")
             : String(localized: "Это не про штрафы: путь у камер сюда не входит, у них своя карточка. Считаем по лимиту дороги из OpenStreetMap, когда он известен, и только заметные превышения — на 10 км/ч и больше. С телефона ничего не уходит."))
            .font(.rounded(13))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Улица ближайшего дома — свой адресник, один файл на клетку за проход.
    private func loadStreets() async {
        var found: [Int: String] = [:]
        for (index, row) in placeRows.enumerated() {
            guard let book = await env.roads.addressBook(for: row.coordinate),
                  let address = book.nearest(to: row.coordinate, within: AppConfig.commuteLossNameMeters),
                  !address.street.isEmpty else { continue }
            if Task.isCancelled { return }
            found[index] = StreetName.display(address.street, language: env.settings.appLanguage.mapCode)
        }
        streets = found
    }
}
