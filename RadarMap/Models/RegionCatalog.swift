//
//  RegionCatalog.swift
//  RadarMap
//
//  Каталог офлайн-регионов — подписанный `regions.json` с сервера
//  (server/publish_regions.sh, docs/plan_map_offline.md §2.7).
//
//  Регион — область целиком (14 штук, ~344 МБ на страну): два файла PMTiles,
//  наш MVT и основа OpenMapTiles. Где лежит точка, решают не полигоны, а
//  клетки z12 региона строками `[y, x_от, x_до]` — несколько килобайт на всю
//  страну, и «в какой области мой дом» считается без геометрии.
//
//  Чистая модель — покрыта RegionCatalogTests.
//

import CoreLocation
import Foundation

nonisolated struct RegionCatalog: Codable, Sendable, Equatable {

    struct File: Codable, Sendable, Equatable {
        let file: String
        let bytes: Int64
        let sha256: String
    }

    struct Region: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let name: [String: String]
        let bbox: [Double]
        let cells: Int
        let rows: [[Int]]
        let files: [String: File]

        /// Название на языке интерфейса (uz/ru), иначе любое.
        func title(language: String) -> String {
            name[language] ?? name["ru"] ?? name.values.first ?? id
        }

        var totalBytes: Int64 { files.values.reduce(0) { $0 + $1.bytes } }

        /// Лежит ли клетка z`cellZoom` в регионе.
        func contains(cellX: Int, cellY: Int) -> Bool {
            rows.contains { row in
                row.count == 3 && row[0] == cellY && row[1] <= cellX && cellX <= row[2]
            }
        }
    }

    let version: Int
    let cellZoom: Int
    let regions: [Region]

    /// Клетка точки на зуме каталога — как `cell_of` в build_regions.py.
    static func cell(of coordinate: CLLocationCoordinate2D, zoom: Int) -> (x: Int, y: Int) {
        let n = Double(1 << zoom)
        let lat = max(-85.0511, min(85.0511, coordinate.latitude)) * .pi / 180
        let x = Int(((coordinate.longitude + 180) / 360 * n).rounded(.down))
        let y = Int(((1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * n).rounded(.down))
        return (x, y)
    }

    /// Регион, в котором точка. nil — вне страны (там только онлайн).
    func region(containing coordinate: CLLocationCoordinate2D) -> Region? {
        let cell = Self.cell(of: coordinate, zoom: cellZoom)
        return regions.first { $0.contains(cellX: cell.x, cellY: cell.y) }
    }

    var totalBytes: Int64 { regions.reduce(0) { $0 + $1.totalBytes } }
}
