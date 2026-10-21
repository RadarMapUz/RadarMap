//
//  AlongRouteSheet.swift
//  RadarMap
//
//  «По пути» (19.3): заправки под топливо машины (метан — со статусом
//  водителей), гостиницы и кафе не дальше 2 км от дороги впереди — в том
//  порядке, в котором они встретятся. Тап — заезд по пути (`addStop`): цель
//  остаётся прежней.
//
//  Что найдено и откуда данные — RouteCorridorService и чистый
//  CorridorVenues; здесь чипы, строки и честная подпись о том, чего нет.
//

import CoreLocation
import SwiftUI

struct AlongRouteSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// Заехать: координата и подпись остановки.
    let onPick: (Venue) -> Void

    @State private var found: RouteCorridorService.Found?
    @State private var loading = true
    @State private var filter: Filter = .group(.fuel)
    /// Прогресс маршрута, к которому посчитано «через N км». Обновляется
    /// раз в `corridorListRefreshSeconds`, а не на каждом фиксе.
    @State private var progress: CLLocationDistance = 0
    @State private var detent: PresentationDetent = AlongRouteSheet.initialDetent

    enum Filter: Hashable {
        case all
        case group(CorridorVenues.Group)
    }

    var body: some View {
        NavigationStack {
            List {
                content
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.screenBackground)
            .safeAreaInset(edge: .top, spacing: 0) { chips }
            .navigationTitle("По пути")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .task {
            await load()
            await keepFresh()
        }
    }

    /// Половина экрана — карта с маршрутом видна за листом; скриншот-хук
    /// `-alongLarge` (DEBUG) раскрывает лист целиком, чтобы снять больше строк.
    private static var initialDetent: PresentationDetent {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-alongLarge") { return .large }
        #endif
        return .medium
    }

    // MARK: - Данные

    private var kinds: [Venue.Kind] {
        CorridorVenues.kinds(fuel: env.settings.vehicleEnergy.stops)
    }

    private func load() async {
        progress = env.route.progressAlong
        found = await env.corridor.venues(route: env.route, kinds: kinds)
        loading = false
    }

    /// Пока лист открыт и машина едет — «через N км» тает, проеханное уходит.
    private func keepFresh() async {
        while !Task.isCancelled {
            await Task.pause(seconds: AppConfig.corridorListRefreshSeconds)
            guard !Task.isCancelled else { return }
            let now = env.route.progressAlong
            if abs(now - progress) >= 1 { progress = now }
        }
    }

    private var rows: [CorridorVenues.Item] {
        (found?.items ?? []).filter { item in
            guard item.ahead(of: progress) >= AppConfig.corridorVenueAheadMeters else { return false }
            switch filter {
            case .all: return true
            case .group(let group): return CorridorVenues.group(of: item.venue.kind) == group
            }
        }
    }

    // MARK: - Чипы

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(.group(.fuel), title: fuelTitle)
                chip(.group(.hotel), title: String(localized: "Гостиницы"))
                chip(.group(.food), title: String(localized: "Кафе"))
                chip(.all, title: String(localized: "Все"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Theme.surface)
    }

    /// «Зарядки» электромобилю, «Заправки» остальным (метан и пропан — тоже
    /// заправки; какие именно — по «Машине» в настройках).
    private var fuelTitle: String {
        env.settings.vehicleEnergy == .electric ? String(localized: "Зарядки") : String(localized: "Заправки")
    }

    private func chip(_ value: Filter, title: String) -> some View {
        let selected = filter == value
        return Button {
            filter = value
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Text(verbatim: title)
                .font(.rounded(14, .semibold))
                .foregroundStyle(selected ? Theme.onAccentFill : Theme.textPrimary)
                .fixedSize()
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(selected ? AnyShapeStyle(Theme.accentFill) : AnyShapeStyle(Theme.background),
                            in: Capsule())
                .overlay(Capsule().stroke(selected ? .clear : Theme.stroke, lineWidth: 1))
                .tapTarget()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Список

    @ViewBuilder private var content: some View {
        if loading {
            HStack(spacing: 12) {
                ProgressView()
                Text("Ищем по пути…")
                    .font(.rounded(15))
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)
        } else if found == nil {
            Text("Маршрута нет")
                .font(.rounded(15))
                .foregroundStyle(Theme.textSecondary)
                .listRowBackground(Theme.surface)
        } else {
            Section {
                ForEach(rows) { row($0) }
                if rows.isEmpty { emptyRow }
            } header: {
                Text(String(format: String(localized: "Не дальше %@ от дороги, по порядку вдоль пути"),
                            Formatting.distance(AppConfig.corridorVenueMeters)))
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
                    .textCase(nil)
            }
            if let found, found.missingCells > 0 {
                Section { dataNote(found) }
            }
        }
    }

    private var emptyRow: some View {
        let nothingKnown = (found?.unpublishedCells ?? 0) == (found?.totalCells ?? 0)
            && (found?.totalCells ?? 0) > 0
        return Text(nothingKnown
                    ? String(localized: "Для этого пути данных о заведениях пока нет")
                    : String(format: String(localized: "Впереди в %@ от дороги ничего не нашлось"),
                             Formatting.distance(AppConfig.corridorVenueMeters)))
            .font(.rounded(15))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .listRowBackground(Theme.surface)
    }

    /// Чего нет на телефоне — словами и с размером, а по мобильной сети —
    /// кнопкой: молча её не будим (RouteCorridor.mayFetchCells).
    private func dataNote(_ found: RouteCorridorService.Found) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let size = OfflineMapsView.size(Int64(found.missingBytes))
            if !env.network.isOnline {
                Text("Нет связи — в списке то, что уже на телефоне")
            } else if env.network.isExpensive {
                Text(String(format: String(localized: "Часть пути пока без данных — %@. Скачаются по Wi-Fi."),
                            Formatting.unbreakable(size)))
                noteButton(String(format: String(localized: "Скачать по мобильной сети · %@"),
                                  Formatting.unbreakable(size)), consent: true)
            } else {
                // По Wi-Fi недостающее качается само — раз его нет, загрузка сорвалась.
                Text(String(format: String(localized: "Часть пути не загрузилась — %@"),
                            Formatting.unbreakable(size)))
                noteButton(String(localized: "Повторить"), consent: false)
            }
        }
        .font(.rounded(13))
        .foregroundStyle(Theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .listRowBackground(Theme.surface)
    }

    private func noteButton(_ title: String, consent: Bool) -> some View {
        Button {
            if consent, let destination = env.route.destinationCoordinate {
                env.corridor.consent(key: RouteCorridor.routeKey(destination: destination))
            }
            loading = true
            Task { await load() }
        } label: {
            Text(verbatim: title)
                .font(.rounded(15, .semibold))
                .foregroundStyle(Theme.accent)
                .frame(minHeight: Theme.controlSize)
        }
        .buttonStyle(.plain)
    }

    private func row(_ item: CorridorVenues.Item) -> some View {
        let venue = item.venue
        let ahead = item.ahead(of: progress)
        let station = venue.kind == .cng && env.cng.isActive ? env.cng.station(for: venue.point) : nil
        return Button {
            onPick(venue)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: venue.kind.symbol)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: venue.title)
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: AlongRouteText.detail(item, ahead: ahead))
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let station, let caption = CngRules.caption(station) {
                        Text(verbatim: caption)
                            .font(.rounded(12, .semibold))
                            .foregroundStyle(station.status == .nogas ? Theme.textTertiary : Theme.success)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "plus.circle.fill")
                    .font(.rounded(22))
                    .foregroundStyle(Theme.accent)
            }
            .frame(minHeight: Theme.controlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.surface)
        .listRowSeparatorTint(Theme.stroke)
        // Голосом — одной фразой и словами: «через 47 километров, заправка
        // метан, газ есть», а не «47 км» буквами.
        .accessibilityLabel(Text(verbatim: AlongRouteText.spoken(item, ahead: ahead, station: station)))
        .accessibilityHint(Text("Заехать по пути"))
    }
}

/// Подписи строки «По пути» — экранная и для VoiceOver. Отдельно от вида,
/// чтобы фразу можно было проверить тестом.
enum AlongRouteText {

    /// Значок «По пути» в панели маршрута и меню: колонка — машине на
    /// топливе, вилка зарядки — электромобилю.
    static func symbol(_ energy: VehicleEnergy) -> String {
        energy == .electric ? "bolt.car.fill" : "fuelpump.fill"
    }

    /// Вид заведения на экране: «Кафе», а не «Еда» плитки поиска.
    static func title(_ kind: Venue.Kind) -> String {
        kind == .food ? String(localized: "Кафе") : kind.title
    }

    /// Вид словами для голоса: «заправка метан», а не «Метан» или «АЗС» буквами.
    static func spokenKind(_ kind: Venue.Kind) -> String {
        switch kind {
        case .fuel:     return String(localized: "заправка")
        case .cng:      return String(localized: "заправка метан")
        case .lpg:      return String(localized: "заправка пропан")
        case .charging: return String(localized: "зарядная станция")
        case .hotel:    return String(localized: "гостиница")
        case .food:     return String(localized: "кафе")
        default:        return kind.title
        }
    }

    /// «Метан · через 47 км, 300 м от дороги» — вид пишется, только если
    /// у заведения есть своё имя (иначе вид уже стоит заголовком).
    static func detail(_ item: CorridorVenues.Item, ahead: CLLocationDistance) -> String {
        let distance = Formatting.distance(max(0, ahead))
        let place = item.offset <= AppConfig.corridorVenueRoadsideMeters
            ? String(format: String(localized: "через %@, у дороги"), distance)
            : String(format: String(localized: "через %1$@, %2$@ от дороги"), distance,
                     Formatting.distance(item.offset))
        return item.venue.name.isEmpty ? place : title(item.venue.kind) + " · " + place
    }

    /// «через 47 километров, заправка метан, Metan Chinoz, газ есть, 300 метров от дороги».
    static func spoken(_ item: CorridorVenues.Item, ahead: CLLocationDistance,
                       station: CngStation?, locale: Locale = NumberFormat.locale) -> String {
        var parts = [spokenKind(item.venue.kind)]
        if !item.venue.name.isEmpty { parts.append(item.venue.name) }
        if let station { parts += spokenStatus(station, locale: locale) }
        parts.append(item.offset <= AppConfig.corridorVenueRoadsideMeters
                     ? String(localized: "у дороги")
                     : String(format: String(localized: "%@ от дороги"),
                              SpokenUnits.distance(item.offset, locale: locale)))
        return String(format: String(localized: "через %1$@, %2$@"),
                      SpokenUnits.distance(max(0, ahead), locale: locale), parts.joined(separator: ", "))
    }

    /// Статус метана голосом: «газ есть, по словам водителя», «очередь около 15 минут».
    static func spokenStatus(_ station: CngStation, locale: Locale = NumberFormat.locale) -> [String] {
        var parts: [String] = []
        if let status = station.status {
            // Строчными: середина фразы, а не заголовок строки.
            parts.append((status == .gas ? String(localized: "Газ есть") : String(localized: "Газа нет"))
                .lowercased(with: locale))
            if !station.confirmed { parts.append(String(localized: "по словам водителя")) }
        }
        if let queue = station.queue {
            parts.append(queue >= 60
                         ? String(localized: "очередь больше 30 минут")
                         : String(format: String(localized: "очередь около %@"),
                                  SpokenUnits.minutes(queue, locale: locale)))
        }
        return parts
    }
}
