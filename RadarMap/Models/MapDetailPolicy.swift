//
//  MapDetailPolicy.swift
//  RadarMap
//
//  Что показывать на карте СЕЙЧАС (29.H, владелец 25.10: «в карплей можно
//  не все объекты показать, только нужные, например когда уже приближается
//  к месту назначения… реши, как лучше»).
//
//  Одно решение на все карты — экран машины, плитку главного экрана,
//  приборку и телефон в поездке: на входе — где карта и что происходит
//  (едем или стоим, есть ли маршрут, сколько осталось до цели, ночь,
//  горячий телефон, чем заправляется машина), на выходе — какие группы
//  объектов видны и сколько их. Карта применяет решение видимостью слоёв и
//  записью своего маленького источника — только на СМЕНЕ решения, без
//  перезагрузки стиля (перф-правила 11.10).
//
//  Режимы:
//    • на ходу — дорога, маршрут, камеры, светофоры; АЗС только по пути и
//      только нужного машине вида, без кафе и магазинов;
//    • стоим (светофор, пробка) — окрестность, заправки и парковки рядом;
//      на телефоне — значки заведений первого ряда (решение 29.D — здесь);
//    • подъезд к цели — номера домов, ореол цели и пунктир от конца
//      маршрута к ней, парковки у цели (ближайшая крупнее), кадр держит
//      цель; остальное гаснет;
//    • дальняя дорога (> 100 км) — на карте только ближайшие впереди из
//      «По пути»;
//    • без маршрута — заправки рядом, без шума;
//    • плитка и приборка — только маршрут, флаг цели и камеры;
//    • телефон вне поездки — как было: решение «всё видно».
//
//  Камер, событий дороги, маршрута и пробок решение не касается вовсе — у
//  него нет для них полей: камера на карте показывается всегда, и никакая
//  «чистая карта» не может её погасить (правило 20).
//
//  Чистая логика, состояние гистерезиса — параметром; MapDetailPolicyTests.
//

import Foundation

nonisolated enum MapDetailPolicy {

    /// Где стоит карта.
    enum Surface: Equatable, Sendable {
        case phone, car, dashboard, cluster

        init(_ surface: CarPlaySurface) {
            switch surface {
            case .car:       self = .car
            case .dashboard: self = .dashboard
            case .cluster:   self = .cluster
            }
        }
    }

    /// Ситуация, которую карта показывает.
    enum Mode: Equatable, Sendable {
        /// Телефон вне поездки: как было, всё по настройкам.
        case browse
        /// Плитка главного экрана и приборка: маршрут и камеры.
        case glance
        /// Едем без маршрута.
        case free
        /// Едем по маршруту.
        case moving
        /// Стоим (светофор, пробка, стоянка).
        case standing
        /// Последние метры до цели.
        case arrival
        /// Дальняя дорога на ходу.
        case longRoute
    }

    /// Значки заведений основы (poi-level-*): сколько рядов.
    enum Places: Int, Comparable, Sendable {
        case none = 0, top, more, all

        static func < (a: Places, b: Places) -> Bool { a.rawValue < b.rawValue }

        /// На ступень реже (ночь).
        var fewer: Places { Places(rawValue: max(0, rawValue - 1)) ?? .none }
    }

    /// Заправки.
    enum Fuel: Equatable, Sendable {
        case hidden
        /// Все в кадре — слой тайлов.
        case nearby
        /// Только ближайшие впереди по маршруту — наши значки (MapDetailPlaces).
        case ahead(Int)
    }

    /// Парковки.
    enum Parking: Equatable, Sendable {
        case hidden
        /// Все в кадре — слои тайлов (контуры стоянок и значки).
        case nearby
        /// У цели: контуры стоянок плюс до N наших значков, ближайшая крупнее.
        /// Своих данных нет — значки тайлов, а не пустота.
        case destination(Int)
    }

    /// Цель маршрута.
    enum Destination: Int, Comparable, Sendable {
        case none = 0
        /// Флаг.
        case flag
        /// Флаг, ореол точки и пунктир от конца маршрута к цели.
        case arrival

        static func < (a: Destination, b: Destination) -> Bool { a.rawValue < b.rawValue }
    }

    struct Context: Equatable, Sendable {
        var surface: Surface
        /// Поездка идёт. Машина подключена — значит едем: для CarPlay true.
        var tripActive: Bool
        /// Стоим — StopView.State.standing (гистерезис 29.D: те же пороги,
        /// что у кадра остановки, — окрестность и кадр меняются одним моментом).
        var standing: Bool
        /// Маршрут построен.
        var hasRoute: Bool
        /// Маршрут строится или перестраивается: остаток застыл и врёт.
        var routePending = false
        /// Осталось до цели по маршруту, м и с; nil — неизвестно.
        var remainingMeters: Double?
        var remainingSeconds: Double?
        /// Длина маршрута целиком, м.
        var routeMeters: Double = 0
        var night = false
        /// Телефон горячий (PerformanceMode не `.full`).
        var hot = false
        /// Карту накрыло полноэкранное предупреждение о камере.
        var covered = false
        /// «Бак на исходе». Источника пока нет нигде — nil, и это «не знаем»,
        /// а не «полный».
        var fuelLow: Bool?
        /// Прошлое решение было «подъезд к цели» (гистерезис).
        var wasArriving = false
    }

    struct Decision: Equatable, Sendable {
        var mode: Mode
        /// Деревья, тени, пешеходные дорожки и тоннели, зерно асфальта.
        var decor: Bool
        var places: Places
        var houseNumbers: Bool
        var fuel: Fuel
        var parking: Parking
        /// Ближайших впереди из «По пути» на дальней дороге (0 — нет).
        var corridor: Int
        /// Кафе и гостиницы «По пути» в этом числе (стоя — да, на ходу — только топливо).
        var corridorFood: Bool
        var destination: Destination
        /// Кадр держит цель и парковки у неё (DriveCamera.Keep).
        var keepDestination: Bool

        var isArrival: Bool { mode == .arrival }

        /// Телефон вне поездки: всё как было до политики.
        static let browse = Decision(mode: .browse, decor: true, places: .all, houseNumbers: true,
                                     fuel: .nearby, parking: .nearby, corridor: 0, corridorFood: false,
                                     destination: .flag, keepDestination: false)
    }

    // MARK: - Решение

    static func decide(_ c: Context) -> Decision {
        if c.surface == .phone, !c.tripActive { return .browse }
        if c.surface == .dashboard || c.surface == .cluster {
            return Decision(mode: .glance, decor: false, places: .none, houseNumbers: false,
                            fuel: .hidden, parking: .hidden, corridor: 0, corridorFood: false,
                            destination: c.hasRoute ? .flag : .none, keepDestination: false)
        }
        let phone = c.surface == .phone
        let mode = mode(c)
        var d: Decision
        switch mode {
        case .browse, .glance:
            return .browse // недостижимо: разобраны выше
        case .free:
            d = Decision(mode: mode, decor: c.standing, places: c.standing ? standingPlaces(c) : .none,
                         houseNumbers: false, fuel: .nearby, parking: c.standing ? .nearby : .hidden,
                         corridor: 0, corridorFood: false, destination: .none, keepDestination: false)
        case .standing:
            d = Decision(mode: mode, decor: true, places: standingPlaces(c), houseNumbers: false,
                         fuel: .nearby, parking: .nearby, corridor: 0, corridorFood: false,
                         destination: .flag, keepDestination: false)
            if isLong(c) {
                d.corridor = phone ? AppConfig.mapDetailCorridorPhone : AppConfig.mapDetailCorridorCar
                d.corridorFood = true
            }
        case .moving:
            d = Decision(mode: mode, decor: false, places: .none, houseNumbers: false,
                         fuel: .ahead(phone ? AppConfig.mapDetailFuelAheadPhone : AppConfig.mapDetailFuelAheadCar),
                         parking: .hidden, corridor: 0, corridorFood: false,
                         destination: .flag, keepDestination: false)
        case .longRoute:
            // Заправки — из «По пути» (коридор в километры), а не городские
            // значки по линии: на трассе следующая колонка бывает в 40 км.
            d = Decision(mode: mode, decor: false, places: .none, houseNumbers: false,
                         fuel: .hidden, parking: .hidden,
                         corridor: phone ? AppConfig.mapDetailCorridorPhone : AppConfig.mapDetailCorridorCar,
                         corridorFood: false, destination: .flag, keepDestination: false)
        case .arrival:
            let parkings = phone ? AppConfig.mapDetailArrivalParkingsPhone : AppConfig.mapDetailArrivalParkingsCar
            d = Decision(mode: mode, decor: c.standing, places: c.standing ? standingPlaces(c) : .none,
                         houseNumbers: true, fuel: .hidden,
                         parking: .destination(parkings), corridor: 0, corridorFood: false,
                         destination: .arrival, keepDestination: true)
        }
        // «Бак на исходе» — заправки по пути и там, где их обычно нет.
        if c.fuelLow == true, mode != .free, mode != .standing {
            d.fuel = .ahead(max(d.fuel.aheadLimit, phone ? AppConfig.mapDetailFuelAheadPhone
                                                          : AppConfig.mapDetailFuelAheadCar))
        }
        return thinned(d, c)
    }

    /// Ночь и горячий телефон — реже: ночью мелкие значки на тёмной карте
    /// бликуют боковому зрению, горячий телефон бережёт кадры. Под тревогой
    /// о камере значков заведений нет вовсе.
    private static func thinned(_ decision: Decision, _ c: Context) -> Decision {
        var d = decision
        if c.night {
            d.places = d.places.fewer
            if case .destination(let n) = d.parking { d.parking = .destination(max(1, n - 1)) }
        }
        if c.hot {
            d.places = .none
            if case .destination(let n) = d.parking {
                d.parking = .destination(min(n, AppConfig.mapDetailHotLimit))
            }
            if case .ahead(let n) = d.fuel { d.fuel = .ahead(min(n, AppConfig.mapDetailHotLimit)) }
            if d.corridor > 0 { d.corridor = min(d.corridor, AppConfig.mapDetailHotCorridor) }
        }
        if c.covered { d.places = .none }
        return d
    }

    /// Значки заведений стоя: телефон — первый ряд (`poi-level-1`, решение
    /// 29.D: со вторым рядом на остановке у развилки было десять подписей —
    /// «нужные детали» превращались в справочник). Машина — нет: на снимке
    /// остановки первый ряд в машине — это школа, салон красоты и банк, а
    /// «полезное по пути» стоя — заправки и парковки, они и так видны;
    /// экран машины читают боковым зрением.
    private static func standingPlaces(_ c: Context) -> Places {
        c.surface == .phone ? .top : .none
    }

    private static func isLong(_ c: Context) -> Bool {
        c.hasRoute && RouteCorridor.isLong(c.routeMeters)
    }

    static func mode(_ c: Context) -> Mode {
        if c.surface == .phone, !c.tripActive { return .browse }
        if c.surface == .dashboard || c.surface == .cluster { return .glance }
        if isArriving(c) { return .arrival }
        guard c.hasRoute else { return .free }
        if c.standing { return .standing }
        return isLong(c) ? .longRoute : .moving
    }

    // MARK: - Подъезд к цели

    /// Подъезд к цели с гистерезисом. Вход — осталось ≤ `mapDetailArrivalEnterMeters`
    /// или ≤ `mapDetailArrivalEnterSeconds` (время — только ближе
    /// `mapDetailArrivalTimeCeilingMeters`: три минуты на трассе — это 4,5 км,
    /// там ещё рано). Выход — дальше `mapDetailArrivalExitMeters` и (дольше
    /// `mapDetailArrivalExitSeconds` или дальше потолка времени).
    /// Без маршрута цели нет — режима нет. Маршрут перестраивается у цели —
    /// остаток застыл или пуст, и прежнее решение держится: кадр не
    /// отскакивает в «на ходу» на одно перестроение.
    static func isArriving(_ c: Context) -> Bool {
        if c.wasArriving, c.routePending { return true }
        guard c.hasRoute, let meters = c.remainingMeters, meters.isFinite, meters >= 0 else { return false }
        let seconds = c.remainingSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if c.wasArriving {
            let farByTime = seconds.map { $0 > AppConfig.mapDetailArrivalExitSeconds } ?? true
            let exit = meters > AppConfig.mapDetailArrivalExitMeters
                && (farByTime || meters > AppConfig.mapDetailArrivalTimeCeilingMeters)
            return !exit
        }
        if meters <= AppConfig.mapDetailArrivalEnterMeters { return true }
        if let seconds, meters <= AppConfig.mapDetailArrivalTimeCeilingMeters,
           seconds <= AppConfig.mapDetailArrivalEnterSeconds { return true }
        return false
    }
}

extension MapDetailPolicy.Fuel {
    /// Сколько значков «по пути» (0 — не по пути).
    var aheadLimit: Int {
        if case .ahead(let n) = self { return n }
        return 0
    }
}

extension MapDetailPolicy.Parking {
    /// Сколько своих значков парковок у цели (0 — не у цели).
    var destinationLimit: Int {
        if case .destination(let n) = self { return n }
        return 0
    }
}
