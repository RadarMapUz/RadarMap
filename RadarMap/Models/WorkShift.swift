//
//  WorkShift.swift
//  RadarMap
//
//  Смены водителя такси или курьера (план 19.10, 12б.9). У таксиста нет
//  «поездки на работу» — есть день из десятков рейсов, и считать его
//  поездками бессмысленно: «47 поездок, средняя 6 км» ничего не говорит.
//  Говорит смена: с 8:10 до 18:40, 212 км, 3 превышения, штрафы по замерам
//  и топливо.
//
//  Смена = рабочие рейсы (TripRecord.work) подряд, пока между концом одного
//  и началом следующего не больше часа простоя. Записи не склеиваются и не
//  переписываются: смены — взгляд на историю, поэтому выключение режима не
//  трогает прошлые поездки, а включение не переписывает старые личные.
//
//  Чистая логика — WorkShiftTests.
//

import Foundation

nonisolated struct WorkShift: Identifiable, Equatable, Sendable {
    /// Первый рейс смены.
    let id: Double
    let start: Date
    let end: Date
    let trips: Int
    let distanceMeters: Double
    /// В движении — без стоянок и простоев между рейсами.
    let movingSeconds: TimeInterval
    /// Проезды камер со штрафуемым превышением.
    let overspeeds: Int
    /// Штрафы по замерам — по тем же воротам, что в «Итогах».
    let fineRisk: Double

    /// Длина смены — от первого старта до последнего финиша.
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// Смены из истории, новые первыми.
    static func shifts(from records: [TripRecord],
                       gap: TimeInterval = AppConfig.workShiftGapSeconds) -> [WorkShift] {
        let work = records.filter { $0.work == true }.sorted { $0.startedAt < $1.startedAt }
        var groups: [[TripRecord]] = []
        for record in work {
            if let last = groups.last?.last, record.startedAt.timeIntervalSince(last.endedAt) <= gap {
                groups[groups.count - 1].append(record)
            } else {
                groups.append([record])
            }
        }
        return groups.map(make).reversed()
    }

    private static func make(_ trips: [TripRecord]) -> WorkShift {
        let passes = trips.flatMap(\.passed)
        return WorkShift(
            id: trips[0].id,
            start: trips[0].startedAt,
            end: trips.map(\.endedAt).max() ?? trips[0].endedAt,
            trips: trips.count,
            distanceMeters: trips.reduce(0) { $0 + $1.distanceMeters },
            movingSeconds: trips.reduce(0) { $0 + $1.movingDuration },
            overspeeds: passes.filter { ($0.overLimitKmh ?? 0) > FineSchedule.toleranceKmh && $0.limitIsCertain }.count,
            fineRisk: TripHistory.fineRisk(of: passes))
    }
}
