//
//  PassVerdict.swift
//  RadarMap
//
//  Три состояния проезда камеры — одно правило на все экраны «Итогов»
//  (аудит 05.11, вариант A).
//
//  До этого состояний было два, и они спорили с баллом: при +2…+5 км/ч
//  проезд рисовался зелёным «в лимите», итог поездки писал «Все камеры —
//  без превышения», календарь — «чисто», а балл поездки при этом был снят
//  (−2 или −8 по лестнице DrivingScore). Водитель видел 92 и не понимал, за
//  что. Третье состояние «на грани» называет ровно этот случай: штрафа
//  обычно нет, балл снят.
//
//  Границы не придуманы здесь, а взяты у движков, которые и так решают:
//    * «превышение» — есть штрафная ступень (FineSchedule.fine > 0);
//    * «на грани» — штрафа нет, но лестница баллов снимает (penaltyPoints > 0);
//    * «в лимите» — не снимает ничего.
//  Поэтому слово на экране не может разойтись ни с суммой штрафов, ни с баллом.
//
//  Чистая логика — PassVerdictTests.
//

import Foundation

nonisolated enum PassVerdict: Equatable, Sendable {
    /// Балл не снят.
    case clean
    /// Штрафа обычно нет, но балл снят.
    case edge
    /// Штрафуемое превышение.
    case over
    /// Лимит неизвестен — судить не по чему.
    case unknown

    static func of(speedKmh: Double, limitKmh: Int?) -> PassVerdict {
        guard let limitKmh else { return .unknown }
        let over = speedKmh - Double(limitKmh)
        if FineSchedule.fine(overKmh: over) > 0 { return .over }
        return DrivingScore.penaltyPoints(overKmh: over) > 0 ? .edge : .clean
    }

    /// Сколько км/ч сверх лимита (0 и меньше — не выше); nil — лимит неизвестен.
    static func excess(speedKmh: Double, limitKmh: Int?) -> Int? {
        limitKmh.map { Int((speedKmh - Double($0)).rounded()) }
    }

    // MARK: - Скорость на экране

    /// Знаков после запятой у скорости проезда: один — когда до границы «на
    /// грани» (+2) или «превышение» (+5) меньше 1 км/ч, иначе ноль. Вердикт
    /// судит по точной скорости, как балл и штраф (DrivingScore, FineSchedule),
    /// а целое «65» при лимите 60 бывало и жёлтым (64,6), и красным (65,4):
    /// у границы видно число, которое судили.
    static func speedDigits(speedKmh: Double, limitKmh: Int?) -> Int {
        guard let limitKmh else { return 0 }
        let over = speedKmh - Double(limitKmh)
        return [2.0, FineSchedule.toleranceKmh].contains { abs(over - $0) < 1 } ? 1 : 0
    }

    /// «65,4» / «70» — скорость проезда по правилу `speedDigits`, запятая по
    /// языку приложения.
    static func speedText(speedKmh: Double, limitKmh: Int?) -> String {
        Formatting.decimal(speedKmh, digits: speedDigits(speedKmh: speedKmh, limitKmh: limitKmh))
    }

    /// «5,4» — на сколько выше лимита, с теми же знаками; nil — лимит неизвестен.
    static func excessText(speedKmh: Double, limitKmh: Int?) -> String? {
        guard let limitKmh else { return nil }
        return Formatting.decimal(speedKmh - Double(limitKmh),
                                  digits: speedDigits(speedKmh: speedKmh, limitKmh: limitKmh))
    }

    /// Счёт проездов по состояниям.
    struct Tally: Equatable, Sendable {
        var clean = 0
        var edge = 0
        var over = 0
        var unknown = 0

        /// Проезды с известным лимитом — те, о которых есть что сказать.
        var judged: Int { clean + edge + over }

        /// Худшее состояние; nil — судить не по чему.
        var worst: PassVerdict? {
            if over > 0 { return .over }
            if edge > 0 { return .edge }
            if clean > 0 { return .clean }
            return nil
        }

        mutating func add(_ verdict: PassVerdict) {
            switch verdict {
            case .clean:   clean += 1
            case .edge:    edge += 1
            case .over:    over += 1
            case .unknown: unknown += 1
            }
        }
    }

    static func tally(_ passes: [PassedCamera]) -> Tally {
        tally(passes.map(\.verdict))
    }

    static func tally(_ verdicts: [PassVerdict]) -> Tally {
        var result = Tally()
        for verdict in verdicts { result.add(verdict) }
        return result
    }

    /// Состояние дня по счётчикам дневной строки: худшее из бывшего.
    /// nil — у камер с известным лимитом в этот день не проезжали.
    static func day(clean: Int, edge: Int, over: Int) -> PassVerdict? {
        Tally(clean: clean, edge: edge, over: over).worst
    }
}

extension PassedCamera {
    nonisolated var verdict: PassVerdict { PassVerdict.of(speedKmh: speedKmh, limitKmh: limitKmh) }
}

extension TripRecord {
    /// Камеры поездки по трём состояниям — одна строка «в лимите 5 · на грани 1».
    nonisolated var cameraTally: PassVerdict.Tally { PassVerdict.tally(passed) }
}
