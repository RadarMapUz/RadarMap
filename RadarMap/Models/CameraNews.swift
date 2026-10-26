//
//  CameraNews.swift
//  RadarMap
//
//  «Новые камеры на ваших дорогах» (31E, п. 4): после обновления базы
//  сравнить набор камер со старым и назвать те новые, что стоят там, где
//  водитель ездил за последние два месяца.
//
//  Две вещи на телефоне, обе маленькие:
//    * `RoadCells` — память «где я езжу»: клетки 150 м с днём последнего
//      проезда, 60 дней. Треки живут неделю, а «моя дорога» — дольше; клетка
//      в разы грубее трека и не уходит никуда.
//    * id камер, которые телефон уже видел, и короткий список новостей
//      {id, когда нашли}. Больше ничего: ни координат, ни названий — их даёт
//      сама база по id.
//
//  Первый запуск ничего «новым» не называет: прежнего набора нет, и вся
//  база оказалась бы новостью. Пачка новых id больше `cameraNewsMaxBatch` —
//  пересборка базы с новыми номерами, а не новые камеры: тоже молчим.
//
//  Чистая логика — CameraNewsTests.
//

import Foundation
import CoreLocation

/// Память своих дорог: клетка → день последнего проезда (дни от 1970).
nonisolated struct RoadCells: Codable, Equatable, Sendable {
    private(set) var cells: [Int64: Int] = [:]

    var isEmpty: Bool { cells.isEmpty }
    var count: Int { cells.count }

    static func dayNumber(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// Добавить трек: клетки вдоль отрезков с шагом в полклетки, иначе
    /// прямая улица с точками раз в 300 м оставила бы дыры.
    mutating func add(_ points: [(lat: Double, lon: Double)], on date: Date,
                      cellMeters: CLLocationDistance = AppConfig.roadCellMeters) {
        guard let first = points.first else { return }
        let day = Self.dayNumber(date)
        func mark(_ lat: Double, _ lon: Double) {
            let key = GridCell.key(lat: lat, lon: lon, meters: cellMeters)
            cells[key] = max(cells[key] ?? day, day)
        }
        mark(first.lat, first.lon)
        for index in points.indices.dropFirst() {
            let a = points[index - 1], b = points[index]
            let steps = max(1, Int((GeoMath.fastDistance(a.lat, a.lon, b.lat, b.lon)
                                    / (cellMeters * 0.5)).rounded(.up)))
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                mark(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t)
            }
        }
    }

    /// Забыть клетки старше `keepDays`.
    mutating func prune(now: Date, keepDays: Int = AppConfig.roadMemoryDays) {
        let horizon = Self.dayNumber(now) - keepDays
        cells = cells.filter { $0.value >= horizon }
    }

    /// Точка рядом со своей дорогой: её клетка или соседняя, проезд не
    /// старше `withinDays`.
    func covers(lat: Double, lon: Double, now: Date, withinDays: Int = AppConfig.roadMemoryDays,
                cellMeters: CLLocationDistance = AppConfig.roadCellMeters) -> Bool {
        let horizon = Self.dayNumber(now) - withinDays
        let key = GridCell.key(lat: lat, lon: lon, meters: cellMeters)
        for dy in -1...1 {
            for dx in -1...1 {
                if let day = cells[GridCell.neighbor(key, dy: Int64(dy), dx: Int64(dx))], day >= horizon {
                    return true
                }
            }
        }
        return false
    }

    // Codable — парами чисел: словарь с ключом Int64 JSONEncoder пишет
    // плоским массивом [k, v, k, v], читать такое глазами невозможно.
    private enum CodingKeys: String, CodingKey { case cells }
    init() {}
    init(from decoder: Decoder) throws {
        let pairs = try decoder.container(keyedBy: CodingKeys.self).decode([[Int64]].self, forKey: .cells)
        for pair in pairs where pair.count == 2 { cells[pair[0]] = Int(pair[1]) }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cells.sorted { $0.key < $1.key }.map { [$0.key, Int64($0.value)] }, forKey: .cells)
    }
}

nonisolated enum CameraNews {

    /// Новость: какая камера и когда телефон о ней узнал.
    struct Item: Codable, Equatable, Identifiable, Sendable {
        let id: Int
        let found: Date
    }

    /// Камера базы для сравнения: id и место.
    struct Point: Equatable, Sendable {
        let id: Int
        let lat: Double
        let lon: Double
    }

    struct Update: Equatable, Sendable {
        /// Что теперь считать «виденным».
        let known: [Int]
        /// Новые камеры на своих дорогах — добавить к новостям.
        let found: [Item]
    }

    /// Сравнить базу с прежним набором. nil — сравнивать нечего (база пуста).
    static func update(known: [Int]?, current: [Point], roads: RoadCells, now: Date,
                       maxBatch: Int = AppConfig.cameraNewsMaxBatch) -> Update? {
        guard !current.isEmpty else { return nil }
        let ids = current.map(\.id).sorted()
        guard let known else { return Update(known: ids, found: []) }
        let seen = Set(known)
        let fresh = current.filter { !seen.contains($0.id) }
        guard !fresh.isEmpty else {
            // Набор мог и сократиться (камеры сняты) — помним нынешний.
            return ids == known ? nil : Update(known: ids, found: [])
        }
        guard fresh.count <= maxBatch else { return Update(known: ids, found: []) }
        let found = fresh
            .filter { roads.covers(lat: $0.lat, lon: $0.lon, now: now) }
            .map { Item(id: $0.id, found: now) }
        return Update(known: ids, found: found)
    }

    /// Новости к показу: моложе `days` и камера ещё есть в базе.
    static func visible(_ items: [Item], existing: Set<Int>, now: Date,
                        days: Int = AppConfig.cameraNewsShowDays) -> [Item] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        var seen = Set<Int>()
        return items
            .filter { $0.found >= since && existing.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { $0.found > $1.found }
    }
}
