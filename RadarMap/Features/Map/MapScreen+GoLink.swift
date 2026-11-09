//
//  MapScreen+GoLink.swift
//  RadarMap
//
//  radarmap://go/home и go/work — виджет «Дорога», Пункт управления. Маршрут
//  тем же путём, что у «Моих мест» (buildRoute): карточка выбора и «Поехали»,
//  поездка сама не стартует. Адрес — заданный руками, без него выученный.
//

import CoreLocation
import SwiftUI

extension MapScreen {
    /// true — ссылка про маршрут и разобрана здесь.
    func handleGoLink(_ url: URL) -> Bool {
        let key = SharedDefaults.store?.string(forKey: TripLink.storeKey)
        guard let decision = TripLink.decideGo(url, expectedKey: key) else { return false }
        closeSheetsForLink()
        map.showStats = false
        switch decision {
        case .route(let place):
            routeToSaved(place)
        case .confirm(let place):
            // Через ход цикла: при холодном старте вопрос в тот же такт теряется.
            Task { @MainActor in
                StartTripPrompt.presentRoute(title: place == .home
                                             ? String(localized: "Построить маршрут домой?")
                                             : String(localized: "Построить маршрут на работу?")) {
                    routeToSaved(place)
                }
            }
        }
        return true
    }

    /// Поверх может быть другой шит: вторая презентация молча не проходит.
    func closeSheetsForLink() {
        map.selectedCamera = nil
        map.showNearbySheet = false
        map.showSearch = false
        map.showSettings = false
        showRouteCameras = false
        showAlongRoute = false
        showLongTrip = false
        showMyPlaces = false
        showsWhatsNew = false
        tripEndDetail = nil
        showFines = false
    }

    private func routeToSaved(_ place: TripLink.GoPlace) {
        let slot: PlaceSlot = place == .home ? .home : .work
        let kind: FrequentPlaces.Kind = place == .home ? .home : .work
        Task { @MainActor in
            // Холодный старт с виджета: выученные места считаются по истории
            // с диска, она ещё едет.
            if env.settings.place(for: slot) == nil {
                for _ in 0..<AppConfig.siriHistoryWaitSteps where !env.trip.isLoaded {
                    await Task.pause(seconds: 0.1)
                }
            }
            guard let target = env.settings.place(for: slot)?.coordinate
                    ?? env.learnedPlaces.first(where: { $0.kind == kind })?.coordinate else {
                showMyPlaces = true
                return
            }
            buildRoute(to: target, name: slot.name)
        }
    }
}
