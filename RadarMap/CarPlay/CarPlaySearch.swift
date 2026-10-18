//
//  CarPlaySearch.swift
//  RadarMap
//
//  Поиск на экране машины.
//
//  До 10.10.2026 «Куда» в машине умело только Дом, Работу и недавние: адрес,
//  которого в них нет, можно было задать лишь на телефоне. Здесь тот же поиск,
//  что на телефоне, в том же порядке источников: свой индекс адресов (без
//  сети, мгновенно) первым, Apple — вторым. Клавиатура на ходу у CarPlay
//  своя (на большинстве машин — только диктовка), её правила задаёт система.
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
    /// Что нашлось на последний запрос — для полного списка по «Найти».
    private var lastResults: [(SavedPlace, String)] = []
    private var book: AddressBook?
    private var venues: VenueBook?
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
    private var reply: Reply?

    private final class Reply {
        private var send: (([CPListItem]) -> Void)?
        init(_ send: @escaping ([CPListItem]) -> Void) { self.send = send }
        func callAsFunction(_ items: [CPListItem]) {
            send?(items)
            send = nil
        }
    }

    private var env: AppEnvironment { .shared }

    /// Сколько строк покажет список машины: CarPlay сам режет лишнее молча,
    /// а на ходу многие машины держат всего 12 (Руководство CarPlay, стр. 19).
    private static var listLimit: Int {
        min(AppConfig.carPlaySearchLimit, Int(CPListTemplate.maximumItemCount))
    }

    init(onPick: @escaping (SavedPlace) -> Void) {
        self.onPick = onPick
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
            let along = await Task.detached(priority: .userInitiated) {
                venues.alongRoute(kind, points: points, progress: progress, limit: limit)
            }.value
            if !along.isEmpty {
                return along.map { venue, ahead in
                    (SavedPlace(title: venue.title, lat: venue.point.latitude, lon: venue.point.longitude),
                     String(format: String(localized: "через %@ по пути"), Formatting.distance(ahead)),
                     true)
                }
            }
        }
        let own = venues?.nearest(kind, to: near, limit: limit) ?? []
        if !own.isEmpty {
            return own.map { venue in
                (SavedPlace(title: venue.title, lat: venue.point.latitude, lon: venue.point.longitude),
                 Self.detail(near: near, point: venue.point, offline: true), false)
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
        let items: [CPListItem] = lastResults.map { place, detail in
            let item = CPListItem(text: place.title, detailText: detail)
            item.handler = { [weak self] _, completion in
                self?.onPick(place)
                completion()
            }
            return item
        }
        let section = items.isEmpty
            ? CPListSection(items: [CPListItem(text: String(localized: "Ничего не нашлось"),
                                               detailText: String(localized: "Попробуйте адрес или название иначе"))])
            : CPListSection(items: items)
        Log.carplay.notice("поиск: «Найти», результатов \(items.count, privacy: .public)")
        present?(CPListTemplate(title: String(localized: "Найдено"), sections: [section]))
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
            loadTask = nil
        }
        guard book == nil || venues == nil else { return }
        if loadTask == nil {
            loadTask = Task { [weak self] in
                guard let self else { return }
                if self.book == nil { self.book = await self.env.roads.addressBook(for: center) }
                if self.venues == nil { self.venues = await self.env.roads.venueBook(for: center) }
                if self.loadedCell == cell { self.loadTask = nil }
            }
        }
        await loadTask?.value
    }

    private func search(_ text: String, completion: @escaping ([CPListItem]) -> Void) {
        task?.cancel()
        reply?([])
        let reply = Reply(completion)
        self.reply = reply
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            lastResults = []
            return reply([])
        }
        let near = env.location.currentCoordinate
        task = Task { [weak self] in
            guard let self else { return reply([]) }
            await self.ensureLoaded(near: near)
            guard !Task.isCancelled else { return }
            let language = self.env.settings.appLanguage.mapCode
            // Заведения — первыми: «азс» за рулём значит «ближайшая заправка».
            var places: [(SavedPlace, String)] = (self.venues?.search(query, near: near,
                                                                      limit: AppConfig.carPlaySearchOwnLimit) ?? [])
                .map { venue in
                    (SavedPlace(title: venue.title, lat: venue.point.latitude, lon: venue.point.longitude),
                     Self.detail(near: near, point: venue.point, offline: true))
                }
            places += (self.book?.lookup(query, near: near,
                                                                    limit: AppConfig.carPlaySearchOwnLimit) ?? [])
                .map { address in
                    let street = StreetName.display(address.street, language: language)
                    let title = address.house.isEmpty ? street : "\(street), \(address.house)"
                    return (SavedPlace(title: title, lat: address.point.latitude, lon: address.point.longitude),
                            Self.detail(near: near, point: address.point, offline: true))
                }
            // Apple — вторым и только со связью: без неё запрос лишь задержит
            // ответ, а свои адреса уже готовы.
            if self.env.network.isOnline {
                await Task.pause(seconds: AppConfig.carPlaySearchAppleDebounceSeconds)
                guard !Task.isCancelled else { return }
                places += await self.apple(query, near: near)
            }
            guard !Task.isCancelled else { return }
            let limit = Self.listLimit
            self.lastResults = Array(places.prefix(limit))
            reply(places.prefix(limit).map { place, detail in
                let item = CPListItem(text: place.title, detailText: detail)
                item.userInfo = place
                return item
            })
        }
    }

    private func apple(_ query: String, near: CLLocationCoordinate2D?) async -> [(SavedPlace, String)] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let near {
            request.region = MKCoordinateRegion(center: near, latitudinalMeters: AppConfig.searchRegionMeters,
                                                longitudinalMeters: AppConfig.searchRegionMeters)
        }
        do {
            let items = try await MKLocalSearch(request: request).start().mapItems
            return items.prefix(Self.listLimit).compactMap { item in
                let point = item.placemark.coordinate
                guard CLLocationCoordinate2DIsValid(point) else { return nil }
                let title = item.name ?? query
                return (SavedPlace(title: title, lat: point.latitude, lon: point.longitude),
                        Self.detail(near: near, point: point, offline: false))
            }
        } catch {
            Log.carplay.error("поиск Apple в машине: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Подпись строки: расстояние и откуда ответ («без сети» — свой индекс).
    private static func detail(near: CLLocationCoordinate2D?, point: CLLocationCoordinate2D,
                               offline: Bool) -> String {
        let distance = near.map {
            Formatting.distance(GeoMath.fastDistance($0.latitude, $0.longitude, point.latitude, point.longitude))
        }
        let source = offline ? String(localized: "своя карта") : nil
        return [distance, source].compactMap { $0 }.joined(separator: " · ")
    }
}
