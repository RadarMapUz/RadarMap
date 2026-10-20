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

nonisolated struct WorkShift: Identifiable, Equatable, Sendable, Codable {
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

    // MARK: - Журнал закрытых смен

    /// Полные записи живут 30 дней и не больше 50 штук — у таксиста это 2–3
    /// дня рейсов. Поэтому закрытая смена (простой после неё дольше часа)
    /// записывается в журнал один раз и дальше от истории не зависит;
    /// журнал хранит 90 дней. Идущая смена считается из истории вживую.
    /// `ongoingSince` — старт идущего рабочего рейса (nil — рейса нет).
    static func logged(_ log: [WorkShift], history: [TripRecord], now: Date,
                       ongoingSince: Date? = nil,
                       gap: TimeInterval = AppConfig.workShiftGapSeconds) -> [WorkShift] {
        let closed = shifts(from: history, gap: gap).filter {
            isClosed($0, now: now, ongoingSince: ongoingSince, gap: gap) && !overlaps($0, log)
        }
        let horizon = now.addingTimeInterval(-AppConfig.workShiftLogDays * 86_400)
        return (log + closed).filter { $0.end >= horizon }.sorted { $0.start > $1.start }
    }

    /// Смена закрыта: простой после неё дольше часа, и идущий рабочий рейс её
    /// не продолжает. Рейс ложится в историю только на финише — без второй
    /// проверки пересчёт посреди долгого рейса (старт сцены, возврат из
    /// приложения такси) записывал смену урезанной, а остаток дня совпадал с
    /// ней по времени и пропадал из «Смен» насовсем (ревью 14.1). Продолженная
    /// склейкой запись тоже вне истории, пока едем, — её старт раньше конца
    /// оставшейся части, и смена так же открыта.
    static func isClosed(_ shift: WorkShift, now: Date, ongoingSince: Date?,
                         gap: TimeInterval = AppConfig.workShiftGapSeconds) -> Bool {
        guard now.timeIntervalSince(shift.end) > gap else { return false }
        if let ongoingSince, ongoingSince.timeIntervalSince(shift.end) <= gap { return false }
        return true
    }

    /// Что показать: журнал и идущие смены из истории, без повторов, новые первыми.
    static func display(log: [WorkShift], history: [TripRecord],
                        gap: TimeInterval = AppConfig.workShiftGapSeconds) -> [WorkShift] {
        let live = shifts(from: history, gap: gap).filter { !overlaps($0, log) }
        return (log + live).sorted { $0.start > $1.start }
    }

    /// Смена уже в журнале — по времени, а не по id: когда первые рейсы
    /// записанной смены вырежет чистка истории, остаток соберётся заново с
    /// другим id, и по id он стал бы второй, урезанной копией.
    private static func overlaps(_ shift: WorkShift, _ log: [WorkShift]) -> Bool {
        log.contains { $0.start <= shift.end && shift.start <= $0.end }
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
