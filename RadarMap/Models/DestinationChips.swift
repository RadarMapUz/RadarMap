//
//  DestinationChips.swift
//  RadarMap
//
//  Чипы «Домой · 25 мин» и «На работу» под полем «Куда едем?» главного
//  экрана (этап 45, вариант A дизайнера).
//
//  Оба чипа стоят всегда — на своих местах, как у Apple Maps «Избранное»:
//  рука находит «Домой» там же, где вчера. Синим и с минутами — только
//  уверенная догадка (DestinationGuess): одна строка «Домой» была в доке и
//  раньше, но появлялась и исчезала, и место под пальцем менялось. Места нет
//  ни заданного, ни выученного — чип ведёт в «Мои места», а не в пустоту.
//  Заданный рукой адрес старше выученного.
//
//  Чистая логика — DestinationChipsTests.
//

import Foundation

nonisolated enum DestinationChips {

    /// Известное место: координата и, если задано рукой, адрес.
    struct Place: Equatable, Sendable {
        let lat: Double
        let lon: Double
        let title: String?
    }

    struct Chip: Equatable, Sendable, Identifiable {
        let kind: FrequentPlaces.Kind
        /// nil — места нет: касание ведёт в «Мои места».
        let place: Place?
        /// Уверенная догадка «сейчас туда» — синим.
        let guessed: Bool
        /// «· 25 мин» — только у догадки и только когда время известно.
        let minutes: Int?
        /// Мы уже у этого места (тот же радиус, что у догадки «стоим у места»):
        /// чип бледный, маршрут «из дома в дом» не строится.
        var isHere = false
        var id: String { kind.rawValue }
    }

    /// - `manual`: адреса, заданные рукой (Настройки → Мои места).
    /// - `learned`: места из распорядка (FrequentPlaces); пусто, если
    ///   «Приложение учится» выключено.
    /// - `guess`: уверенная догадка и её время в пути, секунды.
    /// - `here`: где мы сейчас; nil — неизвестно (тогда «у места» не бывает).
    static func make(manual: [FrequentPlaces.Kind: Place], learned: [FrequentPlaces.Place],
                     guess: (kind: FrequentPlaces.Kind, seconds: TimeInterval?)?,
                     here: (lat: Double, lon: Double)? = nil,
                     atRadius: Double = AppConfig.placeAtRadiusMeters) -> [Chip] {
        [FrequentPlaces.Kind.home, .work].map { kind in
            let place = manual[kind]
                ?? learned.first { $0.kind == kind }.map { Place(lat: $0.lat, lon: $0.lon, title: nil) }
            let isHere = zip2(place, here).map {
                GeoMath.fastDistance($0.0.lat, $0.0.lon, $0.1.lat, $0.1.lon) <= atRadius
            } ?? false
            let guessed = guess?.kind == kind && place != nil && !isHere
            let minutes = guessed ? guess?.seconds.map { max(1, Int(($0 / 60).rounded())) } : nil
            return Chip(kind: kind, place: place, guessed: guessed, minutes: minutes, isHere: isHere)
        }
    }

    private static func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
        guard let a, let b else { return nil }
        return (a, b)
    }
}
