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
