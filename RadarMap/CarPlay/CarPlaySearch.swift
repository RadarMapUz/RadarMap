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
    private var book: AddressBook?
    private var bookAsked = false
    private var task: Task<Void, Never>?

    private var env: AppEnvironment { .shared }

    init(onPick: @escaping (SavedPlace) -> Void) {
        self.onPick = onPick
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

    nonisolated func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {}

    // MARK: - Поиск

    private func search(_ text: String, completion: @escaping ([CPListItem]) -> Void) {
        task?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return completion([]) }
        let near = env.location.currentCoordinate
        task = Task { [weak self] in
            guard let self else { return completion([]) }
            if !self.bookAsked {
                self.bookAsked = true
                self.book = await self.env.roads.addressBook(
                    for: near ?? self.env.settings.place(for: .home)?.coordinate ?? AppConfig.searchFallbackCenter)
            }
            let language = self.env.settings.appLanguage.mapCode
            var places: [(SavedPlace, String)] = (self.book?.lookup(query, near: near,
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
                places += await self.apple(query, near: near)
            }
            guard !Task.isCancelled else { return }
            completion(places.prefix(AppConfig.carPlaySearchLimit).map { place, detail in
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
            return items.prefix(AppConfig.carPlaySearchLimit).compactMap { item in
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
