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

    /// Распаковать тайл. `nil` — формат не тот: sha уже сошёлся, значит это
    /// не порча по дороге, а дрейф формата, и правильный ответ — не рисовать
    /// ничего, а не рисовать наполовину разобранное.
    static func decodeTile(_ data: Data) -> [RoadLine]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["version"] as? Int == formatVersion,
              let rawRoads = root["roads"] as? [[Any]] else { return nil }

        var lines: [RoadLine] = []
        lines.reserveCapacity(rawRoads.count)
        for entry in rawRoads {
            guard entry.count == 3,
                  let code = (entry[0] as? NSNumber)?.intValue,
                  let flags = (entry[1] as? NSNumber)?.intValue,
                  let flat = entry[2] as? [NSNumber],
                  flat.count >= 4, flat.count % 2 == 0 else { return nil }

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
            // Биты flags: 1 = одностороннее, 2 = мост, 4 = тоннель.
            lines.append(RoadLine(points: points,
                                  kind: roadClass(code: code),
                                  level: flags & 2 != 0 ? 1 : (flags & 4 != 0 ? -1 : 0),
                                  isOneWay: flags & 1 != 0,
                                  isDetailed: true))
        }
        return lines
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

    /// Собрать индекс. Дорога на границе лежит в обоих тайлах целиком
    /// (так дешевле серверу и клиенту) — дубли схлопываются здесь, иначе
    /// граница съедала бы бюджет линий дважды.
    static func build(_ tileLines: [[RoadLine]]) -> TileRoadNetwork {
        var lines: [RoadLine] = []
        var grid: [Int: [Int32]] = [:]
        var seen = Set<String>()

        for tile in tileLines {
            for line in tile {
                guard let first = line.points.first, let last = line.points.last else { continue }
                let key = "\(line.kind):\(line.points.count):" +
                    "\(Int(first.latitude * RoadTiles.scale)):\(Int(first.longitude * RoadTiles.scale)):" +
                    "\(Int(last.latitude * RoadTiles.scale)):\(Int(last.longitude * RoadTiles.scale))"
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
