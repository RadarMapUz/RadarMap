//
//  VenueBook.swift
//  RadarMap
//
//  Заведения для поиска — АЗС, парковки, мойки — из своего подписанного
//  файла клетки (набор «v», server/build_roads.py VENUE_KINDS).
//
//  «АЗС рядом» — первый вопрос водителя к поиску, а Apple в Узбекистане на
//  него почти не отвечает. Свой индекс отвечает всегда и без сети; Apple
//  остаётся запасным, пока клетка не опубликована.
//
//  Чистая логика — VenueBookTests.
//

import CoreLocation
import Foundation
import MapKit

nonisolated struct Venue: Sendable, Equatable, Identifiable {
    /// Коды — контракт с сервером (VENUE_KINDS). Незнакомый код пропускается:
    /// сервер вправе завести новый вид раньше, чем выйдет сборка.
    enum Kind: Int, Sendable, CaseIterable {
        case fuel = 1, parking, carWash, carRepair, tyres, charging, food, pharmacy, atm, supermarket
        /// Гостиницы — для междугородних (OSM + сертифицированные с портала
        /// открытых данных). Метан (АГНКС) и пропан (АГЗС) — отдельно от
        /// бензина (13.10): большинство машин на газу, и «АЗС» в поиске
        /// отвечала всеми заправками подряд. Коды — контракт с build_roads.py.
        case hotel = 11, cng = 12, lpg = 13

        var title: String {
            switch self {
            case .fuel:        return String(localized: "АЗС")
            case .parking:     return String(localized: "Парковка")
            case .carWash:     return String(localized: "Мойка")
            case .carRepair:   return String(localized: "Автосервис")
            case .tyres:       return String(localized: "Шиномонтаж")
            case .charging:    return String(localized: "Зарядка")
            case .food:        return String(localized: "Еда")
            case .pharmacy:    return String(localized: "Аптека")
            case .atm:         return String(localized: "Банкомат")
            case .supermarket: return String(localized: "Супермаркет")
            case .hotel:       return String(localized: "Гостиница")
            case .cng:         return String(localized: "Метан")
            case .lpg:         return String(localized: "Пропан")
            }
        }

        var symbol: String {
            switch self {
            case .fuel:        return "fuelpump.fill"
            case .parking:     return "parkingsign"
            // Пена, а не машина с «!»: та читалась как поломка.
            case .carWash:     return "bubbles.and.sparkles.fill"
            case .carRepair:   return "wrench.and.screwdriver.fill"
            // Колесо, а не мишень.
            case .tyres:       return "tirepressure"
            case .charging:    return "bolt.car.fill"
            case .food:        return "fork.knife"
            case .pharmacy:    return "cross.case.fill"
            case .atm:         return "banknote.fill"
            case .supermarket: return "cart.fill"
            case .hotel:       return "bed.double.fill"
            case .cng:         return "flame.fill"
            case .lpg:         return "flame"
            }
        }

        /// Слова, которыми этот вид ищут («заправка», «yoqilg'i»): запрос
        /// словом вида отвечает ближайшими такого вида, а не заведениями,
        /// в чьём имени это слово случайно есть.
        var searchWords: [String] {
            switch self {
            case .fuel:        return ["азс", "заправка", "бензин", "zapravka", "benzin", "yoqilg'i", "azs"]
            case .hotel:       return ["гостиница", "отель", "хостел", "mehmonxona", "hotel", "otel"]
            case .cng:         return ["метан", "агнкс", "metan", "agnks", "gaz"]
            case .lpg:         return ["пропан", "агзс", "propan", "agzs", "suyultirilgan"]
            case .parking:     return ["парковка", "стоянка", "parking", "avtoturargoh", "to'xtash"]
            case .carWash:     return ["мойка", "автомойка", "moyka", "avtomoyka"]
            case .carRepair:   return ["автосервис", "сервис", "ремонт", "сто", "servis", "ta'mirlash"]
            case .tyres:       return ["шиномонтаж", "вулканизация", "shinomontaj", "vulkanizatsiya"]
            case .charging:    return ["зарядка", "электрозарядка", "zaryadka", "quvvatlash"]
            case .food:        return ["кафе", "ресторан", "еда", "kafe", "restoran", "ovqat", "oshxona"]
            case .pharmacy:    return ["аптека", "dorixona", "apteka"]
            case .atm:         return ["банкомат", "банк", "bankomat", "bank"]
            case .supermarket: return ["супермаркет", "магазин", "supermarket", "do'kon"]
            }
        }

        /// Плитки на пустом экране поиска — то, что ищут из машины.
        static let quick: [Kind] = [.fuel, .cng, .lpg, .parking, .carWash, .tyres, .charging, .pharmacy, .atm, .food]
    }

    let kind: Kind
    let name: String
    let point: CLLocationCoordinate2D

    /// Безымянная парковка подписывается видом, а не пустой строкой.
    var title: String { name.isEmpty ? kind.title : name }

    var id: String {
        String(format: "%d|%@|%.5f|%.5f", kind.rawValue, name, point.latitude, point.longitude)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

nonisolated struct VenueBook: Sendable {
    let venues: [Venue]
    /// Сведённые имена — один раз при разборе, а не на каждую букву.
    private let tokens: [[String]]

    init(venues: [Venue]) {
        self.venues = venues
        tokens = venues.map { AddressBook.streetTokens($0.name) }
    }

    /// Ключ клетки — как у адресов, с буквой набора «v».
    static func key(for coordinate: CLLocationCoordinate2D) -> String {
        let row = Int(floor((coordinate.latitude + 90) / AddressBook.cellDegrees))
        let column = Int(floor((coordinate.longitude + 180) / AddressBook.cellDegrees))
        return "\(row)_\(column)_v"
    }

    /// Разобрать файл клетки: {"version":1,"venues":[[код, имя, lat, lon], …]}.
    /// nil — файл не наш; запись с незнакомым кодом или битыми числами —
    /// пропускается, а не роняет клетку.
    static func decode(_ data: Data) -> VenueBook? {
        // Не JSON — тот же ответ «файл не наш» (nil), что и при чужом формате.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["venues"] as? [[Any]] else { return nil }
        var out: [Venue] = []
        out.reserveCapacity(rows.count)
        for row in rows where row.count >= 4 {
            guard let code = (row[0] as? NSNumber)?.intValue, let kind = Venue.Kind(rawValue: code),
                  let name = row[1] as? String,
                  let lat = (row[2] as? NSNumber)?.doubleValue,
                  let lon = (row[3] as? NSNumber)?.doubleValue else { continue }
            out.append(Venue(kind: kind, name: name,
                             point: CLLocationCoordinate2D(latitude: lat / RoadTiles.scale,
                                                           longitude: lon / RoadTiles.scale)))
        }
        return VenueBook(venues: out)
    }

    /// Ближайшие заведения вида. Без позиции — первые по файлу (честнее, чем
    /// ничего: человек всё равно видит, что они есть).
    func nearest(_ kind: Venue.Kind, to near: CLLocationCoordinate2D?, limit: Int = 12) -> [Venue] {
        let ofKind = venues.filter { $0.kind == kind }
        guard let near else { return Array(ofKind.prefix(limit)) }
        return Array(ofKind.map { ($0, Self.distance(near, $0.point)) }
            .sorted { $0.1 < $1.1 }.prefix(limit).map(\.0))
    }

    /// Заведения вида ПО ПУТИ: не дальше `corridor` от линии маршрута и
    /// впереди текущего места, по порядку следования. С маршрутом «ближайшая
    /// АЗС» бывает позади или за рекой, а нужна та, что встретится на пути.
    func alongRoute(_ kind: Venue.Kind, points: [MKMapPoint], progress: Double,
                    corridor: Double = AppConfig.venueRouteCorridorMeters,
                    limit: Int = 8) -> [(venue: Venue, ahead: Double)] {
        guard points.count >= 2 else { return [] }
        var cum = [Double](repeating: 0, count: points.count)
        for i in 1..<points.count { cum[i] = cum[i - 1] + points[i - 1].distance(to: points[i]) }
        var rect = MKMapRect.null
        for point in points { rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0))) }
        let pad = corridor * MKMapPointsPerMeterAtLatitude(points[0].coordinate.latitude)
        rect = rect.insetBy(dx: -pad, dy: -pad)
        var found: [(venue: Venue, ahead: Double)] = []
        for venue in venues where venue.kind == kind {
            let point = MKMapPoint(venue.point)
            guard rect.contains(point) else { continue }
            var hint = 0
            let (along, deviation) = RouteService.project(point, onto: points, cum: cum, hint: &hint)
            guard deviation <= corridor, along > progress else { continue }
            found.append((venue, along - progress))
        }
        return Array(found.sorted { $0.ahead < $1.ahead }.prefix(limit))
    }

    /// Вид, если запрос — слово вида («заправка», «мойка»).
    ///
    /// Сначала точное слово во ВСЕХ видах, потом начало слова: «СТО» —
    /// автосервис, хотя оно же начало «стоянки», и первый по порядку вид
    /// (парковка) забирал его. Бренды («Корзинка») в слова вида не входят:
    /// их ищут по имени, а не списком всех супермаркетов.
    static func kind(for query: String) -> Venue.Kind? {
        let folded = AddressBook.fold(query)
        guard folded.count >= 3 else { return nil }
        if let exact = foldedKindWords.first(where: { $0.words.contains(folded) }) {
            return exact.kind
        }
        return foldedKindWords.first { $0.words.contains { $0.hasPrefix(folded) } }?.kind
    }

    /// Слова видов, уже приведённые: раньше каждая буква запроса заново
    /// приводила все ~70 слов, до двух раз (аудит 11.10). Порядок видов —
    /// как в allCases: первый по порядку вид побеждает при равенстве.
    private static let foldedKindWords: [(kind: Venue.Kind, words: [String])] =
        Venue.Kind.allCases.map { kind in (kind, kind.searchWords.map { AddressBook.fold($0) }) }

    /// Как спросить Apple о виде: категорией POI, где она есть (не зависит
    /// от языка — «AYOQSH» Apple не поймёт), иначе словом по-русски.
    static func appleQuery(_ kind: Venue.Kind) -> (categories: [MKPointOfInterestCategory], words: String) {
        switch kind {
        case .fuel:        return ([.gasStation], "АЗС")
        case .parking:     return ([.parking], "парковка")
        case .carWash:     return ([], "автомойка")
        case .carRepair:   return ([.automotiveRepair], "автосервис")
        case .tyres:       return ([], "шиномонтаж")
        case .charging:    return ([.evCharger], "зарядная станция")
        case .food:        return ([.restaurant, .cafe], "кафе")
        case .pharmacy:    return ([.pharmacy], "аптека")
        case .atm:         return ([.atm, .bank], "банкомат")
        case .supermarket: return ([.foodMarket], "супермаркет")
        case .hotel:       return ([.hotel], "гостиница")
        case .cng:         return ([.gasStation], "метан заправка")
        case .lpg:         return ([.gasStation], "пропан заправка")
        }
    }

    /// Поиск Apple по виду вокруг точки — общий для телефона и машины.
    static func apple(_ kind: Venue.Kind, near: CLLocationCoordinate2D?) async throws -> [Venue] {
        let (categories, words) = appleQuery(kind)
        let items: [MKMapItem]
        if let near, !categories.isEmpty {
            let request = MKLocalPointsOfInterestRequest(center: near, radius: AppConfig.appleCategoryRadiusMeters)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)
            items = try await MKLocalSearch(request: request).start().mapItems
        } else {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = words
            request.resultTypes = .pointOfInterest
            if let near {
                request.region = MKCoordinateRegion(center: near, latitudinalMeters: AppConfig.searchRegionMeters,
                                                    longitudinalMeters: AppConfig.searchRegionMeters)
            }
            items = try await MKLocalSearch(request: request).start().mapItems
        }
        let found = items.map { Venue(kind: kind, name: $0.name ?? "", point: $0.placemark.coordinate) }
        guard let near else { return found }
        return found.sorted { distance(near, $0.point) < distance(near, $1.point) }
    }

    /// Поиск: слово вида — ближайшие этого вида; иначе — по имени (каждое
    /// слово запроса начинает какое-нибудь слово имени), ближние выше.
    func search(_ query: String, near: CLLocationCoordinate2D?, limit: Int = 8) -> [Venue] {
        if let kind = Self.kind(for: query) { return nearest(kind, to: near, limit: limit) }
        let want = AddressBook.tokens(query)
        guard !want.isEmpty, AddressBook.fold(query).count >= 2 else { return [] }
        var found: [(Venue, Double)] = []
        for (index, venue) in venues.enumerated() where !venue.name.isEmpty {
            let words = tokens[index]
            guard want.allSatisfy({ word in words.contains { $0.hasPrefix(word) } }) else { continue }
            found.append((venue, near.map { Self.distance($0, venue.point) } ?? 0))
        }
        return Array(found.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0))
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude)
    }
}
