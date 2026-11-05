//
//  TripStatsSheet+Road.swift
//  RadarMap
//
//  Итоги (31E, 34b): «Пробки и лимит» — время в пробках и путь выше лимита
//  вне камер. Одна строка раздела; тап — лист «где и когда» с вкладками.
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

    /// Данные листа «Пробки и лимит» — с той же сводкой, что строка раздела.
    func payload(_ kind: RoadHabitPayload.Kind, _ itogi: ItogiScreen) -> RoadHabitPayload {
        RoadHabitPayload(kind: kind, summary: itogi.summary, jams: itogi.jams, places: itogi.overLimitPlaces,
                         periodTitle: period.rangeTitle(containing: anchor))
    }

    /// «36 %», «меньше 1 %» — неразрывно с процентом.
    nonisolated static func percentText(_ share: Double) -> String {
        let percent = Int((share * 100).rounded())
        if percent == 0, share > 0 { return String(localized: "меньше 1 %") }
        return "\(percent)\u{00A0}%"
    }
}

/// Лист «Пробки и лимит» (34b): одна строка раздела — один лист, две
/// вкладки, если есть и то, и другое. Раньше это были две строки и два входа.
struct RoadHabitSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let payload: RoadHabitPayload
    @State private var kind: RoadHabitPayload.Kind = .jams
    @State private var chosen = false

    /// Строки мест с подписью улицы — после адресника, слитые по улице (34):
    /// две пробки на одной улице были двумя строками «улица Навои» подряд.
    /// nil — адресник ещё читается, показываем места без слияния.
    @State private var named: [PlaceRow]?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if hasJams && hasOverLimit {
                        Picker("", selection: $kind) {
                            Text("Пробки").tag(RoadHabitPayload.Kind.jams)
                            Text("Скорость вне камер").tag(RoadHabitPayload.Kind.overLimit)
                        }
                        .pickerStyle(.segmented)
                    }
                    headline
                    placesCard
                    if kind == .jams { hoursCard }
                    explanation
                }
                .padding(20)
            }
            .background(Theme.background)
            // Заголовок — той строки, с которой пришли (аудит 05.11: две строки
            // «Пробки» и «Скорость вне камер» вместо одной «Пробки и лимит»).
            .navigationTitle(Text(kind == .jams ? String(localized: "Пробки")
                                                : String(localized: "Скорость вне камер")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
            .task(id: kind) {
                named = nil
                await loadStreets()
            }
        }
        .presentationDetents([.large])
        .onAppear {
            guard !chosen else { return }
            chosen = true
            // Вкладка — той строки, с которой пришли (было `kind = kind`, и
            // «Скорость вне камер» открывалась на «Пробках»).
            kind = payload.kind
        }
    }

    private var hasJams: Bool {
        (payload.summary.jamSeconds ?? 0) >= AppConfig.jamMinPeriodSeconds
    }
    private var hasOverLimit: Bool { payload.summary.overLimitShare != nil }

    /// Подпись листа — то, что раньше было названием: «Время в пробках».
    private var kindTitle: String {
        kind == .jams ? String(localized: "Время в пробках") : String(localized: "Выше лимита вне камер")
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kindTitle + " · " + payload.periodTitle)
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
        switch kind {
        case .jams:
            return Formatting.duration(payload.summary.jamSeconds ?? 0)
        case .overLimit:
            return payload.summary.overLimitShare.map(TripStatsSheet.percentText) ?? "—"
        }
    }

    private var headlineCaption: String {
        switch kind {
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
        let rows = named ?? placeRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(kind == .jams ? String(localized: "Где стояли дольше всего")
                                                    : String(localized: "Где чаще"))
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        if index > 0 { Divider().overlay(Theme.stroke) }
                        HStack(alignment: .firstTextBaseline) {
                            Text(rows[index].street ?? String(localized: "Улица не определена"))
                                .font(.rounded(15, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text(rows[index].value(kind))
                                .font(.rounded(15, .bold).monospacedDigit())
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .padding(.vertical, 10)
                        Text(rows[index].caption(kind))
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

    /// Место — числами, а подписи собираются при показе: так два места одной
    /// улицы складываются честно (секунды и разы — суммой, скорость — максимумом).
    private struct PlaceRow {
        let coordinate: CLLocationCoordinate2D
        var street: String?
        var seconds: TimeInterval = 0
        var times: Int
        var limitKmh = 0
        var maxKmh: Double = 0

        /// Справа — то, что отличает место: время в пробке или скорость, до
        /// которой разгонялись («до 78»); лимит и разы — подписью под ним.
        func value(_ kind: RoadHabitPayload.Kind) -> String {
            kind == .jams ? Formatting.duration(seconds)
                          : String(format: String(localized: "до %lld"), Int(maxKmh.rounded()))
        }

        func caption(_ kind: RoadHabitPayload.Kind) -> String {
            kind == .jams
                ? String(format: String(localized: "Вставали в пробку: %@"), ItogiWords.times(times))
                : String(format: String(localized: "лимит %1$lld · %2$@"), limitKmh, ItogiWords.times(times))
        }

        /// Ключ слияния: улица, а для «выше лимита» — ещё и лимит: «лимит 60»
        /// и «лимит 80» одной длинной улицы — разные места.
        func key(_ kind: RoadHabitPayload.Kind) -> String? {
            guard let street else { return nil }
            return kind == .jams ? street : "\(street)|\(limitKmh)"
        }
    }

    private var placeRows: [PlaceRow] {
        switch kind {
        case .jams:
            return payload.jams.places.map {
                PlaceRow(coordinate: $0.coordinate, seconds: $0.seconds, times: $0.times)
            }
        case .overLimit:
            return payload.places.map {
                PlaceRow(coordinate: $0.coordinate, times: $0.times, limitKmh: $0.limitKmh, maxKmh: $0.maxKmh)
            }
        }
    }

    @ViewBuilder
    private var hoursCard: some View {
        if let peak = payload.jams.peakBlock {
            HStack(spacing: 12) {
                IconBadge(symbol: "clock.fill", tint: Theme.textSecondary, size: 30)
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

    /// «по поездкам этого периода», а не «последних 30 дней» (34): места и
    /// часы строятся из записей выбранного окна (ItogiScreen.jams).
    private var explanation: some View {
        Text(kind == .jams
             ? String(localized: "Считаем по вашим трекам на телефоне: три минуты подряд медленнее 10 км/ч — пробка, короткий светофор — нет. Заезды по пути (магазин, заправка) не входят. Места и часы — по поездкам этого периода.")
             : String(localized: "Это не про штрафы: путь у камер сюда не входит, у них своя карточка. Считаем по лимиту дороги из OpenStreetMap, когда он известен, и только заметные превышения — на 10 км/ч и больше. С телефона ничего не уходит."))
            .font(.rounded(13))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Улица ближайшего дома — свой адресник, один файл на клетку за проход.
    private func loadStreets() async {
        var rows = placeRows
        for index in rows.indices {
            let point = rows[index].coordinate
            guard let book = await env.roads.addressBook(for: point),
                  let address = book.nearest(to: point, within: AppConfig.commuteLossNameMeters),
                  !address.street.isEmpty else { continue }
            if Task.isCancelled { return }
            rows[index].street = StreetName.display(address.street, language: env.settings.appLanguage.mapCode)
        }
        let kind = self.kind
        let merged = PlaceMerge.byStreet(rows, street: { $0.key(kind) }) { lhs, rhs in
            var sum = lhs
            sum.seconds += rhs.seconds
            sum.times += rhs.times
            sum.maxKmh = max(lhs.maxKmh, rhs.maxKmh)
            return sum
        }
        // Порядок — как у движка: пробки — по времени, «выше лимита» — по разам.
        named = kind == .jams ? merged.sorted { $0.seconds > $1.seconds }
                              : merged.sorted { $0.times > $1.times }
    }
}
