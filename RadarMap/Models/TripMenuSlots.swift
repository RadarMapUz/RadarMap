//
//  TripMenuSlots.swift
//  RadarMap
//
//  Меню «…» — плитки 3 × 2 с постоянными местами (этап 45, вариант A
//  дизайнера, выбор владельца 05.11).
//
//  До 45 это был системный `Menu` до четырнадцати строк, пять из них
//  условные: пункт то был, то нет, и строки ниже съезжали — рука искала
//  «Поделиться» там, где минуту назад стояло «Рядом». Здесь у каждой плитки
//  своё место навсегда: неприменимая бледнеет, а не исчезает, и что она
//  делает, зависит от того, есть ли маршрут. На стоянке добавляется третий
//  ряд — первые два не двигаются.
//
//  Чистая логика — TripMenuSlotsTests.
//

import Foundation

nonisolated enum TripMenuSlots {

    /// Место плитки — по порядку на экране, слева направо, сверху вниз.
    enum Slot: Int, CaseIterable, Sendable {
        case search, myPlaces, along
        case cameras, share, map
        // Третий ряд — только на стоянке.
        case stats, addCamera, settings
    }

    /// Что делает плитка сейчас.
    enum Action: Equatable, Sendable {
        case search
        case myPlaces
        /// Заправки, гостиницы, кафе впереди по маршруту.
        case alongRoute
        /// Без маршрута — свой вид топлива рядом (поиск по плитке).
        case nearbyStops
        /// Камеры на маршруте.
        case routeCameras
        /// Без маршрута — ближайшие камеры (бывшее «Рядом»).
        case nearbyCameras
        case shareArrival
        case stopSharing
        /// И маршрут (прибытие), и «Еду домой» уместны — короткий выбор из
        /// двух прямо в панели: ни один пункт прежнего меню не теряется.
        case shareChoice(arrivalEnabled: Bool, sharing: Bool)
        /// Назад из выбора «Поделиться» к плиткам (только внутри панели).
        case back
        /// Без маршрута — «Еду домой» близким (22.1).
        case goingHome
        /// Слои, пробки, объёмный вид, весь маршрут.
        case mapPanel
        case stats
        case addCamera
        case settings
    }

    struct Tile: Equatable, Identifiable, Sendable {
        let slot: Slot
        let action: Action
        /// Неприменимая плитка бледнеет, но стоит на своём месте.
        let enabled: Bool
        var id: Slot { slot }
    }

    struct Situation: Equatable, Sendable {
        var hasRoute = false
        /// Ссылка прибытия уже живёт.
        var isSharingArrival = false
        /// Ссылку прибытия можно начать (маршрут и сервер).
        var canShareArrival = false
        /// «Еду домой» уместно (круг семьи, режим «когда еду домой»).
        var offersGoingHome = false
        /// Стоим (< 20 км/ч, TripScreenLayout.tripMenuShowsParkedItems) —
        /// третий ряд с экранами на минуту чтения.
        var parked = false
    }

    /// Третий ряд с гистерезисом: появляется ниже `enter`, уходит от `leave`.
    /// Без него у 20 км/ч ряд мигал, и первые два ряда прыгали под пальцем
    /// (панель прижата низом к стопке).
    static func parked(speedKmh: Double, wasParked: Bool,
                       enter: Double = AppConfig.tripMenuParkedEnterKmh,
                       leave: Double = AppConfig.speakSpeedThresholdKmh) -> Bool {
        wasParked ? speedKmh < leave : speedKmh < enter
    }

    static func tiles(_ situation: Situation) -> [Tile] {
        let slots = Slot.allCases.filter { situation.parked || $0.rawValue < Slot.stats.rawValue }
        return slots.map { tile($0, situation) }
    }

    private static func tile(_ slot: Slot, _ s: Situation) -> Tile {
        switch slot {
        case .search:    return Tile(slot: slot, action: .search, enabled: true)
        case .myPlaces:  return Tile(slot: slot, action: .myPlaces, enabled: true)
        case .along:     return Tile(slot: slot, action: s.hasRoute ? .alongRoute : .nearbyStops, enabled: true)
        case .cameras:   return Tile(slot: slot, action: s.hasRoute ? .routeCameras : .nearbyCameras, enabled: true)
        case .share:
            if s.offersGoingHome, s.hasRoute || s.isSharingArrival {
                return Tile(slot: slot, action: .shareChoice(arrivalEnabled: s.canShareArrival || s.isSharingArrival,
                                                             sharing: s.isSharingArrival),
                            enabled: true)
            }
            if s.isSharingArrival { return Tile(slot: slot, action: .stopSharing, enabled: true) }
            if s.hasRoute { return Tile(slot: slot, action: .shareArrival, enabled: s.canShareArrival) }
            return Tile(slot: slot, action: s.offersGoingHome ? .goingHome : .shareArrival,
                        enabled: s.offersGoingHome)
        case .map:       return Tile(slot: slot, action: .mapPanel, enabled: true)
        case .stats:     return Tile(slot: slot, action: .stats, enabled: true)
        case .addCamera: return Tile(slot: slot, action: .addCamera, enabled: true)
        case .settings:  return Tile(slot: slot, action: .settings, enabled: true)
        }
    }
}
