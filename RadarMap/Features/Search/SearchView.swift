//
//  SearchView.swift
//  RadarMap
//
//  Поиск места/адреса, маршрут в один тап, сохранённые места «Дом» и «Работа».
//

import SwiftUI
import MapKit
import os

@MainActor
@Observable
final class SearchModel: NSObject, MKLocalSearchCompleterDelegate {

    /// Снос — БЕЗ прыжка на актор, и это не стиль, а обход живого бага рантайма.
    ///
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor синтезирует isolated deinit
    /// каждому @MainActor-классу, даже когда своего deinit нет. Такой deinit
    /// уходит в swift_task_deinitOnExecutor, тот в синхронном кадре главного
    /// потока (текущей Task нет) заводит TaskLocal::StopLookupScope, а
    /// MarkerItem::create в рантайме iOS 26 берёт память у task-аллокатора
    /// БЕЗУСЛОВНО — при task == nullptr это статический слэб внутри
    /// libswift_Concurrency. Item::destroy потом зовёт free() по этому
    /// указателю: «pointer being freed was not allocated» → SIGABRT.
    ///
    /// Условия сходятся ровно там, где SwiftUI сносит вью с @State-моделью
    /// внутри GraphHost.runTransaction: там жива task-local привязка. В ветке
    /// main рантайма баг уже исправлен; до выхода такой iOS помогает одно —
    /// не синтезировать isolated deinit вовсе.
    nonisolated deinit {}
    var query = "" {
        didSet {
            answered = false
            completer.queryFragment = query
            mine = book?.lookup(query, near: near) ?? []
            places = venues?.search(query, near: near) ?? []
            if !query.isEmpty, category != nil {
                cancelCategory()
                category = nil
            }
        }
    }

    /// Где стоит машина: ближний дом в списке выше дальнего. Улица с одним
    /// названием есть в каждом районе, и без этого первым показывался бы
    /// случайный из них.
    var near: CLLocationCoordinate2D?
    private(set) var results: [MKLocalSearchCompletion] = []

    /// Свои адреса — из подписанного файла города, без сети.
    ///
    /// Первым источником, а не заменой. Apple лучше знает заведения, опечатки
    /// и то, что человек называет «Корзинка на Чиланзаре»; своё берёт другим —
    /// оно отвечает мгновенно и отвечает всегда: в роуминге, в подвале
    /// парковки и в тоннеле, где сетевого поиска просто нет.
    private(set) var mine: [Address] = []
    private var book: AddressBook?
    /// Свои заведения клетки (АЗС, парковки…) и найденные в них по запросу.
    private var venues: VenueBook?
    private(set) var places: [Venue] = []

    /// Выбранная плитка категории и её ответ: свой индекс, а пока клетка не
    /// опубликована или пуста — Apple (`categoryFromApple`).
    private(set) var category: Venue.Kind?
    private(set) var categoryResults: [Venue] = []
    private(set) var categoryFromApple = false
    private(set) var categoryLoading = false
    /// Ответ «по пути»: сколько ехать до заведения вдоль маршрута (по id).
    private(set) var categoryAhead: [String: Double] = [:]
    private var categoryTask: Task<Void, Never>?
    private var bookAsked = false

    /// Завершитель ответил на текущий запрос. Без этого флага пустой список
    /// нельзя показать как «ничего не найдено»: ровно так же он выглядит,
    /// пока ответа ещё нет, и надпись мигала бы на каждой набранной букве.
    private(set) var answered = false

    private let completer = MKLocalSearchCompleter()

    /// Идёт разворот адреса Apple в координату. Второй тап в это время
    /// ничего не делает: раньше двойной тап строил два маршрута.
    private(set) var isResolving = false

    func resolveOnce(_ completion: MKLocalSearchCompletion) async -> CLLocationCoordinate2D? {
        guard !isResolving else { return nil }
        isResolving = true
        defer { isResolving = false }
        return await resolve(completion)
    }

    /// Расстояние от машины — подпись строки результата.
    func distance(to point: CLLocationCoordinate2D) -> CLLocationDistance? {
        near.map { GeoMath.fastDistance($0.latitude, $0.longitude, point.latitude, point.longitude) }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {   // MKLocalSearchCompleter вызывает делегат на главном потоке
            self.results = completer.results
            self.answered = true
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter,
                               didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            Log.app.error("поиск не ответил: \(error.localizedDescription, privacy: .public)")
            self.results = []
            self.answered = true
        }
    }

    /// Забрать файл адресов города. Один раз за показ экрана: город не
    /// меняется, пока человек набирает запрос.
    ///
    /// Без GPS — клетка дома, а без дома — Ташкента: свой поиск обязан
    /// работать и в подвале парковки, где спутников нет, а раньше без
    /// координаты он не загружался вовсе.
    func loadBook(from roads: RoadNetworkService,
                  at coordinate: CLLocationCoordinate2D?,
                  fallback: CLLocationCoordinate2D?) async {
        guard !bookAsked else { return }
        bookAsked = true
        near = coordinate
        if let coordinate {
            // Apple без региона ищет по всему миру: «Навои» находился бы в
            // Самарканде раньше, чем в Ташкенте.
            completer.region = MKCoordinateRegion(center: coordinate,
                                                  latitudinalMeters: AppConfig.searchRegionMeters,
                                                  longitudinalMeters: AppConfig.searchRegionMeters)
        }
        let cell = coordinate ?? fallback ?? AppConfig.searchFallbackCenter
        book = await roads.addressBook(for: cell)
        venues = await roads.venueBook(for: cell)
        mine = book?.lookup(query, near: near) ?? []
        places = venues?.search(query, near: near) ?? []
    }

    /// Плитка категории: ближайшие такого вида, а с маршрутом — по пути.
    /// Повторный тап — свернуть.
    func pick(_ kind: Venue.Kind, route: (points: [MKMapPoint], progress: Double)? = nil) {
        cancelCategory()
        guard category != kind else {
            category = nil
            categoryResults = []
            return
        }
        category = kind
        categoryResults = []
        categoryLoading = true
        let venues = venues, near = near
        categoryTask = Task { [weak self] in
            // «По пути» — проекция каждого заведения на линию маршрута: на
            // междугороднем маршруте это десятки миллионов операций, не для main.
            var along: [(venue: Venue, ahead: Double)] = []
            if let route, let venues {
                along = await offMain {
                    venues.alongRoute(kind, points: route.points, progress: route.progress)
                }
            }
            guard let self, !Task.isCancelled, self.category == kind else { return }
            defer { self.categoryLoading = false }
            if !along.isEmpty {
                self.categoryResults = along.map(\.venue)
                self.categoryAhead = Dictionary(uniqueKeysWithValues: along.map { ($0.venue.id, $0.ahead) })
                self.categoryFromApple = false
                return
            }
            let own = venues?.nearest(kind, to: near) ?? []
            if !own.isEmpty {
                self.categoryResults = own
                self.categoryFromApple = false
                return
            }
            // Своего ответа нет (клетка ещё не опубликована) — Apple, и честно
            // подписано, откуда ответ.
            let found: [Venue]
            do {
                found = try await VenueBook.apple(kind, near: near)
            } catch {
                Log.app.error("категория у Apple: \(error.localizedDescription, privacy: .public)")
                found = []
            }
            guard !Task.isCancelled, self.category == kind else { return }
            self.categoryResults = found
            self.categoryFromApple = true
        }
    }

    /// Отменить ответ плитки. Индикатор гасится здесь же: отменённая задача
    /// до своего конца не доходит, и раньше он оставался крутиться вместо
    /// ответа следующей плитки.
    private func cancelCategory() {
        categoryTask?.cancel()
        categoryTask = nil
        categoryLoading = false
        categoryAhead = [:]
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request(completion: completion)
        do {
            return try await MKLocalSearch(request: request).start().mapItems.first?.placemark.coordinate
        } catch {
            // UI скажет «не удалось открыть адрес»; причина — в лог, а не в никуда.
            Log.app.error("адрес не развернулся: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @State private var model = SearchModel()
    /// Адрес не удалось развернуть в координату — тап отработал вхолостую, и
    /// об этом надо сказать: молчание здесь неотличимо от сломанной кнопки.
    @State private var resolveFailed = false
    /// Выбор места: точка и её название (для точки на карте).
    var onSelect: ((CLLocationCoordinate2D, String) -> Void)? = nil
    var onRoute: ((CLLocationCoordinate2D, String) -> Void)? = nil
    /// Заезд по пути: место из плитки категории, найденное впереди по
    /// маршруту, становится остановкой, а цель остаётся. nil — маршрута нет.
    var onAddStop: ((CLLocationCoordinate2D, String) -> Void)? = nil
    /// Открытие сразу в режиме «выбрать адрес для Дом/Работа» (из Настроек).
    var initialAssign: PlaceSlot? = nil
    /// Секция «Мои места». Нет — когда поиск выбирает точку для «Избранного»:
    /// тап по «Дому» предложил бы избранное «Дом», а пустой слот назначил бы
    /// Дом вместо выбора (ревью 19.10).
    var showsPlaces = true

    @State private var assigning: PlaceSlot? = nil
    /// «Выбрать на карте» для назначаемого места — когда адрес словами не
    /// находится (дом без номера в OSM, новый квартал).
    @State private var pickSlot: PlaceSlot?
    /// Точку на карте подтвердили «Готово» — после закрытия карты завершаем
    /// назначение так же, как выбором адреса из списка.
    @State private var pickedOnMap = false

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            List {
                if let slot = assigning {
                    assignBanner(slot)
                } else {
                    if showsPlaces { placesSection }
                    if model.query.isEmpty {
                        categoriesSection
                        recentsSection
                    }
                }
                placesFoundSection
                mineSection
                resultsSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.screenBackground)
            .onAppear { env.usage.noteScreen("search") }
            .searchable(text: $model.query, prompt: "Город, улица, место")
            .navigationTitle(assigning == nil ? Text("Поиск") : Text("Выбор адреса"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // «Готово», как на всех листах приложения (7.1): «Отмена»
                // здесь ничего не отменяла — лист просто закрывался.
                ToolbarItem(placement: .confirmationAction) {
                    // В режиме назначения это выход без сохранения — так и
                    // называется.
                    Button(initialAssign != nil ? "Отмена" : "Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear { assigning = initialAssign }
        .task {
            await model.loadBook(from: env.roads,
                                 at: env.location.currentCoordinate,
                                 fallback: env.settings.place(for: .home)?.coordinate)
        }
        .fullScreenCover(item: $pickSlot, onDismiss: finishMapPick) { slot in
            PlacePickerMap(slot: slot, start: .init(for: slot, env: env),
                           onSaved: { pickedOnMap = true })
        }
        .alert("Не удалось открыть адрес", isPresented: $resolveFailed) {
            Button("Понятно", role: .cancel) { }
        } message: {
            Text("Проверьте связь и попробуйте ещё раз.")
        }
    }

    // MARK: - Мои места

    private var placesSection: some View {
        Section {
            ForEach(PlaceSlot.allCases) { slot in
                placeRow(slot)
            }
        } header: {
            Text("Мои места")
        } footer: {
            if model.query.isEmpty {
                Text("Введите город, улицу или объект — или сохраните частые адреса выше.")
            }
        }
        .listRowBackground(Theme.surface)
    }

    private func placeRow(_ slot: PlaceSlot) -> some View {
        let place = env.settings.place(for: slot)
        // Выученное по поездкам — как в «Моих местах»: «Не задано» при
        // известном доме противоречило соседнему экрану (обзор экранов, 12.10).
        let learned = place == nil && env.settings.destinationSuggestions
            ? env.learnedPlaces.first { $0.kind.rawValue == slot.rawValue } : nil
        let target = place?.coordinate ?? learned?.coordinate
        let usual = env.commute.first { $0.direction == (slot == .work ? .toWork : .toHome) }?.usual
        return Button {
            if let target {
                if let onRoute {
                    onRoute(target, slot.name)
                } else {
                    onSelect?(target, slot.name)
                }
                dismiss()
            } else {
                assigning = slot   // не задано — тап настраивает
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: slot.symbol)
                    .font(.rounded(15, .bold))
                    // Белое на accentFill: Theme.background ночью графитовый,
                    // и на светлом ночном accent значок читался цветом фона.
                    .foregroundStyle(place == nil ? Theme.textSecondary : Theme.onAccentFill)
                    .frame(width: 36, height: 36)
                    .background(place == nil ? AnyShapeStyle(Theme.stroke)
                                             : AnyShapeStyle(Theme.accentFill.gradient), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.name)
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(place?.title
                         ?? (learned != nil ? MyPlacesSheet.learnedSubtitle(usual: usual)
                                            : String(localized: "Не задано — нажмите, чтобы настроить")))
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if target != nil, onRoute != nil {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.rounded(24))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .contextMenu {
            if place == nil, learned != nil {
                Button { assigning = slot } label: {
                    Label("Задать адрес", systemImage: "pencil")
                }
            }
            if place != nil {
                Button { assigning = slot } label: {
                    Label("Изменить адрес", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    env.settings.setPlace(nil, for: slot)
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Категории и заведения

    /// Плитки «АЗС, Парковка, Мойка…» — то, что ищут из машины. Ответ — сразу
    /// под плитками: ближайшие, со своего индекса и без сети.
    @ViewBuilder private var categoriesSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                ForEach(Venue.Kind.quick, id: \.self) { kind in
                    Button {
                        model.pick(kind, route: env.route.selected.map { ($0.points, env.route.progressAlong) })
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: kind.symbol)
                                .font(.rounded(17, .bold))
                            Text(kind.title)
                                .font(.rounded(11, .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(model.category == kind ? Theme.onAccentFill : Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(model.category == kind ? AnyShapeStyle(Theme.accentFill.gradient)
                                                           : AnyShapeStyle(Theme.screenBackground),
                                    in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.category == kind ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
            if let kind = model.category {
                if model.categoryLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if model.categoryResults.isEmpty {
                    Text(String(format: String(localized: "%@ рядом не нашлось"), kind.title))
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(model.categoryResults.prefix(AppConfig.searchCategoryLimit)) { venue in
                        venueRow(venue)
                    }
                }
            }
        } header: {
            // «Заведения»: «рядом» обещало расстояние, а плитки — это виды мест.
            Text("Заведения")
        } footer: {
            if model.category != nil, !model.categoryResults.isEmpty {
                Text(model.categoryFromApple ? "По данным Apple" : "Из своей карты · без сети")
            }
        }
        .listRowBackground(Theme.surface)
    }

    /// Заведения по запросу («Лукойл», «заправка») — своя карта, без сети.
    @ViewBuilder private var placesFoundSection: some View {
        if !model.places.isEmpty, assigning == nil {
            Section {
                ForEach(model.places) { venueRow($0) }
            } header: {
                Text("Места · без сети")
            }
            .listRowBackground(Theme.surface)
        }
    }

    private func venueRow(_ venue: Venue) -> some View {
        HStack(spacing: 10) {
            Button {
                onSelect?(venue.point, venue.title)
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: venue.kind.symbol)
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(venue.title)
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if let ahead = model.categoryAhead[venue.id] {
                            Text(String(format: String(localized: "через %@ по пути"), Formatting.distance(ahead)))
                                .font(.rounded(12))
                                .foregroundStyle(Theme.accent)
                        } else if let distance = model.distance(to: venue.point) {
                            Text(Formatting.distance(distance))
                                .font(.rounded(12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let onAddStop, model.categoryAhead[venue.id] != nil {
                // Впереди по маршруту — заезд, а не новая цель: раньше эта
                // кнопка строила маршрут до заправки, и цель поездки терялась.
                Button {
                    onAddStop(venue.point, venue.title)
                    dismiss()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.rounded(24))
                        .foregroundStyle(Theme.accent)
                        .tapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Заехать по пути"))
            } else if let onRoute {
                Button {
                    onRoute(venue.point, venue.title)
                    dismiss()
                } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.rounded(24))
                        .foregroundStyle(Theme.accent)
                        .tapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Маршрут сюда"))
            }
        }
    }

    private func assignBanner(_ slot: PlaceSlot) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: slot.symbol)
                    .font(.rounded(15, .bold))
                    .foregroundStyle(Theme.onAccentFill)
                    .frame(width: 36, height: 36)
                    .background(Theme.accentFill.gradient, in: Circle())
                Text(String(format: String(localized: "Найдите и выберите адрес для «%@»"), slot.name))
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                if initialAssign == nil {
                    // .borderless обязателен: кнопка со стилем по умолчанию в
                    // строке List забирает касание всей строки, и тап по
                    // подсказке «Найдите и выберите адрес» тоже отменял выбор.
                    Button {
                        assigning = nil
                    } label: {
                        Text("Отмена")
                            .font(.rounded(13, .semibold))
                            .foregroundStyle(Theme.accent)
                            .tapTarget()
                    }
                    .buttonStyle(.borderless)
                }
            }
            if env.location.hasLocation {
                Button {
                    assignCurrentLocation(slot)
                } label: {
                    Label("Использовать текущее местоположение", systemImage: "location.fill")
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            Button {
                pickSlot = slot
            } label: {
                Label("Выбрать на карте", systemImage: "map")
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: - Недавние места

    @ViewBuilder private var recentsSection: some View {
        if !env.settings.recentPlaces.isEmpty {
            Section("Недавние") {
                ForEach(env.settings.recentPlaces, id: \.title) { place in
                    // Как у любой строки поиска (7.1): тап показывает точку на
                    // карте, стрелка строит маршрут. Недавние одни строили
                    // маршрут на тап — и одно и то же касание в одном списке
                    // делало две разные вещи.
                    HStack(spacing: 12) {
                        Button {
                            if let onSelect {
                                onSelect(place.coordinate, place.title)
                            } else {
                                onRoute?(place.coordinate, place.title)
                            }
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.rounded(14, .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 24)
                                Text(place.title)
                                    .font(.rounded(14, .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        if let onRoute {
                            Button {
                                onRoute(place.coordinate, place.title)
                                dismiss()
                            } label: {
                                Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                                    .font(.rounded(24))
                                    .foregroundStyle(Theme.accent)
                                    .tapTarget()
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Маршрут сюда"))
                        }
                    }
                }
                .onDelete { offsets in
                    env.settings.recentPlaces.remove(atOffsets: offsets)
                }
            }
            .listRowBackground(Theme.surface)
        }
    }

    // MARK: - Свои адреса

    /// Отдельной секцией и ВЫШЕ сетевых результатов.
    ///
    /// Не вперемешку: свои адреса появляются мгновенно, сетевые — через
    /// полсекунды, и список, в который они досыпаются, прыгает под пальцем.
    /// Отдельный заголовок ещё и честен: он говорит, что этот кусок работает
    /// без сети, а тот — нет.
    @ViewBuilder private var mineSection: some View {
        if !model.mine.isEmpty {
            Section {
                ForEach(model.mine) { address in
                    mineRow(address)
                }
            } header: {
                Text("Из своей карты · без сети")
            }
            .listRowBackground(Theme.surface)
        }
    }

    /// Название в языке приложения: в OSM 72 % улиц Ташкента записаны
    /// латиницей («Alisher Navoiy ko'chasi»), а человек искал «Навои».
    private func title(_ address: Address) -> String {
        let street = StreetName.display(address.street, language: env.settings.appLanguage.mapCode)
        return address.house.isEmpty ? street : "\(street), \(address.house)"
    }

    private func mineRow(_ address: Address) -> some View {
        let title = title(address)
        return HStack(spacing: 10) {
            Button {
                if let slot = assigning {
                    assign(slot, coordinate: address.point, title: title)
                } else {
                    onSelect?(address.point, title)
                    dismiss()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: address.isStreet ? "road.lanes" : "house.fill")
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if let distance = model.distance(to: address.point) {
                            Text(Formatting.distance(distance))
                                .font(.rounded(12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let onRoute, assigning == nil {
                Button {
                    onRoute(address.point, title)
                    dismiss()
                } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.rounded(24))
                        .foregroundStyle(Theme.accent)
                        .tapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Маршрут сюда"))
            }
        }
    }

    // MARK: - Результаты поиска

    @ViewBuilder private var resultsSection: some View {
        if !model.results.isEmpty {
            Section {
                ForEach(model.results, id: \.self) { result in
                    resultRow(result)
                }
            }
            .listRowBackground(Theme.surface)
        } else if !model.query.isEmpty, model.answered, model.mine.isEmpty, model.places.isEmpty {
            // Пустой список без единого слова читается как зависшее
            // приложение: человек ждёт результата, которого уже не будет.
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ничего не найдено")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    // Один литерал, а не склейка двух: `"a" + "b"` даёт String,
                    // и Text выбирает НЕ-локализуемую перегрузку — строка
                    // оставалась русской на всех языках. Продолжение строки
                    // через «\» держит ключ каталога одним куском.
                    Text("""
                         Попробуйте название улицы или ближайший ориентир. \
                         Свои адреса ищутся и без сети — «улица, номер».
                         """)
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Theme.surface)
        }
    }

    private func resultRow(_ result: MKLocalSearchCompletion) -> some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    guard let coordinate = await model.resolveOnce(result) else {
                        if !model.isResolving { resolveFailed = true }
                        return
                    }
                    if let slot = assigning {
                        assign(slot, coordinate: coordinate, title: result.title)
                    } else {
                        onSelect?(coordinate, result.title)
                        dismiss()
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.rounded(12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let onRoute, assigning == nil {
                // Построить маршрут прямо из поиска — самый короткий путь к цели.
                Button {
                    Task {
                        if let coordinate = await model.resolveOnce(result) {
                            onRoute(coordinate, result.title)
                            dismiss()
                        } else if !model.isResolving {
                            resolveFailed = true
                        }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.rounded(24))
                        .foregroundStyle(Theme.accent)
                        .tapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Маршрут сюда"))
            }
        }
    }

    // MARK: - Назначение места

    private func assign(_ slot: PlaceSlot, coordinate: CLLocationCoordinate2D, title: String) {
        env.settings.setPlace(SavedPlace(title: title,
                                         lat: coordinate.latitude,
                                         lon: coordinate.longitude), for: slot)
        model.query = ""
        if initialAssign != nil {
            dismiss()          // пришли из Настроек — адрес выбран, закрываем
        } else {
            assigning = nil    // остаёмся в поиске: строка «Дом/Работа» уже заполнена
        }
    }

    /// Карта закрылась: если точку подтвердили — назначение завершено (место
    /// сохранила сама карта), закрываемся или возвращаемся к поиску так же,
    /// как после выбора адреса. «Отмена» на карте оставляет выбор открытым.
    private func finishMapPick() {
        guard pickedOnMap else { return }
        pickedOnMap = false
        model.query = ""
        if initialAssign != nil {
            dismiss()
        } else {
            assigning = nil
        }
    }

    private func assignCurrentLocation(_ slot: PlaceSlot) {
        guard let coordinate = env.location.currentCoordinate else { return }
        Task {
            // Пытаемся получить человекочитаемый адрес; если нет сети — координаты.
            var title = String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            // Обратный геокодинг — украшение заголовка; сбой оставит координаты.
            if #available(iOS 26.0, *) {
                if let request = MKReverseGeocodingRequest(location: location),
                   let item = try? await request.mapItems.first {
                    title = item.name ?? title
                }
            }
            assign(slot, coordinate: coordinate, title: title)
        }
    }
}
