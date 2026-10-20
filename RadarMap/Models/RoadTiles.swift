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
        /// Тротуары. Своим набором по тому же закону, что вода и зелень: слой,
        /// невидимый на текущем охвате, не качается и не разбирается.
        case sidewalks = "t"
        /// Дома. Своим набором и по тому же закону, но повод здесь сильнее
        /// всех: их больше, чем всех остальных объектов схемы вместе.
        case houses = "h"
        /// Поверхность дороги: полотно, площадь перекрёстка, фаски подхода.
        ///
        /// Считается СБОРКОЙ раз в неделю, а не телефоном на каждый кадр.
        /// Штрихами реалистичную дорогу не нарисовать никакой толщиной: у
        /// штриха нет ни кромки, ни площади перекрёстка, ни расширения перед
        /// ним. Всё это — геометрия, одинаковая для всех и не зависящая от
        /// зума, и место ей в тайле.
        ///
        /// Только ближний охват: на охвате района полотно вырождается в линию,
        /// и возить туда контуры значит платить за то, чего не видно.
        case surface = "d"
        /// Названия населённых пунктов. Сервер считает их с самого перехода
        /// на формат 2, а приложение не забирало ни разу: случая в этом
        /// перечислении просто не завели. Весь набор — 0,7 МБ на страну и
        /// 0,2 КБ на тайл, и он единственное, что делает обзорный охват
        /// читаемым: без имён это сеть серых линий без ответа на «где я».
        case places = "n"
        /// Точечные объекты. Наборов ДВА: ближний посажен на детальную
        /// геометрию, дальний пересчитан по костяку района — там раздельные
        /// проезжие сведены в одну ось, и точка с детальной сети уехала бы от
        /// нарисованной линии на полширины проспекта.
        case points = "p"
        case pointsFar = "q"

        /// Очередь закачки: кого тянем первым, когда тайлов больше, чем
        /// соединений.
        ///
        /// Раньше очереди не было вовсе — все недостающие файлы уходили в сеть
        /// одним залпом (в центре Ташкента это до девяноста девяти запросов и
        /// 13,86 МБ), и первым приезжал тот, кому повезло. А снимок сети
        /// собирался только когда приедут ВСЕ, то есть до последнего дома
        /// экран оставался пустой землёй.
        ///
        /// Порядок отвечает на вопрос «без чего схемы нет»: костяк, улицы,
        /// крупные ориентиры, потом форма города, и в самом конце асфальт и
        /// застройка — они украшают то, что уже нарисовано.
        var loadRank: Int {
            switch self {
            case .far:       return 0
            case .streets:   return 1
            case .water:     return 2
            case .green:     return 3
            case .rail:      return 4
            case .blocks:    return 5
            case .pointsFar: return 6
            case .places:    return 7
            case .points:    return 8
            case .yards:     return 9
            case .surface:   return 10
            case .sidewalks: return 11
            case .houses:    return 12
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
        coverage(of: coordinate, tileDegrees: tileDegrees, steps: 1)
    }

    /// Сколько тайлов в стороне нужно, чтобы накрыть круг такого радиуса.
    ///
    /// Тайл 0,05° — это 5,5 км по широте и 4,2 км по долготе на широте
    /// Ташкента; считаем по УЗКОЙ стороне, иначе на востоке и западе от
    /// машины окажется незакрытая полоса.
    /// Потолок — четыре тайла в сторону, то есть окрестность 9×9.
    ///
    /// Это ±18,8 км на широте Ташкента: как раз обзорный охват целиком.
    /// Выше потолка растёт не польза, а число запросов: тайлов в окрестности
    /// (2n+1)², и шестой шаг стоил бы вдвое больше пятого ради полосы, до
    /// которой взгляд не доходит.
    static func steps(forRadius meters: Double, tileDegrees: Double,
                      latitude: Double, limit: Int = 4) -> Int {
        let metresPerLon = 111_320.0 * max(0.2, cos(latitude * .pi / 180))
        let side = tileDegrees * min(111_320.0, metresPerLon)
        guard side > 0 else { return 1 }
        return max(1, min(limit, Int(ceil(meters / side))))
    }

    /// Окрестность (2·steps+1)² тайлов, БЛИЖНИМИ КОЛЬЦАМИ ВПЕРЁД.
    ///
    /// Порядок здесь не для красоты: он же порядок закачки. Тайлы приезжают по
    /// одному, и первым обязан приехать тот, на котором стоит машина, а не
    /// тот, чей ключ оказался раньше в переборе. Пока порядок был построчным,
    /// первым качался левый верхний угол окрестности — то есть угол экрана.
    static func coverage(of coordinate: CLLocationCoordinate2D,
                         tileDegrees: Double, steps: Int) -> [String] {
        var keys: [String] = []
        keys.reserveCapacity((2 * steps + 1) * (2 * steps + 1))
        for ring in 0...max(0, steps) {
            for latStep in -ring...ring {
                for lonStep in -ring...ring {
                    guard max(abs(latStep), abs(lonStep)) == ring else { continue }
                    keys.append(tileKey(
                        latitude: coordinate.latitude + Double(latStep) * tileDegrees,
                        longitude: coordinate.longitude + Double(lonStep) * tileDegrees,
                        tileDegrees: tileDegrees))
                }
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

    /// Распаковка записей тайла. Формат дельт — контракт с сервером
    /// (server/test_build_roads.py), и разойтись с ним нельзя.
    private static func decodeEntries(_ data: Data,
                                      minimumCoordinates: Int = 2) -> [Entry]? {
        // Не JSON — тот же nil, что у чужой версии: тайл отклоняется целиком.
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
                  flat.count >= 2,
                  flat.count % 2 == 0 else { return nil }
            // Дорога из одной точки — не дрейф формата, а огрызок короче
            // метра: сервер выбрасывает нулевые дельты после квантования, и
            // от двух близких точек остаётся одна. Нарисовать её нельзя —
            // пропускаем запись, а не тайл: до 20.10 пять таких записей
            // отбрасывали 3 658 улиц центра Ташкента (шесть тайлов «_s»).
            guard flat.count >= minimumCoordinates * 2 else { continue }

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
        // Биты flags: 1 = одностороннее, 2 = мост, 4 = тоннель, 8 = кольцо,
        // 16–128 — число полос.
        //
        // Полосы приехали СТАРШИМИ БИТАМИ, а не пятым элементом записи, и это
        // не экономия. Разбор выше принимает записи длиной 3 или 4; пятый
        // элемент вернул бы nil на ВЕСЬ тайл, то есть установленная сборка
        // потеряла бы не дорогу, а регион. Старшие биты сборка, не знающая о
        // полосах, просто не видит: она читает флаги масками.
        return entries.map { entry in
            RoadLine(points: entry.points,
                     kind: roadClass(code: entry.code),
                     level: entry.flags & 2 != 0 ? 1 : (entry.flags & 4 != 0 ? -1 : 0),
                     isOneWay: entry.flags & 1 != 0 && entry.flags & 8 == 0,
                     isDetailed: true,
                     isRing: entry.flags & 8 != 0,
                     name: entry.name,
                     lanes: (entry.flags >> 4) & 0b1111)
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
            cls = line.kind.stableCode
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
