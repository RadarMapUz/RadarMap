//
//  RouteCorridorService.swift
//  RadarMap
//
//  Коридор маршрута (19.3): что скачать перед дальней дорогой и что есть
//  «По пути». Решения — в чистых RouteCorridor и CorridorVenues; здесь
//  только оркестрация: каталог областей, граф трасс, файлы заведений с
//  диска и сети и память «на этом маршруте уже спросили».
//
//  Политика загрузок (решение 19.3):
//  - области карты — только по согласию («Скачать» на карточке), а карточка —
//    только по Wi-Fi, как разовое предложение своей области (OfflineOffer);
//  - граф трасс — по прежнему правилу сервиса: первый файл любой связью; на
//    длинном маршруте лишь не ждём недельной проверки (ensureGraph);
//  - файлы заведений коридора — по Wi-Fi сами (сотни килобайт на маршрут,
//    без них «По пути» на трассе без связи пуст), по мобильной сети — только
//    после согласия: «Скачать» карты по пути или кнопка с размером в «По
//    пути». Молча будить радио полутора десятками файлов нельзя.
//
//  Камер это не касается никак: база на телефоне, предупреждения работают
//  без всего, что здесь качается (правило 20).
//

import CoreLocation
import Foundation
import MapKit
import Observation
import os

@MainActor
@Observable
final class RouteCorridorService {

    /// Снос без прыжка на актор — тот же обход бага рантайма, что у
    /// остальных сервисов (см. RouteService).
    nonisolated deinit {}

    @ObservationIgnored weak var maps: OfflineMapService?
    @ObservationIgnored weak var graph: OfflineRouteService?
    @ObservationIgnored weak var roads: RoadNetworkService?
    @ObservationIgnored weak var network: NetworkMonitor?

    /// Коридор выбранного длинного маршрута: области по ходу.
    struct Plan: Equatable {
        let key: String
        let line: ObjectIdentifier
        let regions: [RegionCatalog.Region]
    }
    private(set) var plan: Plan?
    /// Размер графа трасс, если сервер его публикует, а на телефоне его нет.
    private(set) var graphBytes: Int?
    /// Маршруты (по цели), на которых карточка своё отработала: ответ,
    /// крестик или машина тронулась. Только на запуск: маршрут на диске не
    /// живёт, а завтрашняя дорога — новый вопрос.
    private(set) var answered: Set<String> = []
    /// Маршруты, на которых водитель согласился качать данные коридора и по
    /// мобильной сети.
    @ObservationIgnored private(set) var consented: Set<String> = []
    /// Линия, для которой файлы заведений уже положены по Wi-Fi.
    @ObservationIgnored private var prefetchedLine: ObjectIdentifier?

    #if DEBUG
    /// Скриншот-хук: заведения вдоль демо-маршрута вместо файлов клеток.
    @ObservationIgnored var demoVenues: [Venue]?
    #endif

    // MARK: - Коридор маршрута

    /// Посчитать коридор выбранного варианта (новая линия — новый расчёт),
    /// проверить граф и по Wi-Fi положить файлы заведений. Зовёт карточка
    /// (`.task(id:)` по линии и сети) — пока её нет на экране, ничего не
    /// считается.
    func prepare(route: RouteService) async {
        guard let variant = route.selected, let destination = route.destinationCoordinate,
              RouteCorridor.isLong(variant.distance) else {
            if plan != nil { plan = nil }
            return
        }
        let line = ObjectIdentifier(variant.polyline)
        let key = RouteCorridor.routeKey(destination: destination)
        let online = network?.isOnline ?? false
        let wifi = online && !(network?.isExpensive ?? true)
        let points = variant.points

        if plan?.line != line || (plan?.regions.isEmpty ?? true) {
            // Каталог — маленький подписанный файл, но спрашивать его ради
            // карточки, которую по мобильной сети не покажем, незачем.
            if maps?.catalog == nil, wifi { await maps?.refreshCatalog() }
            var regions: [RegionCatalog.Region] = []
            if let catalog = maps?.catalog {
                regions = await offMain {
                    RouteCorridor.regions(route: points.map(\.coordinate), catalog: catalog)
                }
            }
            // Пока считали, маршрут сменился — ответ уже не про него (правило 12).
            guard route.selected.map({ ObjectIdentifier($0.polyline) }) == line else { return }
            plan = Plan(key: key, line: line, regions: regions)
            graphBytes = await graph?.ensureGraph()
        }
        if wifi, prefetchedLine != line {
            prefetchedLine = line
            await prefetchCells(points: points)
        }
    }

    /// Что предложить на текущем маршруте: не скачанные и не качающиеся
    /// области коридора и граф трасс. nil — коридора нет.
    func offer() -> RouteCorridor.Offer? {
        guard let plan, let maps else { return nil }
        return RouteCorridor.offer(corridor: plan.regions, isMissing: { region in
            switch maps.state(for: region) {
            case .notDownloaded, .failed: return true
            case .downloading, .ready, .updateAvailable: return false
            }
        }, graphBytes: graphBytes)
    }

    /// Крестик, ответ или машина тронулась: на этом маршруте больше не спрашиваем.
    func answer(key: String) {
        guard !answered.contains(key) else { return }
        answered.insert(key)
    }

    /// «Скачать»: области, граф и файлы заведений — с согласием и на случай,
    /// если Wi-Fi кончится посреди загрузки.
    func download(_ offer: RouteCorridor.Offer, key: String, points: [MKMapPoint]) {
        answer(key: key)
        consented.insert(key)
        for region in offer.regions { maps?.download(region) }
        Task {
            if offer.graphBytes != nil {
                graphBytes = await graph?.ensureGraph(force: true)
            }
            await prefetchCells(points: points)
        }
    }

    /// Файлы заведений коридора — на диск, по ходу. Только опубликованные.
    private func prefetchCells(points: [MKMapPoint]) async {
        guard let roads else { return }
        let cells = await offMain { RouteCorridor.venueCells(route: points.map(\.coordinate)) }
        var fetched = 0
        for cell in cells where roads.venueCellBytes(for: cell.point) != nil {
            if await roads.prefetchVenues(for: cell.point) { fetched += 1 }
        }
        Log.route.info("коридор: файлов заведений на телефоне \(fetched, privacy: .public) из \(cells.count, privacy: .public)")
    }

    // MARK: - «По пути»

    /// Ответ списка: найденное и честный счёт того, чего нет.
    struct Found: Equatable {
        var items: [CorridorVenues.Item]
        /// Клеток впереди, которые опубликованы, но не на телефоне.
        var missingCells: Int
        var missingBytes: Int
        /// Клеток впереди, о которых у нас нет данных вовсе.
        var unpublishedCells: Int
        var totalCells: Int
    }

    /// Согласие на загрузку по мобильной сети для этого маршрута (кнопка с
    /// размером в «По пути»).
    func consent(key: String) {
        consented.insert(key)
    }

    /// Заведения `kinds` впереди по выбранному маршруту. nil — маршрута нет.
    func venues(route: RouteService, kinds: [Venue.Kind]) async -> Found? {
        guard let variant = route.selected, let destination = route.destinationCoordinate else { return nil }
        let key = RouteCorridor.routeKey(destination: destination)
        let points = variant.points
        let progress = route.progressAlong
        let wanted = Set(kinds)
        var books: [VenueBook] = []
        var missing = 0, missingBytes = 0, unpublished = 0
        var cells: [RouteCorridor.VenueCell] = []
        #if DEBUG
        if let demoVenues { books = [VenueBook(venues: demoVenues)] }
        #endif
        if books.isEmpty {
            // Клетки — только впереди: позади заведения не нужны, и качать их незачем.
            cells = await offMain {
                RouteCorridor.venueCells(route: RouteService.remaining(points, after: progress))
            }
            let fetch = RouteCorridor.mayFetchCells(online: network?.isOnline ?? false,
                                                    expensiveNetwork: network?.isExpensive ?? true,
                                                    consented: consented.contains(key))
            for cell in cells {
                guard let bytes = roads?.venueCellBytes(for: cell.point) else {
                    unpublished += 1
                    continue
                }
                if let book = await roads?.venueBook(for: cell.point, allowDownload: fetch) {
                    books.append(book)
                } else {
                    missing += 1
                    missingBytes += bytes
                }
            }
        }
        let loaded = books
        let items = await offMain {
            CorridorVenues.find(loaded.flatMap { $0.venues.filter { wanted.contains($0.kind) } },
                                route: points, progress: progress, kinds: wanted)
        }
        return Found(items: items, missingCells: missing, missingBytes: missingBytes,
                     unpublishedCells: unpublished, totalCells: cells.count)
    }

    #if DEBUG
    /// Демо-заведения вдоль выбранного маршрута (`-demoLongRoute`): по обе
    /// стороны, на разном удалении, с дублем у одной колонки.
    func seedDemoVenues(route: RouteService) -> [Venue] {
        guard let variant = route.selected else { return [] }
        let pts = variant.points
        let cum = RouteService.cumulative(of: pts)
        let plan: [(km: Double, side: Double, kind: Venue.Kind, name: String)] = [
            (6, 120, .fuel, "Mustang"), (6.01, 130, .fuel, ""), (14, -300, .cng, "Metan Chinoz"),
            (23, 60, .food, "Choyxona Yoʻlbars"), (31, -900, .lpg, "Propan Sirdaryo"),
            (47, 300, .cng, "AGNKS Guliston"), (58, -1400, .hotel, "Guliston Hotel"),
            (72, 40, .fuel, "Uzbekneftegaz"), (95, 700, .food, "Kafe Jizzax"),
            (118, -250, .cng, "Metan Zomin"), (140, 1800, .hotel, "Mehmonxona Sharq"),
            (165, 90, .fuel, "Lukoil"), (190, -500, .cng, "AGNKS Bulungʻur"),
            (220, 200, .food, "Samarqand Osh Markazi"), (240, 2600, .hotel, "Uzoq mehmonxona"),
        ]
        var venues: [Venue] = []
        for entry in plan {
            guard let base = RouteService.pointAndCourse(along: entry.km * 1000, pts: pts, cum: cum) else { continue }
            let bearing = base.course + (entry.side >= 0 ? 90 : -90)
            let point = GeoMath.destination(from: base.coordinate, bearing: bearing,
                                            distanceMeters: abs(entry.side))
            venues.append(Venue(kind: entry.kind, name: entry.name, point: point))
        }
        demoVenues = venues
        return venues
    }
    #endif
}
