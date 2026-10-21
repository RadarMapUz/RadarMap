//
//  CommuteCalibrationTests.swift
//  RadarMapTests
//
//  Калибровка призрака (24.2) на синтетических историях — сначала
//  подтверждение гипотез промаха «дал 8:25, приехал 8:38», потом их починка:
//  (а) сумма медиан участков со светофорами оптимистичнее целых поездок;
//  (б) ступени ±60 мин дают выезду 7:40 и 8:20 один и тот же прогноз.
//  Истина — средняя тысячи поездок той же модели в этот выезд.
//

import XCTest
@testable import RadarMap

final class CommuteCalibrationTests: XCTestCase {
    private typealias G = CommuteGhost
    private typealias Row = CommuteProfile.Row

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// SplitMix64 — воспроизводимый шум без системного генератора.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Дорога 12 км: 60 участков по 200 м, на пятнадцати — светофор (красный
    /// в 40 % поездок, 30–70 с). Пробка растёт с выездом: 7:30 — 20 с на
    /// участок, 8:30 — в 1,4 раза дольше.
    private let segments = 60
    private let lights: Set<Int> = [2, 6, 9, 13, 17, 21, 24, 28, 33, 37, 41, 45, 50, 54, 58]

    private func tripSeconds(departureMinute: Int, rng: inout Seeded) -> [Double] {
        let rush = 1 + min(max(Double(departureMinute - 450) / 60, 0), 1) * 0.4
        return (0..<segments).map { j in
            var s = 20 * rush * Double.random(in: 0.9...1.1, using: &rng)
            if lights.contains(j), Double.random(in: 0...1, using: &rng) < 0.4 {
                s += Double.random(in: 30...70, using: &rng)
            }
            return s
        }
    }

    /// Будний день февраля 2027 (праздников нет): `day` 1…26, без выходных.
    private func date(day: Int, minute: Int) -> Date {
        utc.date(from: DateComponents(year: 2027, month: 2, day: day, hour: minute / 60, minute: minute % 60))!
    }

    private var weekdays: [Int] {
        (1...26).filter { !utc.isDateInWeekend(date(day: $0, minute: 480)) }
    }

    /// Двадцать будних поездок с выездом 7:25–8:35.
    private func history(seed: UInt64 = 7) -> [Row] {
        var rng = Seeded(state: seed)
        return weekdays.prefix(20).enumerated().map { i, day in
            let minute = 445 + (i * 37) % 70
            let seconds = tripSeconds(departureMinute: minute, rng: &rng)
            return Row(tripID: Double(i), departure: date(day: day, minute: minute), weekend: false,
                       arrivalMinute: 0, seconds: seconds.map { UInt16($0.rounded()) })
        }
    }

    private var ends: [Float] { (1...segments).map { Float($0 * 200) } }

    /// Средняя тысячи поездок модели в этот выезд — «как на самом деле».
    private func truth(departureMinute: Int) -> Double {
        var rng = Seeded(state: 99)
        let n = 1000
        return (0..<n).reduce(0.0) { sum, _ in
            sum + tripSeconds(departureMinute: departureMinute, rng: &rng).reduce(0, +)
        } / Double(n)
    }

    private func oldBase(_ rows: [Row], minute: Int) throws -> G.Baseline {
        let selected = try XCTUnwrap(G.selectRows(rows, weekend: false, departureMinute: minute, calendar: utc))
        return try XCTUnwrap(G.baseline(ends: ends, limitKmh: [], rows: selected))
    }

    private func newBase(_ rows: [Row], minute: Int, day: Int = 26) throws -> G.Baseline {
        let selection = try XCTUnwrap(G.select(rows, weekend: false, departure: date(day: day, minute: minute),
                                               calendar: utc))
        return try XCTUnwrap(G.baseline(ends: ends, limitKmh: [], rows: selection.rows,
                                        weights: selection.weights, offsets: selection.offsets, calibrate: true))
    }

    // MARK: - Гипотеза (а): светофоры

    /// Сумма медиан участков меньше медианы целых поездок тех же строк — на
    /// каждом участке «обычно зелёный», а в каждой поездке красные есть.
    /// После калибровки база совпадает с медианой целых поездок.
    func testSumOfSegmentMediansIsOptimisticAndCalibrationFixesIt() throws {
        let rows = history()
        let old = try oldBase(rows, minute: 480)
        let totals = rows.map { $0.seconds.reduce(0) { $0 + Double($1) } }.sorted()
        let wholeMedian = G.quantile(totals, 0.5)
        print("светофоры: сумма медиан \(Int(old.total)) с, медиана целых \(Int(wholeMedian)) с")
        XCTAssertLessThan(old.total, wholeMedian - 120, "сумма медиан оптимистичнее целых поездок на 2+ мин")

        let calibrated = try XCTUnwrap(G.baseline(ends: ends, limitKmh: [], rows: rows, calibrate: true))
        XCTAssertGreaterThan(calibrated.scale, 1.05)
        XCTAssertEqual(calibrated.total, wholeMedian, accuracy: 45, "база — медиана целых поездок")
    }

    // MARK: - Гипотеза (б): окно выезда

    /// Выезд 7:40 и 8:20: старые ступени ±60 берут одни и те же строки и
    /// дают один прогноз; ядро и калибровка — разные, и оба ближе к правде.
    func testEarlierDepartureForecastsEarlierArrival() throws {
        let rows = history()
        let (early, late) = (460, 500)
        let oldEarly = try oldBase(rows, minute: early).total
        let oldLate = try oldBase(rows, minute: late).total
        let newEarly = try newBase(rows, minute: early).total
        let newLate = try newBase(rows, minute: late).total
        let (truthEarly, truthLate) = (truth(departureMinute: early), truth(departureMinute: late))
        print("7:40 — было \(Int(oldEarly)) с, стало \(Int(newEarly)) с, правда \(Int(truthEarly)) с")
        print("8:20 — было \(Int(oldLate)) с, стало \(Int(newLate)) с, правда \(Int(truthLate)) с")
        XCTAssertEqual(oldEarly, oldLate, accuracy: 1, "ступени ±60: один прогноз на оба выезда")
        XCTAssertGreaterThan(newLate - newEarly, 180, "выехал раньше — приедешь быстрее")
        XCTAssertLessThan(abs(newLate - truthLate), abs(oldLate - truthLate))
        // В 7:40 старая база попадала случайно: оптимизм светофоров (−5 мин)
        // гасился пессимизмом смешанного окна (+5 мин). Новой это не нужно.
        XCTAssertLessThan(abs(newLate - truthLate), 90, "8:20 — ошибка меньше полутора минут")
        XCTAssertLessThan(abs(newEarly - truthEarly), 90, "7:40 — ошибка меньше полутора минут")
    }

    /// Систематический оптимизм уходит: на десяти разных историях средняя
    /// ошибка старой базы — минус (обещает раньше), новой — около нуля.
    func testSystematicOptimismIsGone() throws {
        var oldBias = 0.0, newBias = 0.0, oldAbs = 0.0, newAbs = 0.0
        let minutes = [455, 470, 485, 500, 515]
        let truths = minutes.map { truth(departureMinute: $0) }
        for seed in 1...10 {
            let rows = history(seed: UInt64(seed))
            for (minute, real) in zip(minutes, truths) {
                let old = try oldBase(rows, minute: minute).total - real
                let new = try newBase(rows, minute: minute).total - real
                oldBias += old
                newBias += new
                oldAbs += abs(old)
                newAbs += abs(new)
            }
        }
        let n = Double(10 * minutes.count)
        print("сдвиг прогноза: было \(Int(oldBias / n)) с, стало \(Int(newBias / n)) с; средняя ошибка: было \(Int(oldAbs / n)) с, стало \(Int(newAbs / n)) с")
        XCTAssertLessThan(oldBias / n, -120, "старая база обещала раньше на 2+ мин")
        XCTAssertLessThan(abs(newBias / n), 60, "новая — в пределах минуты")
        XCTAssertLessThan(newAbs, oldAbs / 2, "и ошибается вдвое меньше")
    }

    // MARK: - Механика

    func testWeightedQuantileEqualsLinearForEqualWeights() {
        let values = [3.0, 9, 1, 7, 5, 12]
        for q in [0.0, 0.25, 0.5, 0.75, 1.0] {
            XCTAssertEqual(G.weightedQuantile(values.map { ($0, 2.0) }, q), G.quantile(values.sorted(), q),
                           accuracy: 1e-9)
        }
        // Тяжёлая точка тянет медиану к себе.
        XCTAssertGreaterThan(G.weightedQuantile([(1, 1), (2, 1), (10, 5)], 0.5), 2)
    }

    /// В ядро легло меньше трёх «поездок» — прежние ступени, без весов.
    func testKernelFallsBackToTiers() throws {
        let rows = (0..<4).map { i in
            Row(tripID: Double(i), departure: date(day: weekdays[i], minute: 9 * 60 + 40), weekend: false,
                arrivalMinute: 0, seconds: [UInt16](repeating: 20, count: segments))
        }
        let selection = try XCTUnwrap(G.select(rows, weekend: false, departure: date(day: 26, minute: 485),
                                               calendar: utc))
        XCTAssertEqual(selection.tier, .twoHours)
        XCTAssertEqual(Set(selection.weights), [1])
        let near = try XCTUnwrap(G.select(rows, weekend: false, departure: date(day: 26, minute: 9 * 60 + 45),
                                          calendar: utc))
        XCTAssertEqual(near.tier, .hour, "рядом с выездами — ядро")
    }

    /// Свой день недели весит вдвое: понедельники медленнее — понедельник
    /// получает понедельничный прогноз, вторник — обычный.
    func testSameWeekdayWeighsMore() throws {
        var rows: [Row] = []
        for (i, day) in weekdays.prefix(20).enumerated() {
            let monday = utc.component(.weekday, from: date(day: day, minute: 480)) == 2
            rows.append(Row(tripID: Double(i), departure: date(day: day, minute: 480), weekend: false,
                            arrivalMinute: 0, seconds: [UInt16](repeating: monday ? 30 : 20, count: segments)))
        }
        // 22.02.2027 — понедельник, 23.02 — вторник.
        let monday = try XCTUnwrap(G.select(rows, weekend: false, departure: date(day: 22, minute: 480),
                                            calendar: utc))
        let tuesday = try XCTUnwrap(G.select(rows, weekend: false, departure: date(day: 23, minute: 480),
                                             calendar: utc))
        let mondayBase = try XCTUnwrap(G.baseline(ends: ends, limitKmh: [], rows: monday.rows,
                                                  weights: monday.weights, offsets: monday.offsets, calibrate: true))
        let tuesdayBase = try XCTUnwrap(G.baseline(ends: ends, limitKmh: [], rows: tuesday.rows,
                                                   weights: tuesday.weights, offsets: tuesday.offsets, calibrate: true))
        XCTAssertGreaterThan(mondayBase.total, tuesdayBase.total)
    }

    /// Калибровка ограничена: вдвое дольше суммы медиан — не светофоры, а
    /// другая дорога; множитель не больше 1,4.
    func testCalibrationIsBounded() {
        let median = [Double](repeating: 20, count: 10)
        let rows = (0..<5).map { i in
            Row(tripID: Double(i), departure: date(day: 1, minute: 480), weekend: false, arrivalMinute: 0,
                seconds: [UInt16](repeating: 40, count: 10))
        }
        XCTAssertEqual(G.calibration(rows: rows, weights: [], median: median), AppConfig.commuteCalibrationMax)
        XCTAssertEqual(G.calibration(rows: Array(rows.prefix(2)), weights: [], median: median), 1,
                       "две строки — не основание")
    }

    /// Поправка вниз не делает призрака быстрее лимита.
    func testCalibrationKeepsTheLimitFloor() throws {
        let rows = (0..<5).map { i in
            Row(tripID: Double(i), departure: date(day: 1, minute: 480), weekend: false, arrivalMinute: 0,
                seconds: [UInt16](repeating: 12, count: segments))
        }
        let base = try XCTUnwrap(G.baseline(ends: ends, limitKmh: [UInt8](repeating: 60, count: segments),
                                            rows: rows, calibrate: true, bias: 0.5))
        for m in base.median { XCTAssertGreaterThanOrEqual(m, 12 - 0.01) }
    }
}
