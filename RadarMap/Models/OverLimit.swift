//
//  OverLimit.swift
//  RadarMap
//
//  «Выше лимита вне камер» (31E, п. 3): какую долю пути с известным лимитом
//  ехали заметно быстрее знака и где это бывает чаще — на телефоне, по
//  лимиту дороги (SpeedLimitService), который и так считается каждый тик.
//
//  Это не про камеры и не про деньги. Путь ближе `overLimitCameraZoneMeters`
//  к камере сюда не входит — у камер своя строка с проездами и штрафами, —
//  а слово «штраф» на этом экране не звучит: камеры здесь нет, и сумма была
//  бы выдумкой. Разговор о безопасности: где привычка ехать быстрее знака.
//
//  Лимит — только достоверный (из OSM): предположенный по классу дороги для
//  совета годится, для «вы ехали быстрее знака 8 % пути» — нет.
//
//  Ничего из этого не уходит с телефона: копится в записи поездки и в
//  дневном итоге, как километры.
//
//  Чистая логика — OverLimitTests.
//

import Foundation
import CoreLocation

/// Участок, где ехали заметно выше лимита: начало, длина, лимит, максимум.
nonisolated struct OverLimitRun: Codable, Equatable, Sendable {
    let lat: Double
    let lon: Double
    let at: Date
    var meters: Double
    let limitKmh: Int
    var maxKmh: Double
}

/// Итог поездки: путь с известным лимитом, из него — выше лимита, и
/// заметные участки. `overMeters` включает и короткие участки, которых нет в
/// `runs` (разгон на обгоне в места не идёт, но в долю — да).
nonisolated struct OverLimitTally: Codable, Equatable, Sendable {
    var knownMeters: Double = 0
    var overMeters: Double = 0
    var runs: [OverLimitRun] = []

    /// Сумма двух поездок — склейка.
    static func + (a: OverLimitTally, b: OverLimitTally) -> OverLimitTally {
        OverLimitTally(knownMeters: a.knownMeters + b.knownMeters,
                       overMeters: a.overMeters + b.overMeters,
                       runs: a.runs + b.runs)
    }

    /// Доля одной ноги при разделении поездки: участки — по времени, метры
    /// без участков — пропорционально пути (`share`).
    func leg(share: Double, contains: (Date) -> Bool) -> OverLimitTally {
        let mine = runs.filter { contains($0.at) }
        let inRuns = runs.reduce(0) { $0 + $1.meters }
        let loose = max(0, overMeters - inRuns)
        let mineMeters = mine.reduce(0) { $0 + $1.meters }
        return OverLimitTally(knownMeters: knownMeters * share,
                              overMeters: mineMeters + loose * share,
                              runs: mine)
    }
}

/// Счётчик живой поездки: шаг одометра → итог. Состояние — открытый участок.
nonisolated struct OverLimitMeter: Equatable {
    private(set) var tally = OverLimitTally()
    private var open: OverLimitRun?

    init(resuming base: OverLimitTally? = nil) {
        tally = base ?? OverLimitTally()
    }

    /// Шаг пути. `limitKmh` — достоверный лимит этого места (nil — неизвестен),
    /// `atCamera` — рядом камера (её путь не наш).
    mutating func step(meters: Double, speedKmh: Double, limitKmh: Int?, atCamera: Bool,
                       coordinate: CLLocationCoordinate2D, at time: Date,
                       margin: Double = AppConfig.overLimitMarginKmh) {
        guard meters > 0 else { return }
        guard let limitKmh, !atCamera else { close(); return }
        tally.knownMeters += meters
        guard speedKmh > Double(limitKmh) + margin else { close(); return }
        tally.overMeters += meters
        if var run = open, run.limitKmh == limitKmh {
            run.meters += meters
            run.maxKmh = max(run.maxKmh, speedKmh)
            open = run
        } else {
            close()
            open = OverLimitRun(lat: (coordinate.latitude * 100_000).rounded() / 100_000,
                                lon: (coordinate.longitude * 100_000).rounded() / 100_000,
                                at: time, meters: meters, limitKmh: limitKmh, maxKmh: speedKmh)
        }
    }

    /// Итог на финише: открытый участок закрывается.
    mutating func finish() -> OverLimitTally {
        close()
        return tally
    }

    private mutating func close(minMeters: Double = AppConfig.overLimitMinRunMeters,
                                maxRuns: Int = AppConfig.overLimitMaxRunsPerTrip) {
        guard let run = open else { return }
        open = nil
        guard run.meters >= minMeters else { return }
        tally.runs.append(run)
        if tally.runs.count > maxRuns {
            // Потолок — самые длинные; порядок по времени нужен разделению.
            tally.runs = Array(tally.runs.sorted { $0.meters > $1.meters }.prefix(maxRuns))
                .sorted { $0.at < $1.at }
        }
    }
}

nonisolated enum OverLimit {

    /// Место, где выше лимита бывает чаще всего.
    struct Place: Equatable, Sendable {
        let lat: Double
        let lon: Double
        let meters: Double
        let times: Int
        /// Лимит, с которым здесь встречались чаще всего.
        let limitKmh: Int
        let maxKmh: Double
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    }

    /// Места периода по записям — от частых к редким: сначала сколько раз,
    /// потом сколько метров (одна длинная трасса не важнее ежедневной улицы).
    static func places(_ records: [TripRecord],
                       cellMeters: CLLocationDistance = AppConfig.overLimitPlaceCellMeters,
                       maxPlaces: Int = 3) -> [Place] {
        struct Cell { var lat = 0.0, lon = 0.0, meters = 0.0, times = 0, maxKmh = 0.0, limits: [Int: Int] = [:] }
        var cells: [Int64: Cell] = [:]
        for record in records {
            for run in record.overLimit?.runs ?? [] {
                let key = GridCell.key(lat: run.lat, lon: run.lon, meters: cellMeters)
                var cell = cells[key] ?? Cell()
                let total = cell.meters + run.meters
                cell.lat = (cell.lat * cell.meters + run.lat * run.meters) / total
                cell.lon = (cell.lon * cell.meters + run.lon * run.meters) / total
                cell.meters = total
                cell.times += 1
                cell.maxKmh = max(cell.maxKmh, run.maxKmh)
                cell.limits[run.limitKmh, default: 0] += 1
                cells[key] = cell
            }
        }
        return cells.values
            .sorted { ($0.times, $0.meters) > ($1.times, $1.meters) }
            .prefix(maxPlaces)
            .map { cell in
                Place(lat: cell.lat, lon: cell.lon, meters: cell.meters, times: cell.times,
                      limitKmh: cell.limits.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key ?? 0,
                      maxKmh: cell.maxKmh)
            }
    }

    /// Доля пути выше лимита, 0…1. nil — пути с известным лимитом мало, и
    /// «0 %» было бы не заслугой, а нехваткой данных.
    static func share(over: Double, known: Double,
                      minKnown: Double = AppConfig.overLimitMinKnownMeters) -> Double? {
        guard known >= minKnown else { return nil }
        return min(1, max(0, over / known))
    }
}
