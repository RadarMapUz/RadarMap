//
//  CommuteLoss.swift
//  RadarMap
//
//  «Где ушло время» (план 19.10, 8.8.8): отрезки поездки дом↔работа, где она
//  шла медленнее обычного, — по участкам профиля (CommuteProfile) против
//  медианы ДРУГИХ поездок того же варианта, того же класса дня и часа выезда
//  (та же выборка, что у призрака).
//
//  Правила:
//    * только медленные места, без «где были быстрее»: похвала за участок
//      подталкивает гнать, а призрак — не секундомер;
//    * участок медленный, только если он хуже q75 водителя — медленнее
//      обычного разброса, а не просто медленнее медианы: иначе каждый
//      светофор становится «потерей»;
//    * потеря отрезка — сумма «секунды − медиана» по его участкам, и
//      называется отрезок, только если это хотя бы минута;
//    * стоянка (склейка, магазин) и неизмеренный участок рвут отрезок — это
//      не пробка (CommuteProfile.Row.noData).
//
//  Чистая логика без часов и диска — CommuteLossTests.
//

import CoreLocation
import Foundation

nonisolated enum CommuteLoss {

    struct Stretch: Equatable, Sendable {
        /// Участки профиля, включительно.
        let segments: ClosedRange<Int>
        /// Начало и конец по линии варианта, м от начала.
        let startMeters: Double
        let endMeters: Double
        /// Потеряно против медианы, с.
        let lostSeconds: Double
        /// Середина отрезка — для подписи места («ул. Бабура»).
        let midLat: Double
        let midLon: Double

        var midpoint: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: midLat, longitude: midLon) }

        var lostMinutes: Int { max(1, Int((lostSeconds / 60).rounded())) }
    }

    /// Медленные отрезки поездки `tripID` в варианте — от большей потери к
    /// меньшей. Пусто, если строки этой поездки в варианте нет или сравнить
    /// не с чем (меньше трёх других поездок того же класса дня).
    static func stretches(in variant: CommuteProfile.Variant, tripID: Double,
                          calendar: Calendar = .current,
                          minLossSeconds: Double = AppConfig.commuteLossMinSeconds,
                          maxCount: Int = AppConfig.commuteLossMaxStretches) -> [Stretch] {
        guard let row = variant.rows.first(where: { $0.tripID == tripID }) else { return [] }
        // Своя строка в «обычно» не входит: медленная поездка тянула бы
        // медиану к себе и прятала собственную потерю.
        let others = variant.rows.filter { $0.tripID != tripID }
        let minute = CommuteProfile.minuteOfDay(row.departure, calendar: calendar)
        guard let rows = CommuteGhost.selectRows(others, weekend: row.weekend, departureMinute: minute,
                                                 calendar: calendar),
              let base = CommuteGhost.baseline(ends: variant.ends, limitKmh: variant.limitKmh, rows: rows)
        else { return [] }

        let count = min(row.seconds.count, base.median.count)
        var runs: [(first: Int, last: Int, lost: Double)] = []
        var open: (first: Int, lost: Double)?
        for j in 0..<count {
            let raw = row.seconds[j]
            let seconds = Double(raw)
            if raw != CommuteProfile.Row.noData, seconds > base.q75[j] {
                open = (open?.first ?? j, (open?.lost ?? 0) + seconds - base.median[j])
            } else if let run = open {
                runs.append((run.first, j - 1, run.lost))
                open = nil
            }
        }
        if let run = open { runs.append((run.first, count - 1, run.lost)) }

        let coordinates = variant.coordinates
        guard let anchor = coordinates.first else { return [] }
        let frame = CommuteProfile.Frame(latitude: anchor.latitude)
        let line = coordinates.map { frame.xy($0.latitude, $0.longitude) }
        return runs
            .filter { $0.lost >= minLossSeconds }
            // Равные потери — по порядку пути, чтобы список не прыгал.
            .sorted { $0.lost != $1.lost ? $0.lost > $1.lost : $0.first < $1.first }
            .prefix(maxCount)
            .map { run in
                let start = base.start(of: run.first)
                let end = base.ends[run.last]
                let middle = frame.coordinate(CommuteProfile.Geometry.point(on: line, at: (start + end) / 2))
                return Stretch(segments: run.first...run.last, startMeters: start, endMeters: end,
                               lostSeconds: run.lost, midLat: middle.latitude, midLon: middle.longitude)
            }
    }
}
