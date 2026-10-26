//
//  TrafficTime.swift
//  RadarMap
//
//  «Время в пробках» (31E, п. 1): сколько за период стояли и ползли, где и
//  когда больше всего — по СВОИМ трекам на телефоне.
//
//  Откуда берётся. На финише у поездки есть сырой трек (точка каждые 30 м)
//  со временем каждой точки. Отрезок между соседними точками медленнее
//  `jamSpeedKmh` — «ползём»: стоя на месте, точка не ставится, и всё стояние
//  ложится в отрезок, которым машина с места тронулась. Пробка — такие
//  отрезки подряд не короче `jamMinRunSeconds`: один красный свет пробкой не
//  считается.
//
//  Чего здесь нет — и это правила, а не упущения:
//    * стоянки склеенной поездки (TripStop: магазин, заправка) — не пробка,
//      отрезок, задевающий стоянку, рвёт счёт;
//    * отрезок длиннее `jamMaxSegmentSeconds` — разрыв (тоннель, GPS), не
//      пробка;
//    * пробки толпы с сервера в итоговое время не входят: это чужие данные о
//      дороге, а не наше время. Подсказкой они могли бы быть, но сумма в
//      «Итогах» — только своё.
//
//  Чистая логика без часов — TrafficTimeTests.
//

import Foundation
import CoreLocation

/// Одна пробка поездки: где (середина по времени), когда началась, сколько.
/// Координата с пятью знаками — метр точности, больше не нужно; лежит только
/// в записи поездки на телефоне, как и сам трек.
nonisolated struct TripJam: Codable, Equatable, Sendable {
    let lat: Double
    let lon: Double
    let at: Date
    let seconds: TimeInterval
}

nonisolated enum TrafficTime {

    /// Пробки поездки по сырому треку. `times` — секунды Unix каждой точки
    /// (NaN — неизвестно: склейка со старой записью), `stops` — стоянки.
    static func jams(track: [TrackPoint], times: [Double], stops: [ClosedRange<Date>],
                     slowKmh: Double = AppConfig.jamSpeedKmh,
                     minRun: TimeInterval = AppConfig.jamMinRunSeconds,
                     maxSegment: TimeInterval = AppConfig.jamMaxSegmentSeconds,
                     maxCount: Int = AppConfig.jamMaxPerTrip) -> [TripJam] {
        guard track.count >= 2, times.count == track.count else { return [] }
        var found: [TripJam] = []
        // Отрезки текущей пробки: начало, длительность, середина отрезка.
        var run: [(t0: Double, dt: Double, lat: Double, lon: Double)] = []

        func close() {
            defer { run.removeAll() }
            let total = run.reduce(0) { $0 + $1.dt }
            guard total >= minRun, let first = run.first else { return }
            // Место — отрезок, на котором прошла середина времени пробки:
            // точка, где стояли дольше всего, а не где в неё въехали.
            var acc = 0.0
            var mid = run[run.count - 1]
            for piece in run {
                acc += piece.dt
                if acc >= total / 2 { mid = piece; break }
            }
            found.append(TripJam(lat: (mid.lat * 100_000).rounded() / 100_000,
                                 lon: (mid.lon * 100_000).rounded() / 100_000,
                                 at: Date(timeIntervalSince1970: first.t0), seconds: total))
        }

        for index in 1..<track.count {
            let t0 = times[index - 1], t1 = times[index]
            guard t0.isFinite, t1.isFinite, t1 > t0 else { close(); continue }
            let dt = t1 - t0
            let from = Date(timeIntervalSince1970: t0), to = Date(timeIntervalSince1970: t1)
            // Стоянка-заезд — не пробка, и отрезок через неё рвёт пробку.
            if dt > maxSegment || stops.contains(where: { $0.lowerBound < to && from < $0.upperBound }) {
                close()
                continue
            }
            let a = track[index - 1], b = track[index]
            let meters = GeoMath.fastDistance(a.lat, a.lon, b.lat, b.lon)
            if meters / dt * 3.6 < slowKmh {
                run.append((t0, dt, (a.lat + b.lat) / 2, (a.lon + b.lon) / 2))
            } else {
                close()
            }
        }
        close()
        guard found.count > maxCount else { return found }
        // Потолок — длинные остаются, порядок — по времени.
        return found.sorted { $0.seconds > $1.seconds }.prefix(maxCount).sorted { $0.at < $1.at }
    }

    // MARK: - Период

    /// Место, где за период простояли больше всего.
    struct Place: Equatable, Sendable {
        let lat: Double
        let lon: Double
        let seconds: TimeInterval
        /// Сколько раз здесь вставали (разных пробок).
        let times: Int
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    }

    /// Пробки периода по записям: места и часы. Сумму времени экран берёт из
    /// дневных агрегатов (они переживают чистку записей); места и часы — только
    /// отсюда, по записям, которые ещё хранятся.
    struct Period: Equatable, Sendable {
        var places: [Place] = []
        /// Секунды пробок по часам суток (24 корзины) — «когда».
        var byHour = [Double](repeating: 0, count: 24)
        /// Поездок, где стояли в пробке хоть раз.
        var trips = 0

        /// Четырёхчасовой блок с наибольшим временем и его доля.
        var peakBlock: (index: Int, share: Double)? {
            let blocks = (0..<6).map { block in (0..<4).reduce(0.0) { $0 + byHour[block * 4 + $1] } }
            let total = blocks.reduce(0, +)
            guard total > 0, let top = blocks.enumerated().max(by: { $0.element < $1.element }) else { return nil }
            return (top.offset, top.element / total)
        }

        static func == (a: Period, b: Period) -> Bool {
            a.places == b.places && a.byHour == b.byHour && a.trips == b.trips
        }
    }

    static func period(_ records: [TripRecord], calendar: Calendar = .current,
                       cellMeters: CLLocationDistance = AppConfig.jamPlaceCellMeters,
                       maxPlaces: Int = 3) -> Period {
        var result = Period()
        var cells: [Int64: (lat: Double, lon: Double, seconds: Double, times: Int)] = [:]
        for record in records {
            guard let jams = record.jams, !jams.isEmpty else { continue }
            result.trips += 1
            for jam in jams {
                result.byHour[calendar.component(.hour, from: jam.at)] += jam.seconds
                let key = GridCell.key(lat: jam.lat, lon: jam.lon, meters: cellMeters)
                var cell = cells[key] ?? (0, 0, 0, 0)
                // Точка места — взвешенная по времени: куда тянет больше стояния.
                let total = cell.seconds + jam.seconds
                cell.lat = (cell.lat * cell.seconds + jam.lat * jam.seconds) / total
                cell.lon = (cell.lon * cell.seconds + jam.lon * jam.seconds) / total
                cell.seconds = total
                cell.times += 1
                cells[key] = cell
            }
        }
        result.places = cells.values
            .sorted { $0.seconds > $1.seconds }
            .prefix(maxPlaces)
            .map { Place(lat: $0.lat, lon: $0.lon, seconds: $0.seconds, times: $0.times) }
        return result
    }
}

/// Клетка сетки по метрам — общая для «где пробки», «где выше лимита» и
/// памяти своих дорог. Долгота сжата по широте точки: в Узбекистане (37–46°)
/// клетка остаётся почти квадратной.
nonisolated enum GridCell {
    static func key(lat: Double, lon: Double, meters: CLLocationDistance) -> Int64 {
        let latStep = meters / 111_320
        // Шаг долготы — по фиксированной широте 41°, а не по широте точки:
        // иначе соседние точки на границе получали бы клетки разной ширины,
        // и «соседи клетки» переставали быть соседями.
        let lonStep = meters / (111_320 * cos(41.0 * .pi / 180))
        let y = Int64((lat / latStep).rounded(.down))
        let x = Int64((lon / lonStep).rounded(.down))
        return y << 32 | (x & 0xFFFF_FFFF)
    }

    /// Ключ соседней клетки (dy, dx) — для коридора «клетка и её соседи».
    static func neighbor(_ key: Int64, dy: Int64, dx: Int64) -> Int64 {
        let y = key >> 32
        let x = Int64(Int32(truncatingIfNeeded: key & 0xFFFF_FFFF))
        return (y + dy) << 32 | ((x + dx) & 0xFFFF_FFFF)
    }
}
