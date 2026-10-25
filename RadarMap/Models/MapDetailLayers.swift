//
//  MapDetailLayers.swift
//  RadarMap
//
//  Решение MapDetailPolicy → слои стиля (29.H): какие спрятать, какие
//  показать поверх режима «в поездке». Отдельно от движка, чтобы проверить
//  тестом главное: ни камеры, ни маршрут, ни события дороги, ни пробки в эти
//  списки не попадают никогда. Слоя нет в стиле — карта его пропускает.
//

import Foundation

nonisolated enum MapDetailLayers {

    /// «Не дорога»: подземные пешеходные переходы и тротуары (широкие
    /// фиолетовые полосы поперёк проспекта — «убери тоннели», 12.10),
    /// наложение тоннелей, деревья и тени, зерно асфальта, имена арыков (у
    /// моста ложились наискось поперёк проспекта, CarPlay 13.10). Подписи
    /// дорожек (`highway-name-path`) прячет режим «в поездке» сам.
    static let decor = [
        "tunnel-path-steps-casing", "tunnel-path-steps", "tunnel-path",
        "bridge-path-shadow", "bridge-path-casing", "bridge-path-steps", "bridge-path",
        "highway-path-steps-casing", "highway-path", "highway-path-steps",
        "radar-tunnel-case", "radar-tunnel",
        "trees", "radar-tree-shadow", "radar-tree", "radar-tree-light", "radar-tree-3d", "radar-barrier-3d",
        "building-ground-shadow",
        "radar-asphalt-grain",
        "waterway-name",
    ]
    /// Ряды значков заведений основы — по порядку важности.
    static let placeRows = ["poi-level-1", "poi-level-2", "poi-level-3", "poi-railway"]
    static let houseNumbers = ["housenumber"]
    /// Заправки слоя тайлов (все в кадре).
    static let fuel = ["radar-poi-fuel"]
    /// Контуры стоянок и разметка мест.
    static let parkingAreas = ["radar-parking", "radar-parking-kerb", "radar-parking-stall"]
    /// Значки парковок слоя тайлов.
    static let parkingIcons = ["radar-poi-parking"]

    /// Все слои, которыми распоряжается решение: видимость остальных оно не
    /// трогает.
    static let managed: Set<String> = Set(decor + placeRows + houseNumbers + fuel + parkingAreas + parkingIcons)

    /// Спрятать.
    static func hidden(_ d: MapDetailPolicy.Decision, destinationParkingsKnown: Bool = true) -> Set<String> {
        managed.subtracting(shown(d, destinationParkingsKnown: destinationParkingsKnown))
    }

    /// Показать — и поверх режима «в поездке» (он прячет заведения и номера
    /// домов на любой скорости).
    static func shown(_ d: MapDetailPolicy.Decision, destinationParkingsKnown: Bool = true) -> Set<String> {
        var out = Set<String>()
        if d.decor { out.formUnion(decor) }
        out.formUnion(placeRows.prefix(rows(d.places)))
        if d.houseNumbers { out.formUnion(houseNumbers) }
        if d.fuel == .nearby { out.formUnion(fuel) }
        switch d.parking {
        case .hidden:
            break
        case .nearby:
            out.formUnion(parkingAreas)
            out.formUnion(parkingIcons)
        case .destination:
            out.formUnion(parkingAreas)
            // Своих значков у цели нет — значки тайлов, а не пустота.
            if !destinationParkingsKnown { out.formUnion(parkingIcons) }
        }
        return out
    }

    /// Ряды значков, вернувшиеся на карту поездки (стоим, у цели): их карта
    /// не кладёт под «я» (EngineStopDetail, 29.D). Вне поездки телефона — пусто:
    /// там значки как были, без круга у машины.
    static func tripPlaceRows(_ d: MapDetailPolicy.Decision) -> [String] {
        d.mode == .browse ? [] : Array(placeRows.prefix(rows(d.places)))
    }

    private static func rows(_ places: MapDetailPolicy.Places) -> Int {
        switch places {
        case .none: 0
        case .top:  1
        case .more: 2
        case .all:  placeRows.count
        }
    }
}
