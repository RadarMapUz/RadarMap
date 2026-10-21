//
//  RouteCorridor.swift
//  RadarMap
//
//  Коридор длинного маршрута (19.3): какие области офлайн-карты и какие
//  клетки заведений задевает полоса вокруг линии, и когда предлагать
//  «Скачать карту по пути».
//
//  Зачем. На трассах Ташкент — Фергана (Камчик) и Ташкент — Самарканд —
//  Бухара связь пропадает часами, а карта без сети рисуется только там, где
//  область скачана. Камеры предупреждают и без неё — база на телефоне, — но
//  серая карта на перевале читается поломкой, а маршрут без сети без графа
//  трасс не строится вовсе.
//
//  Правила спроса — те же, что у разового предложения своей области
//  (OfflineOffer), плюс одно своё:
//  - только длинный маршрут (`corridorLongRouteMeters`);
//  - только по Wi-Fi: сотни мегабайт по мобильной сети не предлагаем —
//    правило сервиса офлайн-карт, а не этого экрана;
//  - один раз на маршрут (по цели): ответ, крестик или то, что машина
//    тронулась, закрывают вопрос до новой цели — на светофоре карточка не
//    всплывает, решение про мегабайты на ходу не принимают;
//  - вопрос «Радар ещё стоял?» и уточнение «Что это было?» старше: живут
//    секунды и требуют ответа, а мегабайты подождут (больше двух карточек
//    внизу не бывает, 5.9).
//
//  Чистое — покрыто RouteCorridorTests.
//

import CoreLocation
import Foundation

nonisolated enum RouteCorridor {

    /// Маршрут — дальняя поездка.
    static func isLong(_ meters: CLLocationDistance) -> Bool {
        meters > AppConfig.corridorLongRouteMeters
    }

    /// Ключ маршрута для «один раз»: цель с точностью ~100 м. Перестроение
    /// после съезда, смена варианта и заезд по пути — тот же маршрут: цель та
    /// же, и спрашивать снова незачем.
    static func routeKey(destination: CLLocationCoordinate2D) -> String {
        String(format: "%.3f,%.3f", destination.latitude, destination.longitude)
    }

    // MARK: - Пробы вдоль линии

    /// Точки линии не реже `step` метров: вершины и промежуточные точки на
    /// длинных прямых (у трассы OSRM вершины бывают через километры).
    static func samples(_ route: [CLLocationCoordinate2D],
                        step: CLLocationDistance = AppConfig.corridorSampleMeters) -> [CLLocationCoordinate2D] {
        guard let first = route.first else { return [] }
        var out = [first]
        guard route.count >= 2, step > 0 else { return out }
        for i in 1..<route.count {
            let a = route[i - 1], b = route[i]
            let length = GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude)
            let parts = max(1, Int((length / step).rounded(.up)))
            for k in 1...parts {
                let t = Double(k) / Double(parts)
                out.append(CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                  longitude: a.longitude + (b.longitude - a.longitude) * t))
            }
        }
        return out
    }

    /// Рамка ±`buffer` метров вокруг точки: (юго-запад, северо-восток).
    static func box(around point: CLLocationCoordinate2D,
                    buffer: CLLocationDistance) -> (sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) {
        let dLat = buffer / 111_320
        let dLon = buffer / (111_320 * max(0.01, cos(point.latitude * .pi / 180)))
        return (CLLocationCoordinate2D(latitude: point.latitude - dLat, longitude: point.longitude - dLon),
                CLLocationCoordinate2D(latitude: point.latitude + dLat, longitude: point.longitude + dLon))
    }

    // MARK: - Области офлайн-карты

    /// Области каталога, которые задевает полоса ±`buffer` вокруг маршрута, —
    /// по порядку первой встречи по ходу (первой качается та, что раньше
    /// понадобится).
    ///
    /// Клетки рамки вокруг каждой пробы перебираются целиком, а не углы: так
    /// ответ точен при любом зуме каталога, а не только пока клетка шире
    /// полосы.
    static func regions(route: [CLLocationCoordinate2D], catalog: RegionCatalog,
                        buffer: CLLocationDistance = AppConfig.corridorRegionBufferMeters,
                        step: CLLocationDistance = AppConfig.corridorSampleMeters) -> [RegionCatalog.Region] {
        var seenCells = Set<Int64>()
        var found = Set<String>()
        var ordered: [RegionCatalog.Region] = []
        for sample in samples(route, step: step) {
            let (sw, ne) = box(around: sample, buffer: buffer)
            // y растёт к югу: север даёт меньший y.
            let low = RegionCatalog.cell(of: CLLocationCoordinate2D(latitude: ne.latitude, longitude: sw.longitude),
                                         zoom: catalog.cellZoom)
            let high = RegionCatalog.cell(of: CLLocationCoordinate2D(latitude: sw.latitude, longitude: ne.longitude),
                                          zoom: catalog.cellZoom)
            for y in low.y...max(low.y, high.y) {
                for x in low.x...max(low.x, high.x) {
                    guard seenCells.insert(Int64(y) << 32 | Int64(x)).inserted else { continue }
                    guard let region = catalog.regions.first(where: { $0.contains(cellX: x, cellY: y) }),
                          found.insert(region.id).inserted else { continue }
                    ordered.append(region)
                }
            }
        }
        return ordered
    }

    // MARK: - Клетки заведений

    /// Клетка файла заведений (`VenueBook.key`) и точка внутри неё — по ней
    /// файл и просят у RoadNetworkService.
    struct VenueCell: Equatable, Sendable {
        let key: String
        let point: CLLocationCoordinate2D

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    }

    /// Клетки заведений, которые задевает полоса ±`buffer`, — по ходу.
    static func venueCells(route: [CLLocationCoordinate2D],
                           buffer: CLLocationDistance = AppConfig.corridorVenueMeters,
                           step: CLLocationDistance = AppConfig.corridorSampleMeters) -> [VenueCell] {
        let size = AddressBook.cellDegrees
        var seen = Set<String>()
        var ordered: [VenueCell] = []
        for sample in samples(route, step: step) {
            let (sw, ne) = box(around: sample, buffer: buffer)
            let rows = Int(floor((sw.latitude + 90) / size))...Int(floor((ne.latitude + 90) / size))
            let columns = Int(floor((sw.longitude + 180) / size))...Int(floor((ne.longitude + 180) / size))
            for row in rows {
                for column in columns {
                    // Центр клетки — та же формула ключа даст ровно эту клетку.
                    let point = CLLocationCoordinate2D(latitude: (Double(row) + 0.5) * size - 90,
                                                       longitude: (Double(column) + 0.5) * size - 180)
                    let key = VenueBook.key(for: point)
                    guard seen.insert(key).inserted else { continue }
                    ordered.append(VenueCell(key: key, point: point))
                }
            }
        }
        return ordered
    }

    /// Можно ли качать недостающие файлы заведений коридора.
    ///
    /// По Wi-Fi — да: файл клетки — сотни килобайт, а без них «По пути» на
    /// трассе без связи пуст. По мобильной сети — только с явного согласия
    /// (кнопка с размером в «По пути» или «Скачать» карты по пути): клеток
    /// на маршрут — десяток-полтора, и молча будить ими радио нельзя. Без
    /// связи — только то, что уже на телефоне.
    static func mayFetchCells(online: Bool, expensiveNetwork: Bool, consented: Bool) -> Bool {
        online && (!expensiveNetwork || consented)
    }

    // MARK: - Предложение «Скачать карту по пути»

    /// Что качать: не скачанные области коридора по ходу и граф трасс, если
    /// он есть на сервере, а на телефоне нет.
    struct Offer: Equatable, Sendable {
        let regions: [RegionCatalog.Region]
        /// Размер графа трасс по подписанному индексу сервера; nil — граф на
        /// телефоне или сервер его не публикует (предлагать нечего).
        let graphBytes: Int?

        var isEmpty: Bool { regions.isEmpty && graphBytes == nil }
        var totalBytes: Int64 {
            regions.reduce(0) { $0 + $1.totalBytes } + Int64(graphBytes ?? 0)
        }
    }

    /// Состав предложения: области коридора, которые `isMissing` (не скачаны
    /// и не качаются), в порядке коридора.
    static func offer(corridor: [RegionCatalog.Region], isMissing: (RegionCatalog.Region) -> Bool,
                      graphBytes: Int?) -> Offer {
        Offer(regions: corridor.filter(isMissing), graphBytes: graphBytes)
    }

    struct Situation: Equatable, Sendable {
        var routeMeters: CLLocationDistance
        var online: Bool
        var expensiveNetwork: Bool
        /// Поездка идёт и машина тронулась.
        var moving: Bool
        /// На этом маршруте уже ответили или уехали.
        var answered: Bool
        /// На экране вопрос, который ждёт ответа («Радар ещё стоял?»,
        /// «Что это было?») или итог поездки — уступаем.
        var questionShown: Bool
    }

    static func shouldOffer(_ s: Situation, offer: Offer) -> Bool {
        isLong(s.routeMeters) && !offer.isEmpty && s.online && !s.expensiveNetwork
            && !s.moving && !s.answered && !s.questionShown
    }

    /// Короткие имена областей для строки карточки: «Джизакская», «Jizzax»
    /// без «область»/«viloyati» — пять полных названий занимали на SE четыре
    /// строки. Где короткие совпали («Toshkent» и «Toshkent viloyati»), оба
    /// остаются полными: два одинаковых слова подряд ничего не говорят.
    static func shortNames(_ titles: [String]) -> [String] {
        let short = titles.map(shortName)
        var counts: [String: Int] = [:]
        for name in short { counts[name.lowercased(), default: 0] += 1 }
        return zip(titles, short).map { full, cut in counts[cut.lowercased(), default: 0] > 1 ? full : cut }
    }

    static func shortName(_ title: String) -> String {
        var name = title.trimmingCharacters(in: .whitespaces)
        for suffix in [" область", " viloyati", " respublikasi"]
        where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        for prefix in ["республика "] where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        return name.isEmpty ? title : name
    }
}
