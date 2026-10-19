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
}
