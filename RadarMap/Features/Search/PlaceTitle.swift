//
//  PlaceTitle.swift
//  RadarMap
//
//  Название точки для «Моих мест»: свой адресник на языке приложения (как у
//  булавки PlacePickerMap и остановок поездки), без сети и без Apple. Нет
//  дома рядом — честное «Текущее место», которое можно переименовать.
//

import CoreLocation
import Foundation

enum PlaceTitle {
    static func resolve(_ point: CLLocationCoordinate2D, env: AppEnvironment) async -> String {
        if let book = await env.roads.addressBook(for: point),
           let address = book.nearest(to: point, within: AppConfig.placePickerAddressMeters) {
            let street = StreetName.display(address.street, language: env.settings.appLanguage.mapCode)
            return address.house.isEmpty ? street : "\(street), \(address.house)"
        }
        return String(localized: "Текущее место")
    }

    /// «Текущее место» для Дом/Работа — одно на «Мои места» и Настройки.
    /// Положение читается в момент нажатия, а не при сборке меню: чтение
    /// `currentCoordinate` в body пересобирало лист на каждом фиксе.
    @MainActor
    static func currentAssigner(_ slot: PlaceSlot, env: AppEnvironment) -> (() -> Void)? {
        guard env.location.hasLocation else { return nil }
        return {
            guard let point = env.location.currentCoordinate else { return }
            Task {
                let title = await resolve(point, env: env)
                env.settings.setPlace(SavedPlace(title: title, lat: point.latitude, lon: point.longitude),
                                      for: slot)
            }
        }
    }
}
