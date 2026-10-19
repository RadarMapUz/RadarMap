//
//  MyPlacesSheet.swift
//  RadarMap
//
//  «Мои места» — кнопкой в нижнем баре, на месте спидометра.
//
//  Спидометр владелец попросил убрать («мне кажется не нужен») и поставить
//  вместо него полезное. Самое полезное, что навигатор даёт одним тапом, —
//  дорога домой или на работу: у Яндекса и Amap «Мои места» / «Избранное»
//  живут ровно там же, в нижнем баре. Раньше Дом и Работа прятались строкой в
//  «Поиске» и страницей в Настройках, и задать их можно было только адресом
//  из поиска — «там выбор по карте нет».
//
//  Здесь: заданное место — тап строит маршрут; незаданное — «Задать» двумя
//  путями (найти адрес или показать на карте); ниже — недавние цели.
//

import CoreLocation
import SwiftUI

struct MyPlacesSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// Маршрут — тот же путь, что у поиска (MapScreen.buildRoute). nil — нет
    /// геопозиции, строить не от чего: тогда место показывается на карте.
    var onRoute: ((CLLocationCoordinate2D, String) -> Void)?
    /// Показать точку на карте (с её панелью «Маршрут сюда» / «Радар здесь»).
    var onShow: ((CLLocationCoordinate2D, String) -> Void)?

    @State private var searchSlot: PlaceSlot?
    @State private var pickSlot: PlaceSlot?
    /// «Избранное»: поиск адреса для нового места и имя перед сохранением.
    @State private var searchingFavorite = false
    @State private var pendingFavorite: SavedPlace?
    @State private var favoriteName = ""
    /// Выбранное в поиске — имя спросим, когда лист поиска закроется.
    @State private var pickedFavorite: SavedPlace?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(PlaceSlot.allCases) { slot in
                        slotRow(slot)
                    }
                }
                .listRowBackground(Theme.surface)
                favoritesSection
                recentsSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.screenBackground)
            .navigationTitle("Мои места")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { env.usage.noteScreen("places") }
        .sheet(item: $searchSlot) { slot in
            SearchView(initialAssign: slot)
        }
        .sheet(isPresented: $searchingFavorite, onDismiss: {
            // После закрытия, а не по таймеру: алерт поверх уходящего листа
            // не показывается, и выбор пропадал на медленной анимации.
            if let picked = pickedFavorite {
                pickedFavorite = nil
                favoriteName = picked.title
                pendingFavorite = picked
            }
        }) {
            SearchView(onSelect: { coordinate, title in
                pickedFavorite = SavedPlace(title: title, lat: coordinate.latitude,
                                            lon: coordinate.longitude)
            }, showsPlaces: false)
        }
        .alert("Название места", isPresented: Binding(get: { pendingFavorite != nil },
                                                      set: { if !$0 { pendingFavorite = nil } })) {
            TextField("Например, Дача", text: $favoriteName)
            Button("Сохранить") {
                if var place = pendingFavorite {
                    let name = favoriteName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { place.title = name }
                    env.settings.addFavorite(place)
                }
                pendingFavorite = nil
            }
            Button("Отмена", role: .cancel) { pendingFavorite = nil }
        }
        .fullScreenCover(item: $pickSlot) { slot in
            PlacePickerMap(slot: slot, start: .init(for: slot, env: env))
        }
    }

    // MARK: - Дом и Работа

    @ViewBuilder
    private func slotRow(_ slot: PlaceSlot) -> some View {
        let place = env.settings.place(for: slot)
        // Выученное по поездкам — только пока слот пуст: заданный рукой адрес
        // старше догадки (то же правило, что у подсказки «Домой»).
        let learned = place == nil ? learnedPlace(for: slot) : nil
        if let target = place?.coordinate ?? learned?.coordinate {
            HStack(spacing: 8) {
                Button {
                    go(to: target, name: slot.name)
                } label: {
                    // Выученное — коротко и с пользой: «По вашим поездкам ·
                    // обычно 39 мин». Прежнее «Выучено по поездкам — адрес не
                    // задан» не помещалось и обрезалось (обзор экранов, 12.10).
                    slotLabel(slot, isSet: place != nil,
                              subtitle: place?.title ?? Self.learnedSubtitle(usual: usualTime(for: slot)),
                              showsRoute: onRoute != nil)
                }
                .buttonStyle(.borderless)
                .accessibilityHint(onRoute != nil ? Text("Маршрут сюда") : Text(verbatim: ""))
                PlaceAssignMenu(onSearch: { searchSlot = slot }, onMap: { pickSlot = slot },
                            onCurrent: currentAssigner(slot)) {
                    PlaceAssignLabel(isSet: place != nil)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if place != nil {
                    Button(role: .destructive) {
                        env.settings.setPlace(nil, for: slot)
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
            }
        } else {
            // Ни адреса, ни догадки — строка целиком и есть «Задать»: тап
            // мимо маленькой кнопки не должен уходить в пустоту.
            PlaceAssignMenu(onSearch: { searchSlot = slot }, onMap: { pickSlot = slot },
                            onCurrent: currentAssigner(slot)) {
                HStack(spacing: 8) {
                    slotLabel(slot, isSet: false,
                              subtitle: String(localized: "Не задано — нажмите, чтобы настроить"),
                              showsRoute: false)
                    PlaceAssignLabel(isSet: false)
                }
            }
        }
    }

    /// «По вашим поездкам · обычно 39 мин».
    static func learnedSubtitle(usual: TimeInterval?) -> String {
        [String(localized: "По вашим поездкам"),
         usual.map { String(format: String(localized: "обычно %@"),
                            Formatting.unbreakable(Formatting.duration($0))) }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Медиана своих поездок к месту (Commute); nil — истории мало.
    private func usualTime(for slot: PlaceSlot) -> TimeInterval? {
        env.commute.first { $0.direction == (slot == .work ? .toWork : .toHome) }?.usual
    }

    private func slotLabel(_ slot: PlaceSlot, isSet: Bool, subtitle: String,
                           showsRoute: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: slot.symbol)
                .font(.rounded(15, .bold))
                // Белое на accentFill — как в строке «Мои места» поиска.
                .foregroundStyle(isSet ? Theme.onAccentFill : Theme.textSecondary)
                .frame(width: 36, height: 36)
                .background(isSet ? AnyShapeStyle(Theme.accentFill.gradient)
                                  : AnyShapeStyle(Theme.stroke), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.name)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    // Внутри Menu многострочная подпись центрировалась.
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if showsRoute {
                Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                    .font(.rounded(24))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(minHeight: Theme.controlSize)
        .contentShape(Rectangle())
    }

    private func learnedPlace(for slot: PlaceSlot) -> FrequentPlaces.Place? {
        guard env.settings.destinationSuggestions else { return nil }
        return env.learnedPlaces.first { $0.kind.rawValue == slot.rawValue }
    }

    // MARK: - Недавние

    @ViewBuilder private var recentsSection: some View {
        if !env.settings.recentPlaces.isEmpty {
            Section("Недавние") {
                ForEach(env.settings.recentPlaces, id: \.title) { place in
                    Button {
                        go(to: place.coordinate, name: place.title)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.rounded(15, .semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 36)
                            Text(place.title)
                                .font(.rounded(15, .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if onRoute != nil {
                                Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                                    .font(.rounded(19))
                                    .foregroundStyle(Theme.accent.opacity(0.75))
                            }
                        }
                        .frame(minHeight: Theme.controlSize)
                        .contentShape(Rectangle())
                    }
                    .accessibilityHint(onRoute != nil ? Text("Маршрут сюда") : Text(verbatim: ""))
                }
                .onDelete { offsets in
                    env.settings.recentPlaces.remove(atOffsets: offsets)
                }
            }
            .listRowBackground(Theme.surface)
        }
    }

    // MARK: - Избранное

    /// Свои места с именем (7.2). Добавить — текущее место или адрес из
    /// поиска; имя спрашиваем сразу, адрес остаётся подсказкой в поле.
    @ViewBuilder private var favoritesSection: some View {
        Section {
            // По позиции, не по имени: два «Текущих места» в разных
            // концах страны давали одинаковый id (ревью 19.10).
            ForEach(Array(env.settings.favoritePlaces.enumerated()), id: \.offset) { _, place in
                Button {
                    go(to: place.coordinate, name: place.title)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: Icon.myPlaces)
                            .font(.rounded(15, .bold))
                            .foregroundStyle(Theme.warning)
                            .frame(width: 36, height: 36)
                            .background(Theme.warning.opacity(0.14), in: Circle())
                        Text(place.title)
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if onRoute != nil {
                            Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                                .font(.rounded(24))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .frame(minHeight: Theme.controlSize)
                    .contentShape(Rectangle())
                }
                .accessibilityHint(onRoute != nil ? Text("Маршрут сюда") : Text(verbatim: ""))
            }
            .onDelete { offsets in
                env.settings.favoritePlaces.remove(atOffsets: offsets)
            }
            Menu {
                if env.location.hasLocation {
                    Button { addCurrentAsFavorite() } label: {
                        Label("Текущее место", systemImage: "location.fill")
                    }
                }
                Button { searchingFavorite = true } label: {
                    Label("Найти адрес", systemImage: "magnifyingglass")
                }
            } label: {
                Label("Добавить место", systemImage: "plus.circle.fill")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: Theme.controlSize)
            }
        } header: {
            Text("Избранное")
        }
        .listRowBackground(Theme.surface)
    }

    /// Задать Дом/Работу текущим местом; без положения пункта нет.
    private func currentAssigner(_ slot: PlaceSlot) -> (() -> Void)? {
        PlaceTitle.currentAssigner(slot, env: env)
    }

    /// «Текущее место» — с адресом из своего адресника, если он рядом.
    private func addCurrentAsFavorite() {
        guard let point = env.location.currentCoordinate else { return }
        Task {
            let title = await PlaceTitle.resolve(point, env: env)
            favoriteName = title
            pendingFavorite = SavedPlace(title: title, lat: point.latitude, lon: point.longitude)
        }
    }

    // MARK: - Действие

    private func go(to coordinate: CLLocationCoordinate2D, name: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let onRoute {
            onRoute(coordinate, name)
        } else {
            onShow?(coordinate, name)
        }
        dismiss()
    }
}

/// «Задать» / «Изменить» Дом или Работу — двумя путями: найти адрес словами
/// или показать на карте.
///
/// Одно меню на оба входа — «Мои места» в баре и страницу в Настройках. Два
/// входа в одно действие расходятся, стоит завести второй список пунктов:
/// так уже было с двумя жёлтыми кнопками «Радар».
struct PlaceAssignMenu<Content: View>: View {
    let onSearch: () -> Void
    let onMap: () -> Void
    /// «Текущее место» (7.2) — стоя у дома, его не ищут словами.
    var onCurrent: (() -> Void)? = nil
    @ViewBuilder var label: Content

    var body: some View {
        Menu {
            if let onCurrent {
                Button(action: onCurrent) {
                    Label("Текущее место", systemImage: "location.fill")
                }
            }
            Button(action: onSearch) {
                Label("Найти адрес", systemImage: "magnifyingglass")
            }
            Button(action: onMap) {
                Label("Выбрать на карте", systemImage: "map")
            }
        } label: {
            label
        }
        // Своя мишень у меню: в строке List кнопка со стилем по умолчанию
        // забирает касание всей строки, и тап по месту открывал бы меню
        // вместо маршрута.
        .menuStyle(.button)
        .buttonStyle(.borderless)
    }
}

/// Подпись меню в строке: «Задать» у пустого места, «Изменить» у заданного.
struct PlaceAssignLabel: View {
    let isSet: Bool

    var body: some View {
        Text(isSet ? String(localized: "Изменить") : String(localized: "Задать"))
            .font(.rounded(15, .semibold))
            .foregroundStyle(Theme.accent)
            .lineLimit(1)
            .tapTarget()
    }
}
