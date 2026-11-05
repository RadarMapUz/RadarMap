//
//  TripReward.swift
//  RadarMap
//
//  «Заработанное» в итоге поездки (этап 45, вариант A дизайнера): не больше
//  двух строк — о вождении и о сообществе — и ничего, что не заработано.
//
//  Strava показывает награды только заработанные, нули не хвалит; Waze
//  возвращает людей отмечать фразой «вашу отметку поблагодарили». Отсюда
//  два правила. При штрафуемом превышении похвалы нет — строка становится
//  фактом того же цвета, что балл. О сообществе — только то, что знает
//  сервер: ПОДТВЕРЖДЕНИЯ своей отметки другими водителями (`confirmers` из
//  /api/mine — другое устройство И другой адрес). Сколько водителей
//  получили предупреждение, он не знает и знать не должен: список раздаётся
//  целиком, а счёт доставок у места потребовал бы координат.
//
//  Чистая логика — TripRewardTests.
//

import Foundation

nonisolated enum TripReward {

    enum Line: Equatable, Sendable {
        /// «Все 8 камер — без превышения» (clean == total) или «7 из 8 камер —
        /// без превышения» (лишнее, но не штрафуемое).
        case camerasClean(clean: Int, total: Int)
        /// Штрафуемое превышение с суммой риска — факт, без похвалы.
        case risk(Double)
        /// Штрафуемые превышения без достоверной суммы — факт, без похвалы.
        case overspeed(Int)
        /// Своя отметка этой поездки уже подтверждена: N независимых водителей.
        case reportConfirmed(drivers: Int)
        /// Своя отметка этой поездки ждёт подтверждения.
        case reportAwaiting(ReportKind)
        /// С прошлого итога пришли подтверждения прежних отметок.
        case earlierConfirmed(Int)

        /// Строка хвалит (вождение без превышения, подтверждённая отметка).
        var isPraise: Bool {
            switch self {
            case .camerasClean, .reportConfirmed, .earlierConfirmed: return true
            case .risk, .overspeed, .reportAwaiting:                 return false
            }
        }

        /// Строка о вождении (первая), а не о сообществе.
        var isDriving: Bool {
            switch self {
            case .camerasClean, .risk, .overspeed: return true
            default:                               return false
            }
        }
    }

    /// Своя отметка — то, что телефон помнит о ней (MobileCameraService.MyReport).
    struct OwnReport: Equatable, Sendable {
        let kind: ReportKind
        let at: Date
        /// Независимых подтверждений по словам сервера; nil — не спрашивали.
        let confirmers: Int?
        /// Живой список хоть раз показал «подтверждена».
        let confirmed: Bool

        /// Подтверждений не меньше одного, если живой список видел «подтверждена».
        var confirmations: Int { max(confirmers ?? 0, confirmed ? 1 : 0) }
    }

    /// Проезд камеры — только то, что нужно строке о вождении.
    struct Pass: Equatable, Sendable {
        let speedKmh: Double
        let limitKmh: Int?
    }

    /// - `seenConfirmations`: сколько подтверждений прежних отметок уже
    ///   показали прошлым итогом; nil — ни разу (первый итог задаёт отсчёт).
    /// - `reportGrace`: отметка вскоре после стопа — ещё этой поездки
    ///   (поставили, тормозя у подъезда).
    static func pick(verdict: TripRecord.Verdict, passes: [Pass], tripStart: Date, tripEnd: Date,
                     reports: [OwnReport], seenConfirmations: Int?,
                     reportGrace: TimeInterval = AppConfig.tripRewardReportGraceSeconds) -> [Line] {
        var lines: [Line] = []
        if let driving = drivingLine(verdict: verdict, passes: passes) { lines.append(driving) }
        if let community = communityLine(tripStart: tripStart, tripEnd: tripEnd, reports: reports,
                                         seenConfirmations: seenConfirmations, grace: reportGrace) {
            lines.append(community)
        }
        return lines
    }

    /// Подтверждений у отметок, поставленных до поездки, — отсчёт для
    /// «с прошлой поездки подтвердили ещё».
    static func earlierConfirmations(_ reports: [OwnReport], before tripStart: Date) -> Int {
        reports.filter { $0.at < tripStart }.reduce(0) { $0 + $1.confirmations }
    }

    private static func drivingLine(verdict: TripRecord.Verdict, passes: [Pass]) -> Line? {
        switch verdict {
        case .risk(let amount):     return .risk(amount)
        case .overspeed(let count): return .overspeed(count)
        case .unknownLimits, .noCameras: return nil
        case .clean:
            let limited = passes.compactMap { pass in pass.limitKmh.map { (pass.speedKmh, Double($0)) } }
            guard !limited.isEmpty else { return nil }
            let clean = limited.filter { $0.0 <= $0.1 }.count
            return .camerasClean(clean: clean, total: limited.count)
        }
    }

    private static func communityLine(tripStart: Date, tripEnd: Date, reports: [OwnReport],
                                      seenConfirmations: Int?, grace: TimeInterval) -> Line? {
        let window = tripStart...tripEnd.addingTimeInterval(grace)
        let own = reports.filter { window.contains($0.at) }
        if let best = own.max(by: { $0.confirmations < $1.confirmations }) {
            return best.confirmations > 0 ? .reportConfirmed(drivers: best.confirmations)
                                          : .reportAwaiting(best.kind)
        }
        guard let seenConfirmations else { return nil }
        let fresh = earlierConfirmations(reports, before: tripStart) - seenConfirmations
        return fresh > 0 ? .earlierConfirmed(fresh) : nil
    }
}
