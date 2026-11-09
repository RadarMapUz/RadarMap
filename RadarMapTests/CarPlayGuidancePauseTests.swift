//
//  CarPlayGuidancePauseTests.swift
//  RadarMapTests
//
//  Пауза ведения в машине (25.H1): перестроение старше поиска сигнала,
//  поиск сигнала — только после первого манёвра, снятие — на первом фиксе;
//  плашка «Нет сигнала GPS» не дублирует карточку системы.
//

import XCTest
@testable import RadarMap

final class CarPlayGuidancePauseTests: XCTestCase {

    private func wanted(rerouting: Bool = false, stale: Bool = false, maneuver: Bool = true,
                        enabled: Bool = true) -> CarPlayGuidancePause.Reason? {
        CarPlayGuidancePause.wanted(rerouting: rerouting, signalStale: stale, hasManeuver: maneuver,
                                    locatingEnabled: enabled)
    }

    func testLostSignalPausesForLocating() {
        XCTAssertEqual(wanted(stale: true), .locating)
        XCTAssertNil(wanted())
    }

    /// Старый поворот неверен при любом сигнале — перестроение важнее.
    func testReroutingOutranksLocating() {
        XCTAssertEqual(wanted(rerouting: true, stale: true), .rerouting)
        XCTAssertEqual(wanted(rerouting: true, stale: false), .rerouting)
    }

    /// До первого манёвра сессия стоит на «загружаю»: «ищу сигнал» снять было
    /// бы нечем, и карточка застряла бы на нём при живом сигнале.
    func testNoLocatingBeforeTheFirstManeuver() {
        XCTAssertNil(wanted(stale: true, maneuver: false))
        XCTAssertEqual(wanted(rerouting: true, maneuver: false), .rerouting)
    }

    /// iOS < 27 — как раньше: только перестроение.
    func testLocatingOffKeepsTheOldBehaviour() {
        XCTAssertNil(wanted(stale: true, enabled: false))
        XCTAssertEqual(wanted(rerouting: true, stale: true, enabled: false), .rerouting)
    }

    func testStepsBetweenStates() {
        XCTAssertEqual(CarPlayGuidancePause.step(current: nil, wanted: nil), .none)
        XCTAssertEqual(CarPlayGuidancePause.step(current: nil, wanted: .locating), .pause(.locating))
        XCTAssertEqual(CarPlayGuidancePause.step(current: .locating, wanted: .locating), .none,
                       "пауза не шлётся в машину на каждом тике")
        // Первый хороший фикс — снять.
        XCTAssertEqual(CarPlayGuidancePause.step(current: .locating, wanted: nil), .resume)
        // Сигнал пропал посреди перестроения и наоборот — сменить причину.
        XCTAssertEqual(CarPlayGuidancePause.step(current: .locating, wanted: .rerouting), .pause(.rerouting))
        XCTAssertEqual(CarPlayGuidancePause.step(current: .rerouting, wanted: .locating), .pause(.locating))
        XCTAssertEqual(CarPlayGuidancePause.step(current: .rerouting, wanted: nil), .resume)
    }

    func testGPSChipYieldsToTheSystemCard() {
        XCTAssertTrue(CarPlayGuidancePause.showsGPSChip(signalStale: true, systemLocating: false))
        XCTAssertFalse(CarPlayGuidancePause.showsGPSChip(signalStale: true, systemLocating: true))
        XCTAssertFalse(CarPlayGuidancePause.showsGPSChip(signalStale: false, systemLocating: false))
    }

    func testBuildingNewRoutePausesAsLoading() {
        func wanted(rerouting: Bool = false, building: Bool) -> CarPlayGuidancePause.Reason? {
            CarPlayGuidancePause.wanted(rerouting: rerouting, signalStale: false, hasManeuver: true,
                                        locatingEnabled: true, building: building)
        }
        XCTAssertEqual(wanted(building: true), .loading)
        XCTAssertEqual(wanted(rerouting: true, building: true), .rerouting)
        XCTAssertEqual(CarPlayGuidancePause.step(current: .loading, wanted: nil), .resume, "отмена возвращает манёвр")
    }
}
