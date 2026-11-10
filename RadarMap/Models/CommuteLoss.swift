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
//      не пробка (CommuteProfile.Row.noData);
//    * первые и последние `commuteLossEdgeMeters` — не дорога: участок 0
//      начинается с первой точки поездки, и прогрев, ворота, выезд со стоянки
//      ложились в «+10 мин в 100 м от работы» (разбор 10.11). Их лишнее время
//      — отдельно (`Report.leaving/arriving`), и называется оно честно.
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

    /// Разбор поездки: места на дороге и лишнее время у краёв пути.
    struct Report: Equatable, Sendable {
        var stretches: [Stretch] = []
        /// Сверх обычного в первых метрах — выезд со стоянки, с.; 0 — нет.
        var leaving: Double = 0
        /// Сверх обычного в последних метрах — подъезд и поиск места, с.
        var arriving: Double = 0
    }

    /// Медленные отрезки поездки `tripID` в варианте — `report(...).stretches`.
    static func stretches(in variant: CommuteProfile.Variant, tripID: Double,
                          calendar: Calendar = .current,
                          minLossSeconds: Double = AppConfig.commuteLossMinSeconds,
                          maxCount: Int = AppConfig.commuteLossMaxStretches) -> [Stretch] {
        report(in: variant, tripID: tripID, calendar: calendar,
               minLossSeconds: minLossSeconds, maxCount: maxCount).stretches
    }

    /// Медленные отрезки поездки `tripID` в варианте — от большей потери к
    /// меньшей. Пусто, если строки этой поездки в варианте нет или сравнить
    /// не с чем: меньше трёх других поездок того же класса дня В ЭТОТ ЖЕ ЧАС
    /// (±2 ч) — медиана всего дня меряла бы поездку в 9:30 утренним часом пик.
    /// Край пути (`edgeMeters` от начала и конца) в места не идёт.
    static func report(in variant: CommuteProfile.Variant, tripID: Double,
                       calendar: Calendar = .current,
                       minLossSeconds: Double = AppConfig.commuteLossMinSeconds,
                       maxCount: Int = AppConfig.commuteLossMaxStretches,
                       edgeMeters: Double = AppConfig.commuteLossEdgeMeters) -> Report {
        guard let row = variant.rows.first(where: { $0.tripID == tripID }) else { return Report() }
        // Своя строка в «обычно» не входит: медленная поездка тянула бы
        // медиану к себе и прятала собственную потерю.
        let others = variant.rows.filter { $0.tripID != tripID }
        let minute = CommuteProfile.minuteOfDay(row.departure, calendar: calendar)
        guard let selected = CommuteGhost.selectRowsTiered(others, weekend: row.weekend,
                                                           departureMinute: minute, calendar: calendar),
              selected.tier <= .twoHours,
              let base = CommuteGhost.baseline(ends: variant.ends, limitKmh: variant.limitKmh,
                                               rows: selected.rows)
        else { return Report() }

        let count = min(row.seconds.count, base.median.count)
        // Состояние участка. «Обычно» есть, только где его мерили хотя бы две
        // другие поездки: остальное база заполняет средним темпом для прогноза,
        // и сравнение с ним выдумывало бы «потери» у дома, где автостарт
        // начинает поездки в полукилометре от ворот.
        enum State { case slow(Double), normal, gap, unknown, edge }
        var states = [State](repeating: .unknown, count: count)
        var report = Report()
        let length = base.length
        for j in 0..<count {
            let measured = selected.rows.reduce(0) {
                $0 + (j < $1.seconds.count && $1.seconds[j] != CommuteProfile.Row.noData ? 1 : 0)
            }
            guard measured >= 2 else { continue }
            let raw = row.seconds[j]
            if base.start(of: j) < edgeMeters || base.ends[j] > length - edgeMeters {
                states[j] = .edge
                if raw != CommuteProfile.Row.noData, Double(raw) > base.q75[j] {
                    let extra = Double(raw) - base.median[j]
                    if base.start(of: j) < edgeMeters { report.leaving += extra } else { report.arriving += extra }
                }
            } else if raw == CommuteProfile.Row.noData {
                states[j] = .gap
            } else if Double(raw) > base.q75[j] {
                states[j] = .slow(Double(raw) - base.median[j])
            } else {
                states[j] = .normal
            }
        }
        // Пробел посреди пробки — не разрыв: стояние в очереди дольше двух
        // минут на границе участков даёт неизмеренные соседние участки, и ровно
        // там ушло больше всего времени. Короткий пробел между двумя медленными
        // участками входит в отрезок с потерей, как у соседей; длинный или у
        // края — разрыв (стоянка, сошли с линии).
        var j = 0
        while j < count {
            guard case .gap = states[j] else { j += 1; continue }
            var end = j
            while end + 1 < count, case .gap = states[end + 1] { end += 1 }
            if end - j + 1 <= AppConfig.commuteLossBridgeSegments, j > 0, end + 1 < count,
               case .slow(let left) = states[j - 1], case .slow(let right) = states[end + 1] {
                for k in j...end { states[k] = .slow((left + right) / 2) }
            }
            j = end + 1
        }
        var runs: [(first: Int, last: Int, lost: Double)] = []
        var open: (first: Int, lost: Double)?
        for j in 0..<count {
            if case .slow(let lost) = states[j] {
                open = (open?.first ?? j, (open?.lost ?? 0) + lost)
            } else if let run = open {
                runs.append((run.first, j - 1, run.lost))
                open = nil
            }
        }
        if let run = open { runs.append((run.first, count - 1, run.lost)) }

        if report.leaving < minLossSeconds { report.leaving = 0 }
        if report.arriving < minLossSeconds { report.arriving = 0 }
        let coordinates = variant.coordinates
        guard let anchor = coordinates.first else { return report }
        let frame = CommuteProfile.Frame(latitude: anchor.latitude)
        let line = coordinates.map { frame.xy($0.latitude, $0.longitude) }
        report.stretches = runs
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
        return report
    }

    /// Разбор поездки в том варианте, где лежит её строка: места и края пути
    /// («у работы, до выезда на дорогу»). nil — строки нет ни в одном варианте.
    static func report(for tripID: Double, in variants: [CommuteProfile.Variant],
                       calendar: Calendar = .current) -> Report? {
        guard let variant = variants.first(where: { $0.rows.contains { $0.tripID == tripID } }) else { return nil }
        return report(in: variant, tripID: tripID, calendar: calendar)
    }

    /// Места потерь для поездок экрана «Дорога»: у последней — все (до трёх),
    /// у остальных — самое дорогое, и только у поездок, которые и правда
    /// дольше обычного (`slower`). Вариант — тот, где лежит строка поездки.
    static func places(for trips: [(id: Double, slower: Bool)], lastID: Double,
                       in variants: [CommuteProfile.Variant],
                       calendar: Calendar = .current) -> [Double: [Stretch]] {
        var found: [Double: [Stretch]] = [:]
        for trip in trips where trip.id == lastID || trip.slower {
            guard let variant = variants.first(where: { $0.rows.contains { $0.tripID == trip.id } })
            else { continue }
            let stretches = Self.stretches(in: variant, tripID: trip.id, calendar: calendar)
            guard !stretches.isEmpty else { continue }
            found[trip.id] = trip.id == lastID ? stretches : Array(stretches.prefix(1))
        }
        return found
    }
}
