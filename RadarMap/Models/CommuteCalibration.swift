//
//  CommuteCalibration.swift
//  RadarMap
//
//  Калибровка призрака (этап 24.2, жалоба владельца 21.10: «дал 8:25,
//  приехал 8:38; выхожу раньше — приезжаю быстрее»). Две систематические
//  ошибки старой базы, обе проверены на синтетике (CommuteCalibrationTests):
//
//  1. Сумма медиан участков МЕНЬШЕ медианы целых поездок. На каждом участке
//     со светофором «обычно» — без остановки (красный в трёх поездках из
//     десяти — не медиана), а в каждой целой поездке красные есть. На 12 км
//     с пятнадцатью светофорами — около 3 мин оптимизма, и каждый день в одну
//     сторону. Поэтому база приводится к медиане отношения «вся строка /
//     сумма медиан тех же участков» по тем же строкам — масштаб с
//     ограничением `commuteCalibrationMin…Max`: поправка на светофоры, а не
//     новая модель.
//  2. Ступени ±60/±120 мин смешивали выезд 7:40 и 8:30 — в восемь утра
//     полчаса это другая дорога. Строки теперь взвешиваются по близости
//     выезда (ядро Гаусса ~20 мин); ступени остаются запасным путём, когда в
//     ядро легло меньше `commuteGhostKernelMinMass` «поездок».
//
//  Поправка остаточного сдвига из журнала точности (CommuteAccuracy) — третий
//  множитель, медленный и в узких границах; считается там, приходит сюда
//  одним числом `bias`.
//
//  Чистая логика без часов и диска.
//

import Foundation

nonisolated extension CommuteGhost {

    // MARK: - Выборка с весами

    /// Строки для базы и их веса (≤ 1 у ядра, 1 у ступеней): `tier` говорит,
    /// насколько выборка «про этот час» — ядро считается часовым окном.
    struct Selection: Sendable {
        let rows: [CommuteProfile.Row]
        let weights: [Double]
        let tier: RowTier
        /// Сумма весов — сколько «поездок» на самом деле легло в выборку.
        var mass: Double { weights.reduce(0, +) }
    }

    /// Вес строки по разнице выездов: ядро Гаусса с `commuteGhostKernelMinutes`.
    static func kernelWeight(minutesApart: Int) -> Double {
        let z = Double(minutesApart) / AppConfig.commuteGhostKernelMinutes
        return exp(-0.5 * z * z)
    }

    /// Выборка для призрака и «сейчас ~44 мин»: тот же класс дня, веса по
    /// близости выезда; тот же день недели весит больше, если таких строк
    /// рядом хватает. В ядро легло меньше `commuteGhostKernelMinMass` —
    /// прежние ступени ±60/±120/весь день без весов. nil — меньше `minRows`.
    static func select(_ rows: [CommuteProfile.Row], weekend: Bool, departure: Date,
                       calendar: Calendar = .current,
                       minRows: Int = AppConfig.commuteGhostMinRows) -> Selection? {
        let minute = CommuteProfile.minuteOfDay(departure, calendar: calendar)
        let weekday = calendar.component(.weekday, from: departure)
        let sameClass = rows.filter {
            ($0.weekend || UzHolidays.isHoliday($0.departure, calendar: calendar)) == weekend
        }
        var picked: [CommuteProfile.Row] = []
        var weights: [Double] = []
        var sameDay: [Int] = []
        for row in sameClass {
            let m = CommuteProfile.minuteOfDay(row.departure, calendar: calendar)
            let d = abs(m - minute)
            let w = kernelWeight(minutesApart: min(d, 1440 - d))
            guard w >= AppConfig.commuteGhostKernelMinWeight else { continue }
            if calendar.component(.weekday, from: row.departure) == weekday { sameDay.append(picked.count) }
            picked.append(row)
            weights.append(w)
        }
        if picked.count >= minRows, weights.reduce(0, +) >= AppConfig.commuteGhostKernelMinMass {
            // Понедельник утром не вторник: в будни свой день весит вдвое, но
            // только когда таких строк рядом хватает — одна поездка не «обычно».
            if sameDay.reduce(0, { $0 + weights[$1] }) >= AppConfig.commuteGhostWeekdayMinMass {
                for i in sameDay { weights[i] *= AppConfig.commuteGhostWeekdayBoost }
            }
            return Selection(rows: picked, weights: weights, tier: .hour)
        }
        guard let tiered = selectRowsTiered(rows, weekend: weekend, departureMinute: minute,
                                            calendar: calendar, minRows: minRows) else { return nil }
        return Selection(rows: tiered.rows, weights: [Double](repeating: 1, count: tiered.rows.count),
                         tier: tiered.tier)
    }

    // MARK: - Взвешенный квантиль

    /// Квантиль по весам — обобщение линейного (`quantile`): при равных весах
    /// совпадает с ним точка в точку, поэтому старые базы без весов не
    /// меняются ни на секунду. Точка k стоит на (C_k − w_k/2 − w_1/2) /
    /// (W − w_1/2 − w_n/2), между точками — линейно.
    static func weightedQuantile(_ pairs: [(value: Double, weight: Double)], _ q: Double) -> Double {
        let sorted = pairs.filter { $0.weight > 0 }.sorted { $0.value < $1.value }
        guard let first = sorted.first, let last = sorted.last else { return .nan }
        guard sorted.count > 1 else { return first.value }
        let total = sorted.reduce(0) { $0 + $1.weight }
        let span = total - first.weight / 2 - last.weight / 2
        guard span > 0 else { return quantile(sorted.map(\.value), q) }
        var cumulative = 0.0
        var previous: (position: Double, value: Double)?
        for pair in sorted {
            cumulative += pair.weight
            let position = (cumulative - pair.weight / 2 - first.weight / 2) / span
            if position >= q {
                guard let previous, position > previous.position else { return pair.value }
                let t = (q - previous.position) / (position - previous.position)
                return previous.value + (pair.value - previous.value) * t
            }
            previous = (position, pair.value)
        }
        return last.value
    }

    // MARK: - Поправка на светофоры

    /// Во сколько раз целые поездки дольше суммы медиан их же участков:
    /// медиана по строкам отношения «строка / медианы тех же участков» (у
    /// строки со стоянкой участки со стоянкой пропущены — с обеих сторон).
    /// Ограничено `commuteCalibrationMin…Max`; меньше `commuteGhostMinRows`
    /// строк с измерениями — 1.
    static func calibration(rows: [CommuteProfile.Row], weights: [Double], median: [Double]) -> Double {
        let ratios = rowRatios(rows: rows, weights: weights, median: median)
        guard ratios.count >= AppConfig.commuteGhostMinRows else { return 1 }
        let raw = weightedQuantile(ratios, 0.5)
        guard raw.isFinite else { return 1 }
        return min(max(raw, AppConfig.commuteCalibrationMin), AppConfig.commuteCalibrationMax)
    }

    /// «Строка / сумма медиан тех же участков» с весом строки.
    static func rowRatios(rows: [CommuteProfile.Row], weights: [Double],
                          median: [Double]) -> [(value: Double, weight: Double)] {
        var ratios: [(value: Double, weight: Double)] = []
        for (r, row) in rows.enumerated() {
            var own = 0.0, usual = 0.0
            for j in 0..<min(row.seconds.count, median.count) where row.seconds[j] != CommuteProfile.Row.noData {
                own += Double(row.seconds[j])
                usual += median[j]
            }
            guard usual > 0 else { continue }
            ratios.append((own / usual, r < weights.count ? weights[r] : 1))
        }
        return ratios
    }

    /// Разброс целых поездок (межквартильный размах отношений / 1,35): для
    /// честной вилки раннего прогноза. Участки по отдельности его занижают —
    /// красный на одном перекрёстке и зелёный на соседнем не гасят друг друга.
    static func totalSpread(rows: [CommuteProfile.Row], weights: [Double], median: [Double]) -> Double {
        let ratios = rowRatios(rows: rows, weights: weights, median: median)
        guard ratios.count >= 2 else { return 0 }
        let spread = (weightedQuantile(ratios, 0.75) - weightedQuantile(ratios, 0.25)) / 1.35
        return spread.isFinite ? max(0, spread) : 0
    }

    /// База по выборке: веса, поправка на светофоры и сдвиг журнала — одним
    /// вызовом для призрака и «сейчас ~44 мин».
    static func calibratedBaseline(_ variant: CommuteProfile.Variant, selection: Selection,
                                   bias: Double = 1) -> Baseline? {
        baseline(ends: variant.ends, limitKmh: variant.limitKmh, rows: selection.rows,
                 weights: selection.weights, calibrate: true, bias: bias)
    }
}
