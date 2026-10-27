//
//  TrafficLines.swift
//  RadarMap
//
//  Пробки на карте — линиями улиц, а не кусками рёбер (33H, владелец 27.10:
//  «у них с указателями, у нас линия — непонятно, что это, и везде
//  по-разному»).
//
//  now.json несёт рёбра OSM по одному (u→v, 10–100 м). Нарисованные
//  поштучно, они дают «пунктир»: круглый конец каждого отрезка лежит на
//  соседнем, полупрозрачные концы темнеют бусинами, а одиночное короткое
//  ребро другого уровня красит улицу «зеброй». Здесь рёбра одного
//  направления сшиваются в цепочки, уровень сглаживается, и цепочка режется
//  на линии одного уровня и одного источника — одна полилиния на участок.
//
//  Где сшивать — на телефоне, при разборе нового now.json (раз в 2 минуты,
//  вне главного потока): формат v1 не меняется, старые сборки читают его как
//  раньше, сервер не тратит ни байта, а правило сшивки живёт рядом со стилем,
//  который его рисует, и проверяется тестами без сервера.
//
//  Правила.
//  • Продолжение ребра e — ребро f из конца e (не разворот назад) с
//    поворотом не круче `trafficStitchMaxTurnDegrees`; из нескольких —
//    самое прямое, и только если e тоже самое прямое из входящих в f
//    (взаимный выбор: на перекрёстке улица идёт прямо, а не сворачивает).
//  • Уровень показа: 1 свободно, 2 медленно, 3 пробка, 4 стоят — пробка
//    медленнее `trafficStandstillKmh` (сервер шлёт три уровня, четвёртый —
//    из скорости, без смены формата).
//  • Сглаживание: участок одного уровня короче `trafficSmoothMeters` между
//    двумя участками одного и того же другого уровня берёт их уровень; то же
//    для источника. Концы цепочки не трогаются — там соседа нет.
//  • Толщина — одна на цепочку (класс дороги по скорости графа, взвешенной
//    по длине): у соседних кусков одной улицы толщина не прыгает.
//
//  Чистая логика, покрыта TrafficLinesTests; бюджет — PerformanceBudgetTests.
//

import CoreLocation
import Foundation

nonisolated enum TrafficLines {

    /// Класс дороги для толщины: 0 — магистраль, 1 — улица, 2 — второстепенная.
    typealias Tier = Int

    struct Line: Equatable, Sendable {
        let coordinates: [CLLocationCoordinate2D]
        /// 1 свободно, 2 медленно, 3 пробка, 4 стоят.
        let level: Int
        let source: TrafficEdge.Source
        let tier: Tier
        /// Длина, метры.
        let length: Double
        /// Скорость, взвешенная по длине рёбер, км/ч; скорость графа — так же.
        let kmh: Double
        let modelKmh: Double

        static func == (l: Line, r: Line) -> Bool {
            l.level == r.level && l.source == r.source && l.tier == r.tier && l.length == r.length
                && l.kmh == r.kmh && l.modelKmh == r.modelKmh && l.coordinates.count == r.coordinates.count
                && zip(l.coordinates, r.coordinates).allSatisfy {
                    $0.latitude == $1.latitude && $0.longitude == $1.longitude
                }
        }
    }

    /// Уровень показа ребра (см. шапку).
    static func displayLevel(_ edge: TrafficEdge) -> Int {
        edge.level >= 3 && edge.kmh < AppConfig.trafficStandstillKmh ? 4 : min(3, max(1, edge.level))
    }

    /// Класс дороги по скорости графа (car_radarmap.lua: primary 65,
    /// secondary 55, tertiary 40, улицы 25 — до срезки по maxspeed):
    /// магистраль от `trafficMajorModelKmh`, улица от `trafficStreetModelKmh`,
    /// остальное — второстепенная. Посредник, пока now.json не несёт класс.
    static func tier(modelKmh: Double) -> Tier {
        if modelKmh >= AppConfig.trafficMajorModelKmh { return 0 }
        if modelKmh >= AppConfig.trafficStreetModelKmh { return 1 }
        return 2
    }

    /// Сшивка вне главного потока: тысячи рёбер по городу раз в 2 минуты.
    @concurrent
    static func build(_ edges: [TrafficEdge]) async -> [Line] {
        lines(from: edges)
    }

    // MARK: - Сшивка

    static func lines(from edges: [TrafficEdge]) -> [Line] {
        let count = edges.count
        guard count > 0 else { return [] }
        return edges.withUnsafeBufferPointer { lines(from: $0) }
    }

    /// Сшивка на сырых указателях. В Debug каждый доступ к Array — проверка
    /// границ, удержание буфера и вызов функции; на город (40 тыс. рёбер)
    /// это ~100 мс при бюджете 30 (PerformanceBudgetTests). Указатели
    /// стандартной библиотеки встраиваются и без оптимизации.
    private static func lines(from buffer: UnsafeBufferPointer<TrafficEdge>) -> [Line] {
        let count = buffer.count
        guard let e = buffer.baseAddress else { return [] }
        // Плоскость с одним косинусом на набор (город — доли градуса): длина и
        // направление без тригонометрии на ребро, поворот — скалярным
        // произведением единичных векторов. Циклы — `while`, а не `for in`:
        // в Debug итератор диапазона — вызов на каждый шаг.
        let k = cos(e[0].a.latitude * .pi / 180) * 111_320
        let minDot = cos(AppConfig.trafficStitchMaxTurnDegrees * .pi / 180)

        let aNode = alloc(count, Int32(-1)), bNode = alloc(count, Int32(-1))
        let length = alloc(count, 0.0), ux = alloc(count, 0.0), uy = alloc(count, 0.0)
        let nextOut = alloc(count, Int32(-1)), outHead = alloc(count * 2, Int32(-1))
        let next = alloc(count, Int32(-1)), prev = alloc(count, Int32(-1))
        let nextDot = alloc(count, -2.0), prevDot = alloc(count, -2.0)
        let level = alloc(count, 0), source = alloc(count, 0)
        let visited = alloc(count, false)
        let chain = alloc(count, 0)
        let runs = alloc(count, Run(value: 0, from: 0, to: 0, meters: 0))
        // Узлы: ключ координаты → номер подряд, открытая адресация.
        var tableSize = 16
        while tableSize < count * 4 { tableSize <<= 1 }
        let mask = tableSize - 1
        let tableKeys = alloc(tableSize, Int64(0)), tableIDs = alloc(tableSize, Int32(-1))
        var nodeCount: Int32 = 0
        defer {
            aNode.deallocate(); bNode.deallocate(); length.deallocate(); ux.deallocate(); uy.deallocate()
            nextOut.deallocate(); outHead.deallocate(); next.deallocate(); prev.deallocate()
            nextDot.deallocate(); prevDot.deallocate(); level.deallocate(); source.deallocate()
            visited.deallocate(); chain.deallocate(); runs.deallocate()
            tableKeys.deallocate(); tableIDs.deallocate()
        }
        func node(_ key: Int64) -> Int32 {
            var slot = Int(truncatingIfNeeded: (UInt64(bitPattern: key) &* 0x9E37_79B9_7F4A_7C15) >> 20) & mask
            while true {
                let found = tableIDs[slot]
                if found < 0 {
                    tableKeys[slot] = key
                    tableIDs[slot] = nodeCount
                    nodeCount += 1
                    return nodeCount - 1
                }
                if tableKeys[slot] == key { return found }
                slot = (slot + 1) & mask
            }
        }

        // Узлы, длины, направления; повтор u→v и нулевое ребро — не линии.
        var index = 0
        while index < count {
            defer { index += 1 }
            let edge = e[index]
            let aKey = key(edge.a), bKey = key(edge.b)
            guard aKey != bKey else { continue }
            let a = node(aKey), b = node(bKey)
            var cursor = outHead[Int(a)]
            var duplicate = false
            while cursor >= 0 {
                if bNode[Int(cursor)] == b { duplicate = true; break }
                cursor = nextOut[Int(cursor)]
            }
            guard !duplicate else { continue }
            let dx = (edge.b.longitude - edge.a.longitude) * k
            let dy = (edge.b.latitude - edge.a.latitude) * 111_320
            let meters = (dx * dx + dy * dy).squareRoot()
            aNode[index] = a
            bNode[index] = b
            length[index] = meters
            ux[index] = meters > 0 ? dx / meters : 0
            uy[index] = meters > 0 ? dy / meters : 0
            nextOut[index] = outHead[Int(a)]
            outHead[Int(a)] = Int32(index)
            level[index] = displayLevel(edge)
            source[index] = edge.source.rawValue
        }

        // Самое прямое продолжение каждого ребра (наибольшее скалярное
        // произведение направлений, не круче порога, не разворот назад).
        index = 0
        while index < count {
            defer { index += 1 }
            guard aNode[index] >= 0 else { continue }
            var cursor = outHead[Int(bNode[index])]
            while cursor >= 0 {
                let j = Int(cursor)
                cursor = nextOut[j]
                if j == index || bNode[j] == aNode[index] { continue }
                let dot = ux[index] * ux[j] + uy[index] * uy[j]
                if dot >= minDot, dot > nextDot[index] {
                    next[index] = Int32(j)
                    nextDot[index] = dot
                }
            }
        }
        // Взаимность: f принимает того, кто входит в него прямее всех.
        index = 0
        while index < count {
            let j = Int(next[index])
            if j >= 0, nextDot[index] > prevDot[j] {
                prev[j] = Int32(index)
                prevDot[j] = nextDot[index]
            }
            index += 1
        }
        index = 0
        while index < count {
            let j = Int(next[index])
            if j >= 0, prev[j] != Int32(index) { next[index] = -1 }
            index += 1
        }
        index = 0
        while index < count {
            let i = Int(prev[index])
            if i >= 0, next[i] != Int32(index) { prev[index] = -1 }
            index += 1
        }

        // Цепочки: сначала от голов, затем замкнутые кольца (круговое движение).
        var out: [Line] = []
        out.reserveCapacity(count / 4)
        let lengths = UnsafePointer(length)
        func walk(from start: Int) {
            var size = 0
            var cursor = start
            while cursor >= 0, !visited[cursor] {
                visited[cursor] = true
                chain[size] = cursor
                size += 1
                cursor = Int(next[cursor])
            }
            guard size > 0 else { return }
            if size >= 3 {
                smooth(level, chain: chain, size: size, lengths: lengths, runs: runs)
                smooth(source, chain: chain, size: size, lengths: lengths, runs: runs)
            }
            // Класс — один на цепочку: скорость графа, взвешенная по длине.
            var weighted = 0.0, total = 0.0
            var position = 0
            while position < size {
                let edge = chain[position]
                weighted += e[edge].modelKmh * length[edge]
                total += length[edge]
                position += 1
            }
            let tier = tier(modelKmh: total > 0 ? weighted / total : 0)
            // Разрез по смене (уровень, источник).
            var from = 0
            while from < size {
                let value = level[chain[from]], origin = source[chain[from]]
                var to = from
                while to + 1 < size, level[chain[to + 1]] == value, source[chain[to + 1]] == origin { to += 1 }
                var meters = 0.0, kmh = 0.0, model = 0.0
                let coordinates = [CLLocationCoordinate2D](unsafeUninitializedCapacity: to - from + 2) { out, filled in
                    out[0] = e[chain[from]].a
                    var p = from
                    while p <= to {
                        let edge = chain[p]
                        let piece = length[edge]
                        out[p - from + 1] = e[edge].b
                        meters += piece
                        kmh += e[edge].kmh * piece
                        model += e[edge].modelKmh * piece
                        p += 1
                    }
                    filled = to - from + 2
                }
                out.append(Line(coordinates: coordinates, level: value,
                                source: TrafficEdge.Source(rawValue: origin) ?? .drivers, tier: tier,
                                length: meters, kmh: meters > 0 ? kmh / meters : 0,
                                modelKmh: meters > 0 ? model / meters : 0))
                from = to + 1
            }
        }
        index = 0
        while index < count {
            if aNode[index] >= 0, prev[index] < 0 { walk(from: index) }
            index += 1
        }
        index = 0
        while index < count {
            if aNode[index] >= 0, !visited[index] { walk(from: index) }
            index += 1
        }
        return out
    }

    private struct Run {
        var value: Int
        var from: Int
        var to: Int
        var meters: Double
    }

    private static func alloc<T>(_ count: Int, _ value: T) -> UnsafeMutablePointer<T> {
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: max(1, count))
        pointer.initialize(repeating: value, count: max(1, count))
        return pointer
    }

    /// Короткий участок одного значения между двумя участками одного и того
    /// же другого значения берёт значение соседей (пока есть что менять).
    /// Проход через один: соседний участок только что сменил значение, и
    /// судить о нём по старой разметке нельзя — это сделает следующий проход.
    static func smooth(_ values: inout [Int], lengths: [Double]) {
        guard !values.isEmpty else { return }
        let count = values.count
        let chain = alloc(count, 0), runs = alloc(count, Run(value: 0, from: 0, to: 0, meters: 0))
        defer { chain.deallocate(); runs.deallocate() }
        for i in 0..<count { chain[i] = i }
        values.withUnsafeMutableBufferPointer { v in
            lengths.withUnsafeBufferPointer { l in
                guard let vb = v.baseAddress, let lb = l.baseAddress else { return }
                smooth(vb, chain: chain, size: count, lengths: lb, runs: runs)
            }
        }
    }

    /// Сглаживание значений рёбер цепочки на месте (номера рёбер — `chain`).
    private static func smooth(_ values: UnsafeMutablePointer<Int>, chain: UnsafeMutablePointer<Int>, size: Int,
                               lengths: UnsafePointer<Double>, runs: UnsafeMutablePointer<Run>) {
        let limit = AppConfig.trafficSmoothMeters
        // Без смены значения по цепочке сглаживать нечего — частый случай.
        let first = values[chain[0]]
        var position = 1
        while position < size, values[chain[position]] == first { position += 1 }
        guard position < size else { return }
        for _ in 0..<4 {
            var count = 0
            position = 0
            while position < size {
                let value = values[chain[position]], meters = lengths[chain[position]]
                if count > 0, runs[count - 1].value == value {
                    runs[count - 1].to = position
                    runs[count - 1].meters += meters
                } else {
                    runs[count] = Run(value: value, from: position, to: position, meters: meters)
                    count += 1
                }
                position += 1
            }
            guard count >= 3 else { return }
            var changed = false
            var r = 1
            while r < count - 1 {
                if runs[r].meters < limit, runs[r - 1].value == runs[r + 1].value {
                    for position in runs[r].from...runs[r].to { values[chain[position]] = runs[r - 1].value }
                    changed = true
                    r += 2
                } else {
                    r += 1
                }
            }
            guard changed else { return }
        }
    }

    private static func key(_ c: CLLocationCoordinate2D) -> Int64 {
        let lat = Int64((c.latitude * 100_000).rounded())
        let lon = Int64((c.longitude * 100_000).rounded())
        return lat << 32 | (lon & 0xFFFF_FFFF)
    }
}
