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
            mine = book?.search(query, near: near) ?? []
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
    private var bookAsked = false

    /// Завершитель ответил на текущий запрос. Без этого флага пустой список
    /// нельзя показать как «ничего не найдено»: ровно так же он выглядит,
    /// пока ответа ещё нет, и надпись мигала бы на каждой набранной букве.
    private(set) var answered = false

    private let completer = MKLocalSearchCompleter()

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
    func loadBook(from roads: RoadNetworkService,
                  at coordinate: CLLocationCoordinate2D?) async {
        guard !bookAsked, let coordinate else { return }
        bookAsked = true
        near = coordinate
        book = await roads.addressBook(for: coordinate)
        mine = book?.search(query, near: near) ?? []
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request(completion: completion)
        // Поиск/сеть подвели — вернём nil, UI покажет пустой результат.
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        return response.mapItems.first?.placemark.coordinate
    }
}

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @State private var model = SearchModel()
    /// Адрес не удалось развернуть в координату — тап отработал вхолостую, и
    /// об этом надо сказать: молчание здесь неотличимо от сломанной кнопки.
    @State private var resolveFailed = false
    var onSelect: ((CLLocationCoordinate2D) -> Void)? = nil
    var onRoute: ((CLLocationCoordinate2D, String) -> Void)? = nil
    /// Открытие сразу в режиме «выбрать адрес для Дом/Работа» (из Настроек).
    var initialAssign: PlaceSlot? = nil

    @State private var assigning: PlaceSlot? = nil

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            List {
                if let slot = assigning {
                    assignBanner(slot)
                } else {
                    placesSection
                    if model.query.isEmpty { recentsSection }
                }
                mineSection
                resultsSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.screenBackground)
            .searchable(text: $model.query, prompt: "Город, улица, место")
            .navigationTitle(assigning == nil ? Text("Поиск") : Text("Выбор адреса"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear { assigning = initialAssign }
        .task {
            await model.loadBook(from: env.roads,
                                 at: env.location.currentCoordinate)
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
        return Button {
            if let place {
                if let onRoute {
                    onRoute(place.coordinate, slot.name)
                } else {
                    onSelect?(place.coordinate)
                }
                dismiss()
            } else {
                assigning = slot   // не задано — тап настраивает
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: slot.symbol)
                    .font(.rounded(15, .bold))
                    .foregroundStyle(place == nil ? Theme.textSecondary : Theme.background)
                    .frame(width: 36, height: 36)
                    .background(place == nil ? AnyShapeStyle(Theme.stroke)
                                             : AnyShapeStyle(Theme.accent.gradient), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.name)
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(place?.title ?? String(localized: "Не задано — нажмите, чтобы настроить"))
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                if place != nil, onRoute != nil {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.rounded(24))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .contextMenu {
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

    private func assignBanner(_ slot: PlaceSlot) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: slot.symbol)
                    .font(.rounded(15, .bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent.gradient, in: Circle())
                Text(String(format: String(localized: "Найдите и выберите адрес для «%@»"), slot.name))
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                if initialAssign == nil {
                    Button("Отмена") { assigning = nil }
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            if env.location.currentCoordinate != nil {
                Button {
                    assignCurrentLocation(slot)
                } label: {
                    Label("Использовать текущее местоположение", systemImage: "location.fill")
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: - Недавние места

    @ViewBuilder private var recentsSection: some View {
        if !env.settings.recentPlaces.isEmpty {
            Section("Недавние") {
                ForEach(env.settings.recentPlaces, id: \.title) { place in
                    Button {
                        if let onRoute {
                            onRoute(place.coordinate, place.title)
                        } else {
                            onSelect?(place.coordinate)
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
                            if onRoute != nil {
                                Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                                    .font(.rounded(20))
                                    .foregroundStyle(Theme.accent.opacity(0.75))
                            }
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
                ForEach(model.mine, id: \.title) { address in
                    mineRow(address)
                }
            } header: {
                Text("Из своей карты · без сети")
            }
            .listRowBackground(Theme.surface)
        }
    }

    private func mineRow(_ address: Address) -> some View {
        HStack(spacing: 10) {
            Button {
                if let slot = assigning {
                    assign(slot, coordinate: address.point, title: address.title)
                } else {
                    onSelect?(address.point)
                    dismiss()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "house.fill")
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 24)
                    Text(address.title)
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let onRoute, assigning == nil {
                Button {
                    onRoute(address.point, address.title)
                    dismiss()
                } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.rounded(24))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
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
        } else if !model.query.isEmpty, model.answered, model.mine.isEmpty {
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
                    guard let coordinate = await model.resolve(result) else {
                        resolveFailed = true
                        return
                    }
                    if let slot = assigning {
                        assign(slot, coordinate: coordinate, title: result.title)
                    } else {
                        onSelect?(coordinate)
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
                        if let coordinate = await model.resolve(result) {
                            onRoute(coordinate, result.title)
                            dismiss()
                        } else {
                            resolveFailed = true
                        }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.rounded(26))
                        .foregroundStyle(Theme.accent)
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
