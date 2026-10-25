//
//  MapDetailService.swift
//  RadarMap
//
//  Данные для наших значков «нужного сейчас» (29.H): заправки вида машины
//  впереди по маршруту, парковки у цели, ближайшие из «По пути» на дальней
//  дороге. Что из этого показать и сколько — решает MapDetailPolicy в каждой
//  карте (телефон, экран машины, плитка, приборка); здесь — только найти.
//
//  Когда считается: на каждом принятом фиксе с маршрутом сверяется ключ
//  (линия, цель, километр пути, «близко к цели»), и только на его смене —
//  поиск вне main. Файлы — те же подписанные файлы заведений, что у поиска
//  (RoadNetworkService.venueBook): своя клетка и клетка цели, это один-два
//  файла на город. Дальняя дорога — через RouteCorridorService, у него своя
//  политика загрузок (по мобильной сети — только с согласия), и не чаще
//  раза в `corridorStepMeters`: коридор — это чтение десятка файлов.
//
//  Камер это не касается: значки — картинка, решение о них не читает ни
//  один гейт (правило 20).
//

import CoreLocation
import Foundation
import MapKit
import Observation

@MainActor
@Observable
final class MapDetailService {

    /// Снос без прыжка на актор — тот же обход бага рантайма, что у
    /// остальных сервисов (см. RouteService).
    nonisolated deinit {}

    @ObservationIgnored weak var roads: RoadNetworkService?
    @ObservationIgnored weak var corridor: RouteCorridorService?
    @ObservationIgnored weak var route: RouteService?
    /// Топливо машины по порядку (VehicleEnergy.stops) — из настроек.
    @ObservationIgnored var fuelKinds: () -> [Venue.Kind] = { [.fuel] }

    /// Найденное для текущего маршрута; пусто — маршрута нет или данных нет.
    private(set) var found = MapDetailPlaces.Found.empty

    private struct Key: Equatable {
        var line: ObjectIdentifier
        var latitude: Double
        var longitude: Double
        var step: Int
        var corridorStep: Int
        var near: Bool
        var kinds: [Int]
    }
    @ObservationIgnored private var key: Key?
    /// Поколение (правило 12): пока искали, маршрут могли сменить.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Файлы заведений, уже разобранные: своя клетка и клетка цели. Сервис
    /// дорог читает файл с диска и сверяет sha на КАЖДЫЙ вызов, а здесь он
    /// нужен раз в километр — без памяти это мегабайты JSON на каждом шаге.
    @ObservationIgnored private var books: [String: VenueBook] = [:]

    private func book(for point: CLLocationCoordinate2D) async -> VenueBook? {
        let cell = VenueBook.key(for: point)
        if let cached = books[cell] { return cached }
        guard let loaded = await roads?.venueBook(for: point) else { return nil }
        // Две клетки на маршрут — своя и цели; больше не держим.
        if books.count >= 2 { books.removeAll() }
        books[cell] = loaded
        return loaded
    }

    /// Коридор дальней дороги — не чаще, чем через столько метров пути.
    private static let corridorStepMeters = 5 * AppConfig.mapDetailRefreshMeters

    /// Принятый фикс (AppEnvironment.onAcceptedFix). Дёшево: ключ сравнивается
    /// с прошлым, поиск — только на его смене.
    func note(position: CLLocationCoordinate2D) {
        guard let route, let variant = route.selected, let destination = route.destinationCoordinate else {
            clear()
            return
        }
        let progress = route.progressAlong
        let kinds = fuelKinds()
        let long = RouteCorridor.isLong(variant.distance)
        let near = route.remainingDistance <= AppConfig.mapDetailArrivalTimeCeilingMeters
        let next = Key(line: ObjectIdentifier(variant.polyline),
                       latitude: destination.latitude, longitude: destination.longitude,
                       step: Int(progress / AppConfig.mapDetailRefreshMeters),
                       corridorStep: long ? Int(progress / Self.corridorStepMeters) : 0,
                       near: near, kinds: kinds.map(\.rawValue))
        guard next != key else { return }
        let corridorDue = long && (key?.line != next.line || key?.corridorStep != next.corridorStep)
        key = next
        generation &+= 1
        let current = generation
        let points = variant.points
        let previousCorridor = corridorDue ? [] : found.corridor
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            var result = MapDetailPlaces.Found(corridor: previousCorridor)
            if let book = await self.book(for: position) {
                let venues = book.venues
                result.fuelAhead = await offMain {
                    MapDetailPlaces.fuelAhead(venues, kinds: kinds, route: points, progress: progress)
                }
            }
            if near, let book = await self.book(for: destination) {
                let venues = book.venues
                result.parkings = await offMain { MapDetailPlaces.parkings(venues, destination: destination) }
            }
            if corridorDue, let corridor = self.corridor, let route = self.route {
                let items = await corridor.venues(route: route, kinds: CorridorVenues.kinds(fuel: kinds))?.items ?? []
                result.corridor = items.map(\.venue)
            }
            guard current == self.generation, !Task.isCancelled else { return }
            #if DEBUG
            if result.parkings.isEmpty, near, let demo = self.demoParkings { result.parkings = demo }
            #endif
            if result != self.found { self.found = result }
        }
    }

    /// Маршрута нет — значков нет.
    func clear() {
        guard key != nil || found != .empty else { return }
        key = nil
        generation &+= 1
        task?.cancel()
        task = nil
        books = [:]
        found = .empty
    }

    #if DEBUG
    /// `-demoArrival`: парковки у демо-цели, если файла заведений нет
    /// (симулятор без сети, клетка не опубликована) — снимки режима прибытия.
    @ObservationIgnored var demoParkings: [Venue]?

    func seedDemoParkings(around destination: CLLocationCoordinate2D) {
        let plan: [(bearing: Double, meters: Double, name: String)] = [
            (40, 70, "Parking A"), (200, 140, ""), (300, 230, "Parking C"), (120, 280, ""),
        ]
        demoParkings = plan.map {
            Venue(kind: .parking, name: $0.name,
                  point: GeoMath.destination(from: destination, bearing: $0.bearing, distanceMeters: $0.meters))
        }
        key = nil
    }
    #endif
}
