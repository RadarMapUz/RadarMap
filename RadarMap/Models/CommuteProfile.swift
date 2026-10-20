//
//  CommuteProfile.swift
//  RadarMap
//
//  Профиль дороги дом↔работа по участкам — память для «призрака»
//  (docs/plan_full_2026-10-19.md, этап 8): «приедете в 9:12, на 4 мин дольше
//  обычного» без построенного маршрута, с пересчётом на каждом участке.
//
//  Почему отдельный профиль, а не история поездок: в записи истории трек без
//  времени (до 400 точек Дугласа—Пекера, и как раз пробку на прямой упрощение
//  выкидывает), живёт неделю, а записей не больше 50. Поэтому каждая поездка
//  дом↔работа сворачивается при финише в одну строку «секунды по участкам
//  ~200 м» на линии своего варианта пути, и это всё, что хранится.
//
//  Правила, которые здесь закреплены:
//    * не гонка — время участка не меньше проезда на лимите: призрак никогда
//      не превышает, и лучшее время здесь не хранится вовсе;
//    * стоянка (склейка, магазин по дороге) — пропуск участка, не пробка;
//    * без времени у точки — пропуск, а не догадка;
//    * дом, работа и распорядок — самые личные данные приложения: файл только
//      на телефоне, вне резервной копии (CommuteProfileStore).
//
//  Чистая логика без часов и диска — CommuteProfileTests.
//

import CoreLocation
import Foundation
import simd

nonisolated enum CommuteProfile {

    /// Точка сырого трека поездки со временем (секунды Unix; NaN — время
    /// неизвестно: первая нога склейки после перезапуска, слепок после вылета).
    struct TimedPoint: Equatable, Sendable {
        let lat: Double
        let lon: Double
        let t: Double
    }

    /// Строка: одна поездка, секунды по участкам варианта.
    struct Row: Codable, Equatable, Sendable {
        let tripID: Double
        let departure: Date
        let weekend: Bool
        /// Минута суток прибытия.
        let arrivalMinute: Int16
        /// По участкам; `noData` — участок не измерен (стоянка, нет времени,
        /// сошли с линии).
        let seconds: [UInt16]

        static let noData = UInt16.max

        var validCount: Int { seconds.lazy.filter { $0 != Self.noData }.count }
    }

    /// Один из путей направления (обычно один-два: через центр, по кольцу).
    struct Variant: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        /// lat, lon × 1e5 парами.
        var line: [Int32]
        /// Границы участков по линии, метры от начала; последняя — длина линии.
        var ends: [Float]
        /// Лимит на середине участка, км/ч; 0 — неизвестен.
        var limitKmh: [UInt8]
        /// Новые первыми.
        var rows: [Row]
        var lastUsed: Date

        var coordinates: [CLLocationCoordinate2D] {
            stride(from: 0, to: line.count - 1, by: 2).map {
                CLLocationCoordinate2D(latitude: Double(line[$0]) / 1e5,
                                       longitude: Double(line[$0 + 1]) / 1e5)
            }
        }
        var length: Double { Double(ends.last ?? 0) }
    }

    /// Все варианты обоих направлений.
    struct Book: Codable, Equatable, Sendable {
        var version = 1
        var toWork: [Variant] = []
        var toHome: [Variant] = []

        subscript(direction: Commute.Direction) -> [Variant] {
            get { direction == .toWork ? toWork : toHome }
            set { if direction == .toWork { toWork = newValue } else { toHome = newValue } }
        }

        var isEmpty: Bool { toWork.isEmpty && toHome.isEmpty }
    }

    // MARK: - Свёртка поездки

    /// Свернуть поездку в профиль: найти её вариант (или завести новый) и
    /// положить строку по участкам. Строка без половины измеренных участков
    /// не кладётся — вариант при этом всё равно помнится.
    static func fold(_ track: [TimedPoint], into book: Book,
                     direction: Commute.Direction, tripID: Double,
                     departure: Date, arrival: Date,
                     stops: [ClosedRange<Double>] = [],
                     calendar: Calendar = .current,
                     limitAt: ((CLLocationCoordinate2D) -> Int?)? = nil,
                     now: Date) -> Book {
        let points = track.filter { $0.lat.isFinite && $0.lon.isFinite }
        guard points.count >= 2 else { return book }
        let frame = Frame(latitude: points[0].lat)
        let tripLine = points.map { frame.xy($0.lat, $0.lon) }
        guard Geometry.length(tripLine) >= AppConfig.commuteProfileMinTripMeters else { return book }

        var book = book
        var variants = book[direction]
        let index: Int
        if let found = bestVariant(for: tripLine, among: variants, frame: frame) {
            index = found
        } else {
            variants.append(makeVariant(from: tripLine, frame: frame, limitAt: limitAt, now: now))
            index = variants.count - 1
        }

        var variant = variants[index]
        variant.lastUsed = now
        // Строки — ПО ЛИНИИ варианта, не по своей: так строки разных дней
        // складываются участок к участку.
        let line = variant.coordinates.map { frame.xy($0.latitude, $0.longitude) }
        let seconds = rowSeconds(points: points, tripLine: tripLine, variantLine: line,
                                 ends: variant.ends.map(Double.init),
                                 limits: variant.limitKmh, stops: stops)
        let row = Row(tripID: tripID, departure: departure,
                      weekend: UzHolidays.isDayOff(departure, calendar: calendar),
                      arrivalMinute: Int16(minuteOfDay(arrival, calendar: calendar)),
                      seconds: seconds)
        if Double(row.validCount) >= Double(seconds.count) * AppConfig.commuteProfileMinValidShare {
            // Склейка финиширует ту же поездку второй раз — строка заменяется.
            variant.rows.removeAll { $0.tripID == tripID }
            variant.rows.insert(row, at: 0)
        }
        let oldest = now.addingTimeInterval(-AppConfig.commuteProfileKeepDays * 86_400)
        variant.rows = Array(variant.rows.filter { $0.departure >= oldest }
            .prefix(AppConfig.commuteProfileMaxRows))
        variants[index] = variant

        // Вариантов немного: лишний — давно не езженный.
        if variants.count > AppConfig.commuteProfileMaxVariants {
            let victim = variants.indices.filter { $0 != index }
                .min { variants[$0].lastUsed < variants[$1].lastUsed }
            if let victim { variants.remove(at: victim) }
        }
        book[direction] = variants
        return book
    }

    // MARK: - Вариант

    /// Тот же путь — покрытие в обе стороны: поездка лежит на варианте и
    /// вариант на поездке (короткий заезд не делает «тот же путь» другим, а
    /// путь через другой мост — делает).
    static func bestVariant(for tripLine: [SIMD2<Double>], among variants: [Variant],
                            frame: Frame) -> Int? {
        var best: (index: Int, score: Double)?
        for (index, variant) in variants.enumerated() {
            let line = variant.coordinates.map { frame.xy($0.latitude, $0.longitude) }
            let there = Geometry.coverage(of: tripLine, by: line)
            guard there >= AppConfig.commuteProfileSameRouteShare else { continue }
            let back = Geometry.coverage(of: line, by: tripLine)
            guard back >= AppConfig.commuteProfileSameRouteShare else { continue }
            let score = there + back
            if best.map({ score > $0.score }) ?? true { best = (index, score) }
        }
        return best?.index
    }

    static func makeVariant(from tripLine: [SIMD2<Double>], frame: Frame,
                            limitAt: ((CLLocationCoordinate2D) -> Int?)?, now: Date) -> Variant {
        let simplified = Geometry.simplify(tripLine, tolerance: AppConfig.commuteProfileLineTolerance,
                                           maxPoints: AppConfig.commuteProfileMaxVertices)
        let ends = boundaries(length: Geometry.length(simplified))
        var packed: [Int32] = []
        packed.reserveCapacity(simplified.count * 2)
        for p in simplified {
            let c = frame.coordinate(p)
            packed.append(Int32((c.latitude * 1e5).rounded()))
            packed.append(Int32((c.longitude * 1e5).rounded()))
        }
        var limits: [UInt8] = []
        var start = 0.0
        for end in ends {
            let mid = Geometry.point(on: simplified, at: (start + end) / 2)
            let limit = limitAt?(frame.coordinate(mid)) ?? 0
            limits.append(UInt8(clamping: limit))
            start = end
        }
        return Variant(id: UUID(), line: packed, ends: ends.map(Float.init),
                       limitKmh: limits, rows: [], lastUsed: now)
    }

    /// Границы участков по `commuteProfileSegmentMeters`; хвост короче
    /// половины участка сливается с предыдущим.
    static func boundaries(length: Double,
                           step: Double = AppConfig.commuteProfileSegmentMeters) -> [Double] {
        guard length > 0 else { return [] }
        var ends: [Double] = []
        var at = step
        while at < length {
            ends.append(at)
            at += step
        }
        if let last = ends.last, length - last < step / 2 { ends.removeLast() }
        ends.append(length)
        return ends
    }

    // MARK: - Строка по участкам

    /// Секунды по участкам линии варианта. Время пересечения границы —
    /// интерполяция между соседними точками, обе близко к линии и не дальше
    /// `commuteProfileMaxGapSeconds` друг от друга по времени.
    static func rowSeconds(points: [TimedPoint], tripLine: [SIMD2<Double>],
                           variantLine: [SIMD2<Double>], ends: [Double],
                           limits: [UInt8], stops: [ClosedRange<Double>]) -> [UInt16] {
        guard !ends.isEmpty, variantLine.count >= 2 else { return [] }
        let near = AppConfig.commuteProfileNearMeters
        let projected = Geometry.projectMonotonic(tripLine, onto: variantLine)
        let length = ends.last ?? 0

        func crossing(_ boundary: Double) -> Double? {
            // Старт и финиш линии — первая/последняя точка у самого края.
            if boundary <= 0 {
                guard let first = projected.indices.first(where: { points[$0].t.isFinite }),
                      projected[first].along <= near, projected[first].offset <= near else { return nil }
                return points[first].t
            }
            for i in 1..<projected.count {
                let a = projected[i - 1], b = projected[i]
                guard a.along < boundary, b.along >= boundary else { continue }
                let ta = points[i - 1].t, tb = points[i].t
                guard ta.isFinite, tb.isFinite, tb > ta,
                      tb - ta <= AppConfig.commuteProfileMaxGapSeconds,
                      a.offset <= near, b.offset <= near, b.along > a.along else { return nil }
                return ta + (boundary - a.along) / (b.along - a.along) * (tb - ta)
            }
            if boundary >= length,
               let last = projected.indices.last(where: { points[$0].t.isFinite }),
               projected[last].along >= length - near, projected[last].offset <= near {
                return points[last].t
            }
            return nil
        }

        let times = ([0] + ends).map(crossing)
        var seconds: [UInt16] = []
        seconds.reserveCapacity(ends.count)
        var start = 0.0
        for k in ends.indices {
            let segment = ends[k] - start
            defer { start = ends[k] }
            guard let t0 = times[k], let t1 = times[k + 1], t1 > t0 else {
                seconds.append(Row.noData)
                continue
            }
            // Стоянка внутри участка — не дорога (магазин по пути не пробка).
            if stops.contains(where: { $0.lowerBound < t1 && $0.upperBound > t0 }) {
                seconds.append(Row.noData)
                continue
            }
            var value = t1 - t0
            // Не гонка: призрак не едет быстрее лимита (и шум GPS не делает
            // из пробки рекорд).
            let limit = k < limits.count ? Double(limits[k]) : 0
            if limit > 0 { value = max(value, segment * 3.6 / limit) }
            seconds.append(UInt16(clamping: Int(value.rounded())).clampedBelowNoData)
        }
        return seconds
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    // MARK: - Геометрия в метрах

    /// Плоская проекция вокруг широты поездки: на 30 км ошибка — доли
    /// процента, и считать на сфере каждую из тысяч точек незачем.
    struct Frame: Sendable {
        let kx: Double
        /// Те же 111 320 м на градус, что и вся остальная геометрия
        /// приложения (GeoMath): одна и та же точка не должна оказаться на
        /// разном расстоянии от линии в профиле и в остальном коде.
        let ky = 111_320.0

        init(latitude: Double) {
            kx = 111_320.0 * cos(latitude * .pi / 180)
        }

        func xy(_ lat: Double, _ lon: Double) -> SIMD2<Double> { SIMD2(lon * kx, lat * ky) }
        func coordinate(_ p: SIMD2<Double>) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: p.y / ky, longitude: p.x / kx)
        }
    }

    enum Geometry {
        static func length(_ line: [SIMD2<Double>]) -> Double {
            zip(line, line.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
        }

        /// Точка на линии на расстоянии `along` от начала.
        static func point(on line: [SIMD2<Double>], at along: Double) -> SIMD2<Double> {
            guard var previous = line.first else { return .zero }
            var walked = 0.0
            for next in line.dropFirst() {
                let step = simd_distance(previous, next)
                if walked + step >= along, step > 0 {
                    return previous + (next - previous) * ((along - walked) / step)
                }
                walked += step
                previous = next
            }
            return previous
        }

        /// Доля точек `a` (через `commuteProfileSampleMeters`), лежащих ближе
        /// `commuteProfileNearMeters` к линии `b`.
        static func coverage(of a: [SIMD2<Double>], by b: [SIMD2<Double>]) -> Double {
            let total = length(a)
            guard total > 0, b.count >= 2 else { return 0 }
            let step = AppConfig.commuteProfileSampleMeters
            var near = 0, all = 0
            var at = 0.0
            while at <= total {
                let p = point(on: a, at: at)
                all += 1
                if distance(from: p, to: b) <= AppConfig.commuteProfileNearMeters { near += 1 }
                at += step
            }
            return all > 0 ? Double(near) / Double(all) : 0
        }

        static func distance(from p: SIMD2<Double>, to line: [SIMD2<Double>]) -> Double {
            var best = Double.infinity
            for (a, b) in zip(line, line.dropFirst()) {
                best = min(best, simd_distance(p, nearest(p, a, b).point))
            }
            return best
        }

        static func nearest(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>)
            -> (point: SIMD2<Double>, fraction: Double) {
            let ab = b - a
            let lengthSquared = simd_length_squared(ab)
            guard lengthSquared > 0 else { return (a, 0) }
            let f = max(0, min(1, simd_dot(p - a, ab) / lengthSquared))
            return (a + ab * f, f)
        }

        /// Проекция точек на линию: пройденное по линии не убывает (машина
        /// не едет назад по своей дороге — откат проекции на развязке был бы
        /// шумом), отклонение — до ближайшей точки линии.
        static func projectMonotonic(_ points: [SIMD2<Double>], onto line: [SIMD2<Double>])
            -> [(along: Double, offset: Double)] {
            var cumulative: [Double] = [0]
            for (a, b) in zip(line, line.dropFirst()) {
                cumulative.append(cumulative.last! + simd_distance(a, b))
            }
            var result: [(along: Double, offset: Double)] = []
            result.reserveCapacity(points.count)
            var floor = 0.0
            for p in points {
                var best = (along: 0.0, offset: Double.infinity)
                for i in 0..<(line.count - 1) {
                    let (q, f) = nearest(p, line[i], line[i + 1])
                    let offset = simd_distance(p, q)
                    // Чуть ближе, но далеко ПОЗАДИ уже пройденного — это та
                    // же дорога в обратную сторону (петля), не берём.
                    let along = cumulative[i] + f * (cumulative[i + 1] - cumulative[i])
                    if along + AppConfig.commuteProfileNearMeters < floor { continue }
                    if offset < best.offset { best = (along, offset) }
                }
                if best.offset.isInfinite { best = (floor, .infinity) }
                floor = max(floor, best.along)
                result.append((floor, best.offset))
            }
            return result
        }

        /// Дуглас—Пекер с потолком числа точек: допуск растёт, пока не влезет.
        static func simplify(_ line: [SIMD2<Double>], tolerance: Double, maxPoints: Int) -> [SIMD2<Double>] {
            guard line.count > 2 else { return line }
            var eps = tolerance
            var result = douglasPeucker(line, eps)
            while result.count > maxPoints {
                eps *= 1.5
                result = douglasPeucker(line, eps)
            }
            return result
        }

        private static func douglasPeucker(_ line: [SIMD2<Double>], _ eps: Double) -> [SIMD2<Double>] {
            var keep = [Bool](repeating: false, count: line.count)
            keep[0] = true
            keep[line.count - 1] = true
            var stack = [(0, line.count - 1)]
            while let (first, last) = stack.popLast() {
                guard last > first + 1 else { continue }
                var farthest = first, maxDistance = 0.0
                for i in (first + 1)..<last {
                    let d = simd_distance(line[i], nearest(line[i], line[first], line[last]).point)
                    if d > maxDistance { maxDistance = d; farthest = i }
                }
                if maxDistance > eps {
                    keep[farthest] = true
                    stack.append((first, farthest))
                    stack.append((farthest, last))
                }
            }
            return line.indices.filter { keep[$0] }.map { line[$0] }
        }
    }
}

private extension UInt16 {
    /// Измеренное значение не может совпасть с меткой «нет данных».
    nonisolated var clampedBelowNoData: UInt16 {
        self == CommuteProfile.Row.noData ? self - 1 : self
    }
}
