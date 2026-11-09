//
//  CarPlaySearch.swift
//  RadarMap
//
//  Поиск на экране машины.
//
//  До 10.10.2026 «Куда» в машине умело только Дом, Работу и недавние: адрес,
//  которого в них нет, можно было задать лишь на телефоне. Здесь тот же поиск,
//  что на телефоне, в том же порядке источников: свой индекс адресов (без
//  сети, мгновенно) первым, Apple — вторым. Клавиатура — у системы: пока машина
//  её ограничивает, сюда не приходим (CarPlaySearchEntry, список «Поиск на ходу»).
//

import CarPlay
import MapKit
import os

@MainActor
final class CarPlaySearch: NSObject, CPSearchTemplateDelegate {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    /// Выбранное место: название и точка.
    private let onPick: (SavedPlace) -> Void
    /// Показать шаблон поверх поиска (список по кнопке «Найти»). Ставит
    /// делегат сцены: у поиска своего контроллера интерфейса нет.
    var present: ((CPTemplate) -> Void)?
    /// Что нашлось на последний запрос — для полного списка по «Найти». Свои
    /// адреса пишутся сразу, не дожидаясь Apple.
    private var lastResults: [(SavedPlace, String)] = []
    /// Запрос ещё идёт: «Найти» ждёт ответа, а не говорит «ничего».
    private var searching = false
    /// Свои адреса на текущий запрос уже есть: раньше «Найти» показать нечего.
    private var ownReady = false
    private var listWanted = false
    private var listFallback: Task<Void, Never>?
    private var book: AddressBook?
    private var venues: VenueBook?
    /// Поиск по всем именам клетки (40G) — строится своей задачей после
    /// загрузки файлов; пока его нет, отвечает старый поиск — первый запрос в
    /// машине не ждёт сборку индекса (ревью 03.11).
    private var index: SearchIndex?
    private var indexTask: Task<Void, Never>?
    /// Клетка, для которой загружены адреса и заведения. Подключение длится
    /// часами: выехали из Ташкента в Самарканд — нужна клетка Самарканда, а
    /// не ташкентские АЗС «в 310 км».
    private var loadedCell: String?
    /// Загрузка клетки — ОДНА на все запросы и отдельной задачей: новая буква
    /// отменяет поиск, и раньше вместе с ним отменялась и загрузка. Адреса и
    /// заведения — каждый своим ответом: не загрузилось одно — следующий
    /// запрос дозагрузит именно его.
    private var loadTask: Task<Void, Never>?
    private var task: Task<Void, Never>?
    /// Ответ шаблону на текущий запрос. CarPlay требует ответить на каждый, и
    /// ровно один раз: заменённый запрос получает пустой список сразу.
    private var reply: CarPlaySearchReply<CPListItem>?

    private var env: AppEnvironment { .shared }

    /// Сколько строк покажет список машины: CarPlay сам режет лишнее молча,
    /// а на ходу многие машины держат всего 12 (Руководство CarPlay, стр. 19).
    private static var listLimit: Int {
        CarPlaySearchEntry.listLimit(own: AppConfig.carPlaySearchLimit,
                                     maximumItemCount: Int(CPListTemplate.maximumItemCount))
    }

    init(onPick: @escaping (SavedPlace) -> Void) {
        self.onPick = onPick
        super.init()
        // Адресная книга и заведения клетки — мегабайты, а нужны только пока
        // открыт поиск: на предупреждении о памяти отдаём их (план 2.20) —
        // следующий запрос прочтёт заново с диска.
        MemoryPressure.onWarning(self) { $0.releaseBooks() }
    }

    private func releaseBooks() {
        loadTask?.cancel()
        loadTask = nil
        book = nil
        venues = nil
        index = nil
        indexTask?.cancel()
        indexTask = nil
        loadedCell = nil
    }

    /// Ближайшие заведения вида — для плитки «АЗС» в «Куда». Свой индекс, а
    /// без него (клетка не опубликована) — Apple, если есть связь.
    /// `alongRoute` — найдено впереди по маршруту: такое место выбирают как
    /// остановку по пути, а не как новую цель.
    func nearest(_ kind: Venue.Kind) async -> [(place: SavedPlace, detail: String, alongRoute: Bool)] {
        let near = env.location.currentCoordinate
        await ensureLoaded(near: near)
        // С маршрутом — то, что встретится по пути, а не ближайшее вообще.
        // Проекция на линию — не для main: маршрут бывает междугородним.
        let limit = Self.listLimit
        if let route = env.route.selected, let venues {
            let points = route.points, progress = env.route.progressAlong
            let along = await offMain {
                venues.alongRoute(kind, points: points, progress: progress, limit: limit)
            }
            if !along.isEmpty {
                // «Метан» по пути — тот же порядок по статусу, расстояние остаётся.
                let cngAlong = kind == .cng && env.cng.isActive
                let order = cngAlong ? CngRules.ranked(along.map(\.venue), stations: env.cng.stations)
                                     : along.map(\.venue)
                let ahead = Dictionary(along.map { ($0.venue.id, $0.ahead) }, uniquingKeysWith: { first, _ in first })
                return order.map { venue in
                    let distance = String(format: String(localized: "через %@ по пути"),
                                          Formatting.distance(ahead[venue.id] ?? 0))
                    let status = cngAlong ? env.cng.station(for: venue.point).flatMap(CngRules.caption) : nil
                    return (SavedPlace(title: venue.title, lat: venue.point.latitude, lon: venue.point.longitude),
                            status.map { "\($0) · \(distance)" } ?? distance, true)
                }
            }
        }
        var own = venues?.nearest(kind, to: near, limit: limit) ?? []
        // «Метан» в машине — сначала где газ есть, со строкой статуса (12б.4).
        let cng = kind == .cng && env.cng.isActive
        if cng { own = CngRules.ranked(own, stations: env.cng.stations) }
        if !own.isEmpty {
            return own.map { venue in
                let status = cng ? env.cng.station(for: venue.point).flatMap(CngRules.caption) : nil
                let detail = Self.detail(near: near, point: venue.point, offline: true)
                // В машине расстояние не теряем: «Газ есть, 15 мин назад · 1,2 км».
                return (SavedPlace(title: venue.title, lat: venue.point.latitude, lon: venue.point.longitude),
                        status.map { "\($0) · \(detail)" } ?? detail, false)
            }
        }
        guard env.network.isOnline else { return [] }
        // Apple — категорией POI, а не словом: «AYOQSH» на узбекском Apple
        // не поймёт.
        do {
            return try await VenueBook.apple(kind, near: near).prefix(limit).map { venue in
                (SavedPlace(title: venue.title, lat: venue.point.latitude, lon: venue.point.longitude),
                 Self.detail(near: near, point: venue.point, offline: false), false)
            }
        } catch {
            Log.carplay.error("категория у Apple в машине: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Машина отключилась: идущий запрос ни к чему, а ответ шаблону обязателен.
    func cancelAll() {
        task?.cancel()
        task = nil
        reply?([])
        reply = nil
        lastResults = []
        searching = false
        stopWaitingForList()
    }

    /// Лучшее совпадение для фразы Siri: тот же порядок источников.
    func firstPlace(for text: String) async -> SavedPlace? {
        let query = CarPlaySearchEntry.normalized(text, maxLength: AppConfig.carPlaySearchMaxQueryLength)
        guard CarPlaySearchEntry.isSearchable(query) else { return nil }
        let near = env.location.currentCoordinate
        if let own = await ownPlaces(query, near: near).first { return own.0 }
        guard env.network.isOnline else { return nil }
        return await apple(query, near: near).first?.0
    }

    func makeTemplate() -> CPSearchTemplate {
        let template = CPSearchTemplate()
        template.delegate = self
        return template
    }

    // MARK: - CPSearchTemplateDelegate

    nonisolated func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
                                    completionHandler: @escaping ([CPListItem]) -> Void) {
        nonisolated(unsafe) let completion = completionHandler
        MainActor.assumeIsolated {   // CarPlay зовёт делегат на главном потоке
            self.search(searchText, completion: completion)
        }
    }

    nonisolated func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
                                    completionHandler: @escaping () -> Void) {
        nonisolated(unsafe) let completion = completionHandler
        MainActor.assumeIsolated {
            if let place = item.userInfo as? SavedPlace { self.onPick(place) }
            completion()
        }
    }

    /// «Найти» на клавиатуре машины. До 2.2.16 метод был пустым: нажатие
    /// ничего не делало (аудит CarPlay, 12.10). Теперь — полный список того,
    /// что нашлось, а пусто — честное «ничего не нашлось».
    nonisolated func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
        MainActor.assumeIsolated { self.showAllResults() }
    }

    private func showAllResults() {
        guard CarPlaySearchEntry.listRequest(searching: searching) == .whenReady else { return presentList() }
        listWanted = true
        listFallback?.cancel()
        // Apple медлит — покажем то, что уже есть своего.
        listFallback = Task { [weak self] in
            await Task.pause(seconds: AppConfig.carPlaySearchListWaitSeconds)
            guard let self, !Task.isCancelled, self.listWanted, self.ownReady else { return }
            self.presentList()
        }
    }

    private func stopWaitingForList() {
        listWanted = false
        listFallback?.cancel()
        listFallback = nil
    }

    private func presentList() {
        stopWaitingForList()
        let items: [CPListItem] = lastResults.map { place, detail in
            let item = CPListItem(text: place.title, detailText: detail)
            item.handler = { [weak self] _, completion in
                self?.onPick(place)
                completion()
            }
            return item
        }
        let section = CPListSection(items: items.isEmpty ? [emptyRow()] : items)
        Log.carplay.notice("поиск: «Найти», результатов \(items.count, privacy: .public)")
        present?(CPListTemplate(title: String(localized: "Найдено"), sections: [section]))
    }

    /// Строка «ничего не нашлось»: пустой экран за рулём читается как поломка.
    private func emptyRow() -> CPListItem {
        let detail = CarPlaySearchEntry.empty(online: env.network.isOnline) == .offline
            ? String(localized: "Без сети ищу только по своей карте.")
            : String(localized: "Попробуйте адрес или название иначе")
        let item = CPListItem(text: String(localized: "Ничего не нашлось"), detailText: detail)
        item.isEnabled = false
        return item
    }

    // MARK: - Поиск

    /// Адреса и заведения клетки, где машина сейчас (без позиции — дом или
    /// Ташкент). Ждать её — `await ensureLoaded(near:)`.
    private func ensureLoaded(near: CLLocationCoordinate2D?) async {
        let center = near ?? env.settings.place(for: .home)?.coordinate ?? AppConfig.searchFallbackCenter
        let cell = AddressBook.key(for: center)
        if cell != loadedCell {
            loadedCell = cell
            book = nil
            venues = nil
            index = nil
            loadTask = nil
            indexTask?.cancel()
            indexTask = nil
        }
        guard book == nil || venues == nil else { buildIndex(cell: cell); return }
        if loadTask == nil {
            // Пишем, только если клетка та же: пока грузилась старая, машина
            // могла уехать в новую — и в Самарканде отвечали ташкентские
            // адреса, а проверка выше считала новую клетку загруженной
            // (аудит CarPlay 19.10).
            loadTask = Task { [weak self] in
                guard let self else { return }
                if self.book == nil {
                    let book = await self.env.roads.addressBook(for: center)
                    guard self.loadedCell == cell else { return }
                    self.book = book
                    if book != nil { self.index = nil; self.indexTask?.cancel(); self.indexTask = nil }   // дозагрузилось — индекс заново
                }
                if self.venues == nil {
                    let venues = await self.env.roads.venueBook(for: center)
                    guard self.loadedCell == cell else { return }
                    self.venues = venues
                    if venues != nil { self.index = nil; self.indexTask?.cancel(); self.indexTask = nil }
                }
                self.loadTask = nil
                self.buildIndex(cell: cell)
            }
        }
        await loadTask?.value
    }

    /// Индекс клетки — в фоне, не задерживая ответ: до него — старый поиск.
    private func buildIndex(cell: String) {
        guard index == nil, indexTask == nil, book != nil || venues != nil else { return }
        let book = book, venues = venues
        indexTask = Task { [weak self] in
            let index = await SearchIndex.make(book: book, venues: venues)
            guard let self, self.loadedCell == cell, !Task.isCancelled else { return }
            self.index = index
            self.indexTask = nil
        }
    }

    private func search(_ text: String, completion: @escaping ([CPListItem]) -> Void) {
        task?.cancel()
        reply?([])
        stopWaitingForList()
        let reply = CarPlaySearchReply(completion)
        self.reply = reply
        let query = CarPlaySearchEntry.normalized(text, maxLength: AppConfig.carPlaySearchMaxQueryLength)
        guard CarPlaySearchEntry.isSearchable(query) else {
            lastResults = []
            searching = false
            return reply([])
        }
        let near = env.location.currentCoordinate
        searching = true
        ownReady = false
        task = Task { [weak self] in
            guard let self else { return reply([]) }
            let own = await self.ownPlaces(query, near: near)
            guard !Task.isCancelled else { return }
            let limit = Self.listLimit
            self.lastResults = Array(own.prefix(limit))
            self.ownReady = true
            // Apple — вторым и только со связью: без неё запрос лишь задержит
            // ответ, а свои адреса уже готовы.
            var apple: [(SavedPlace, String)] = []
            if self.env.network.isOnline {
                await Task.pause(seconds: AppConfig.carPlaySearchAppleDebounceSeconds)
                guard !Task.isCancelled else { return }
                apple = await self.apple(query, near: near)
            }
            guard !Task.isCancelled else { return }
            let places = CarPlaySearchEntry.merged(own: own, apple: apple, limit: limit,
                                                   appleSlots: AppConfig.carPlaySearchAppleSlots,
                                                   isSame: Self.samePlace)
            self.lastResults = places
            self.searching = false
            reply(places.isEmpty ? [self.emptyRow()] : places.map { place, detail in
                let item = CPListItem(text: place.title, detailText: detail)
                item.userInfo = place
                return item
            })
            if self.listWanted { self.presentList() }
        }
    }

    /// Свои адреса и заведения по запросу, лучшие первыми.
    private func ownPlaces(_ query: String, near: CLLocationCoordinate2D?) async -> [(SavedPlace, String)] {
        await ensureLoaded(near: near)
        let language = env.settings.appLanguage.mapCode
        // Свой индекс: по всем именам, со старыми («метро хамза»). Пока он
        // строится — как раньше, по одному имени.
        let own = AppConfig.carPlaySearchOwnLimit
        let answer = index?.search(query, near: near, streetLimit: own, venueLimit: own)
            ?? SearchIndex.Answer(addresses: book?.lookup(query, near: near, limit: own) ?? [],
                                  venues: venues?.search(query, near: near, limit: own) ?? [])
        let found: [(SavedPlace, String)] = answer.venues.map { venue in
            (SavedPlace(title: venue.title, lat: venue.point.latitude, lon: venue.point.longitude),
             Self.detail(near: near, point: venue.point, offline: true, former: answer.formerNames[venue.id]))
        }
        let streets: [(SavedPlace, String)] = answer.addresses.map { address in
            let street = StreetName.display(address.street, language: language)
            let title = address.house.isEmpty ? street : "\(street), \(address.house)"
            return (SavedPlace(title: title, lat: address.point.latitude, lon: address.point.longitude),
                    Self.detail(near: near, point: address.point, offline: true,
                                former: answer.formerNames[address.id]))
        }
        // Заведения — первыми, если лучший ответ — место: «азс» за рулём
        // значит «ближайшая заправка», «метро хамза» — станция.
        return answer.venuesFirst ? found + streets : streets + found
    }

    private static func samePlace(_ a: (SavedPlace, String), _ b: (SavedPlace, String)) -> Bool {
        GeoMath.fastDistance(a.0.lat, a.0.lon, b.0.lat, b.0.lon) < AppConfig.carPlayRecentDuplicateMeters
            && SearchIndex.fold(a.0.title) == SearchIndex.fold(b.0.title)
    }

    private func apple(_ query: String, near: CLLocationCoordinate2D?) async -> [(SavedPlace, String)] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let near {
            request.region = MKCoordinateRegion(center: near, latitudinalMeters: AppConfig.searchRegionMeters,
                                                longitudinalMeters: AppConfig.searchRegionMeters)
        }
        let items = await Self.mapItems(MKLocalSearch(request: request))
        return items.prefix(Self.listLimit).compactMap { item in
            let point = item.placemark.coordinate
            guard CLLocationCoordinate2DIsValid(point) else { return nil }
            let title = item.name ?? query
            return (SavedPlace(title: title, lat: point.latitude, lon: point.longitude),
                    Self.detail(near: near, point: point, offline: false))
        }
    }

    /// Запрос к Apple с потолком времени: при плохой связи ответ мог не прийти
    /// вовсе, и шаблон ждал бы, не показывая готовые свои адреса.
    private static func mapItems(_ search: MKLocalSearch) async -> [MKMapItem] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[MKMapItem], Never>) in
            let reply = CarPlaySearchReply<MKMapItem> { continuation.resume(returning: $0) }
            search.start { response, error in
                if let error {
                    Log.carplay.error("поиск Apple в машине: \(error.localizedDescription, privacy: .public)")
                }
                reply(response?.mapItems ?? [])
            }
            Task {
                await Task.pause(seconds: AppConfig.carPlaySearchAppleTimeoutSeconds)
                search.cancel()
                reply([])
            }
        }
    }

    /// Подпись строки: расстояние и откуда ответ («без сети» — свой индекс).
    private static func detail(near: CLLocationCoordinate2D?, point: CLLocationCoordinate2D,
                               offline: Bool, former: String? = nil) -> String {
        let distance = near.map {
            Formatting.distance(GeoMath.fastDistance($0.latitude, $0.longitude, point.latitude, point.longitude))
        }
        let source = offline ? String(localized: "своя карта") : nil
        let was = former.map { String(format: String(localized: "бывш. %@"), $0) }
        return [was, distance, source].compactMap { $0 }.joined(separator: " · ")
    }
}
