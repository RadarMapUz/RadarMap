//
//  RoadTiles.swift
//  RadarMap
//
//  Собственная дорожная сеть для схемы приборки: тайлы по 0.5° с сервера
//  (server/build_roads.py), в отличие от индекса лимитов знающие класс
//  дороги, мост, тоннель и односторонность — то есть всё, чем схема
//  отличает развязку от перекрёстка.
//
//  Целостность устроена в два звена: подписан ИНДЕКС (Ed25519, через общий
//  SignedPayload — правило 19: молча применяемые данные только под подписью),
//  а каждый тайл сверяется с sha256 из этого индекса. Подменённый на сервере
//  или по дороге тайл не сойдётся по хэшу и будет отброшен — при этом сами
//  тайлы возятся без подписи, и подпись владельца нужна одна на весь набор.
//
//  Формат тайла — контракт с server/build_roads.py (см. его шапку):
//  {"version":1,"roads":[[cls, flags, [lat, lon, dlat, dlon, …]], …]},
//  координаты в целых 1e-5°, первая абсолютная, дальше дельты.
//
//  Чистая распаковка и сеточный индекс, покрыты RoadTilesTests.
//

import CoreLocation
import CryptoKit
import Foundation

nonisolated enum RoadTiles {

    static let formatVersion = 1
    /// Новый формат: мелкая сетка и три набора на тайл — костяк района,
    /// улицы, дворовые проезды. Разложен так не для красоты: дворы это
    /// половина всех дорог, а видны они только когда мы сами во дворе, и в
    /// отдельном файле телефон просто не качает их всю остальную дорогу.
    static let formatVersionV2 = 2

    /// Наборы нового формата. Ключ индекса составной: «тайл_набор» — так он
    /// ложится в тот же плоский словарь, что и раньше.
    enum Set: String, CaseIterable, Sendable {
        case far = "f", streets = "s", yards = "y"
        case water = "w", green = "g", rail = "r", blocks = "b"
        /// Точечные объекты. Наборов ДВА: ближний посажен на детальную
        /// геометрию, дальний пересчитан по костяку района — там раздельные
        /// проезжие сведены в одну ось, и точка с детальной сети уехала бы от
        /// нарисованной линии на полширины проспекта.
        case points = "p"
        case pointsFar = "q"

        /// Наборы местности разбираются в SketchArea, дорожные — в RoadLine.
        var isArea: Bool {
            switch self {
            case .far, .streets, .yards, .points, .pointsFar: return false
            case .water, .green, .rail, .blocks: return true
            }
        }

        /// Набор точечных объектов: у него своя распаковка — одна координата
        /// вместо ломаной.
        var isPoints: Bool { self == .points || self == .pointsFar }

        /// Вид местности набора. nil — набор дорожный.
        var areaKind: SketchArea.Kind? {
            switch self {
            case .water:  return .water
            case .green:  return .green
            case .rail:   return .rail
            case .blocks: return .block
            case .far, .streets, .yards, .points, .pointsFar: return nil
            }
        }
    }

    static func setKey(_ tile: String, _ set: Set) -> String { "\(tile)_\(set.rawValue)" }

    /// Имя файла тайла на сервере и на диске.
    static func fileName(key: String, version: Int) -> String {
        version >= formatVersionV2 ? "road2_\(key).json" : "tile_\(key).json"
    }
    /// Масштаб координат в тайле: 1e-5° ≈ 1,1 м.
    static let scale = 1e5

    /// Подписанный индекс: какие тайлы существуют и их sha256.
    struct Index: Decodable, Sendable, Equatable {
        let version: Int
        let tileDegrees: Double
        let tiles: [String: TileMeta]

        struct TileMeta: Decodable, Sendable, Equatable {
            let sha256: String
            let bytes: Int
        }
    }

    /// Ключ тайла — ровно та же формула, что в build_roads.py: смещение в
    /// положительные, чтобы не спорить об округлении отрицательных.
    static func tileKey(latitude: Double, longitude: Double,
                        tileDegrees: Double) -> String {
        let latIndex = Int(floor((latitude + 90) / tileDegrees))
        let lonIndex = Int(floor((longitude + 180) / tileDegrees))
        return "\(latIndex)_\(lonIndex)"
    }

    /// Окрестность 3×3: свой тайл и все соседние — граница тайла не должна
    /// быть краем мира на схеме.
    static func neighborhood(of coordinate: CLLocationCoordinate2D,
                             tileDegrees: Double) -> [String] {
        var keys: [String] = []
        for latStep in -1...1 {
            for lonStep in -1...1 {
                keys.append(tileKey(latitude: coordinate.latitude + Double(latStep) * tileDegrees,
                                    longitude: coordinate.longitude + Double(lonStep) * tileDegrees,
                                    tileDegrees: tileDegrees))
            }
        }
        return keys
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Код класса из тайла → RoadClass. Неизвестный код будущего формата —
    /// «.unknown»: дорогу рисуем, но тонко и без обещаний.
    static func roadClass(code: Int) -> RoadClass {
        switch code {
        case 1: .motorway
        case 2: .trunk
        case 3: .primary
        case 4: .secondary
        case 5: .tertiary
        case 6: .residential
        case 7: .service
        default: .unknown
        }
    }

    /// Распаковать тайл местности.
    ///
    /// Формат тот же, что у дорог, и это не совпадение, а решение: одна
    /// распаковка дельт на оба слоя. Первое число — вид, второе — биты, из
    /// которых нам нужен один: замкнут контур или нет.
    static func decodeAreas(_ data: Data) -> [SketchArea]? {
        guard let raw = decodeEntries(data) else { return nil }
        var areas: [SketchArea] = []
        areas.reserveCapacity(raw.count)
        for entry in raw {
            guard let kind = SketchArea.Kind(rawValue: entry.code) else { continue }
            areas.append(SketchArea(points: entry.points, kind: kind,
                                    isClosed: entry.flags & 1 != 0))
        }
        return areas
    }

    /// Распаковать тайл. `nil` — формат не тот: sha уже сошёлся, значит это
    /// не порча по дороге, а дрейф формата, и правильный ответ — не рисовать
    /// ничего, а не рисовать наполовину разобранное.
    /// Одна запись тайла: код, биты и распакованные дельты.
    private struct Entry {
        let code: Int
        let flags: Int
        let points: [CLLocationCoordinate2D]
        /// Имя четвёртым элементом и только там, где оно есть: у одной дороги
        /// из семи. Писать пустую строку остальным значило бы платить за неё
        /// местом у всех.
        let name: String
    }

    /// Распаковка, общая для дорог и местности. Держать её в одном месте
    /// важнее краткости: формат дельт — контракт с сервером, и разойтись двум
    /// его читателям нельзя.
    /// Распаковать тайл точечных объектов.
    ///
    /// Вид, которого приложение не знает, пропускается, а не валит тайл:
    /// панель вправе завести новый раньше, чем выйдет сборка, и светофоры в
    /// том же файле водитель увидеть обязан.
    static func decodePoints(_ data: Data) -> [SketchPoint]? {
        guard let raw = decodeEntries(data, minimumCoordinates: 1) else { return nil }
        return raw.compactMap { entry in
            guard let kind = SketchPoint.Kind(rawValue: entry.code),
                  let point = entry.points.first else { return nil }
            return SketchPoint(coordinate: point, kind: kind)
        }
    }

    private static func decodeEntries(_ data: Data,
                                      minimumCoordinates: Int = 2) -> [Entry]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? Int,
              version == formatVersion || version == formatVersionV2,
              let rawEntries = root["roads"] as? [[Any]] else { return nil }

        var entries: [Entry] = []
        entries.reserveCapacity(rawEntries.count)
        for entry in rawEntries {
            guard entry.count == 3 || entry.count == 4,
                  let code = (entry[0] as? NSNumber)?.intValue,
                  let flags = (entry[1] as? NSNumber)?.intValue,
                  let flat = entry[2] as? [NSNumber],
                  flat.count >= minimumCoordinates * 2,
                  flat.count % 2 == 0 else { return nil }

            var points: [CLLocationCoordinate2D] = []
            points.reserveCapacity(flat.count / 2)
            var lat = 0, lon = 0
            for i in stride(from: 0, to: flat.count - 1, by: 2) {
                if i == 0 {
                    lat = flat[0].intValue
                    lon = flat[1].intValue
                } else {
                    lat += flat[i].intValue
                    lon += flat[i + 1].intValue
                }
                points.append(CLLocationCoordinate2D(latitude: Double(lat) / scale,
                                                     longitude: Double(lon) / scale))
            }
            let name = entry.count > 3 ? (entry[3] as? String ?? "") : ""
            entries.append(Entry(code: code, flags: flags, points: points, name: name))
        }
        return entries
    }

    static func decodeTile(_ data: Data) -> [RoadLine]? {
        guard let entries = decodeEntries(data) else { return nil }
        // Биты flags: 1 = одностороннее, 2 = мост, 4 = тоннель, 8 = кольцо.
        return entries.map { entry in
            RoadLine(points: entry.points,
                     kind: roadClass(code: entry.code),
                     level: entry.flags & 2 != 0 ? 1 : (entry.flags & 4 != 0 ? -1 : 0),
                     isOneWay: entry.flags & 1 != 0 && entry.flags & 8 == 0,
                     isDetailed: true,
                     isRing: entry.flags & 8 != 0,
                     name: entry.name)
        }
    }
}

// MARK: - Сеточный индекс по загруженным тайлам

/// Иммутабельный снимок загруженных тайлов: строится в фоне, читается с
/// главного потока без блокировок — тот же приём, что LimitIndex.
nonisolated struct TileRoadNetwork: RoadNetworkSource {
    let lines: [RoadLine]
    let grid: [Int: [Int32]]   // ячейка 0.01° → индексы линий

    private static func cellKey(lat: Double, lon: Double) -> Int {
        Int((lat + 90) * 100) * 40_000 + Int((lon + 180) * 100)
    }

    /// Ключ схлопывания дублей на границе тайлов.
    ///
    /// Все шесть полей исходного ключа обязаны остаться: одни и те же концы
    /// бывают у РАЗНЫХ дорог — мостовой сегмент над одноимённым участком имеет
    /// те же крайние точки, но другой класс и другое число точек. Ужать ключ
    /// до пары чисел, выбросив класс и счётчик, значит молча стереть со схемы
    /// сотню настоящих дорог ради трёх мегабайт.
    private struct LineKey: Hashable {
        let cls: UInt8
        let count: Int32
        let ax, ay, bx, by: Int32

        init(line: RoadLine, first: CLLocationCoordinate2D, last: CLLocationCoordinate2D) {
            // truncatingIfNeeded, а не ловушечный Int32(): тайл сверен по
            // sha256 с подписанным индексом, но дельты в формате ничем не
            // ограничены, и накопленная координата в кривом-но-подписанном
            // тайле уронила бы приложение прямо в поездке.
            cls = UInt8(truncatingIfNeeded: line.kind.hashValue)
            count = Int32(truncatingIfNeeded: line.points.count)
            ax = Int32(truncatingIfNeeded: Int(first.latitude * RoadTiles.scale))
            ay = Int32(truncatingIfNeeded: Int(first.longitude * RoadTiles.scale))
            bx = Int32(truncatingIfNeeded: Int(last.latitude * RoadTiles.scale))
            by = Int32(truncatingIfNeeded: Int(last.longitude * RoadTiles.scale))
        }
    }

    /// Собрать индекс. Дорога на границе лежит в обоих тайлах целиком
    /// (так дешевле серверу и клиенту) — дубли схлопываются здесь, иначе
    /// граница съедала бы бюджет линий дважды.
    static func build(_ tileLines: [[RoadLine]]) -> TileRoadNetwork {
        var lines: [RoadLine] = []
        var grid: [Int: [Int32]] = [:]
        var seen = Set<LineKey>()
        // Окрестность 3×3 над Ташкентом — это больше ста тысяч линий, и на
        // каждую строился строковый ключ длиной под полсотни символов, то есть
        // отдельная аллокация в куче. Всплеск доходил до четырнадцати
        // мегабайт — ради схлопывания четырёх сотен дублей. Тот же урок в
        // проекте уже выучен: ключ ячейки в CameraMapContent пакуется в целое,
        // а не собирается интерполяцией.
        seen.reserveCapacity(tileLines.reduce(0) { $0 + $1.count })

        for tile in tileLines {
            for line in tile {
                guard let first = line.points.first, let last = line.points.last else { continue }
                let key = LineKey(line: line, first: first, last: last)
                guard seen.insert(key).inserted else { continue }

                let index = Int32(lines.count)
                var cells = Set<Int>()
                var previous: CLLocationCoordinate2D?
                for point in line.points {
                    cells.insert(cellKey(lat: point.latitude, lon: point.longitude))
                    // Длинные прямые перегоны: отмечаем и промежуточные ячейки,
                    // иначе трасса «пропадает» между своими редкими точками.
                    if let from = previous {
                        let steps = Int(max(abs(point.latitude - from.latitude),
                                            abs(point.longitude - from.longitude)) / 0.005)
                        if steps > 1 {
                            for step in 1..<steps {
                                let f = Double(step) / Double(steps)
                                cells.insert(cellKey(
                                    lat: from.latitude + (point.latitude - from.latitude) * f,
                                    lon: from.longitude + (point.longitude - from.longitude) * f))
                            }
                        }
                    }
                    previous = point
                }
                lines.append(line)
                for cell in cells { grid[cell, default: []].append(index) }
            }
        }
        return TileRoadNetwork(lines: lines, grid: grid)
    }

    func roads(near coordinate: CLLocationCoordinate2D,
               radius: CLLocationDistance) -> [RoadLine] {
        let span = max(1, Int((radius / 1100).rounded(.up)))
        let centerLat = Int((coordinate.latitude + 90) * 100)
        let centerLon = Int((coordinate.longitude + 180) * 100)

        var candidates = Set<Int32>()
        for latCell in (centerLat - span)...(centerLat + span) {
            for lonCell in (centerLon - span)...(centerLon + span) {
                if let found = grid[latCell * 40_000 + lonCell] {
                    candidates.formUnion(found)
                }
            }
        }
        guard !candidates.isEmpty else { return [] }

        let metersPerLon = 111_320.0 * cos(coordinate.latitude * .pi / 180)
        func distance(_ point: CLLocationCoordinate2D) -> Double {
            hypot((point.latitude - coordinate.latitude) * 111_320.0,
                  (point.longitude - coordinate.longitude) * metersPerLon)
        }
        return candidates.compactMap { index -> RoadLine? in
            let line = lines[Int(index)]
            // Точки за радиусом отбрасываем, но линию не рвём: берём кусок от
            // первой до последней попавшей — иначе дорога рассыпалась бы на
            // обрывки там, где она просто длинная.
            guard let first = line.points.firstIndex(where: { distance($0) <= radius }),
                  let last = line.points.lastIndex(where: { distance($0) <= radius }),
                  last > first else { return nil }
            var trimmed = line
            trimmed.points = Array(line.points[first...last])
            return trimmed
        }
    }
}
