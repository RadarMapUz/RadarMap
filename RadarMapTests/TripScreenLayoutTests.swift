//
//  TripScreenLayoutTests.swift
//  RadarMapTests
//
//  Экран поездки после реальной езды (docs/plan_drive_ux_2026-10-07.md, п. 4–6):
//  что видно в навигации, где прибытие и когда «Поездка сохранена» свежая.
//

import XCTest
@testable import RadarMap

final class TripScreenLayoutTests: XCTestCase {

    // MARK: - Кнопки и скорость

    func testMapToolsGoToTheMenuOnlyWhileDriving() {
        XCTAssertFalse(MapMode.idle.keepsMapToolsInMenu, "на стоянке колонка как была")
        XCTAssertTrue(MapMode.driving.keepsMapToolsInMenu)
        XCTAssertTrue(MapMode.navigating.keepsMapToolsInMenu)
    }

    /// Верх в навигации — только манёвр; скорость уходит вниз влево.
    func testSpeedPlacement() {
        XCTAssertEqual(MapMode.idle.speedPlacement, .top)
        XCTAssertEqual(MapMode.driving.speedPlacement, .top)
        XCTAssertEqual(MapMode.navigating.speedPlacement, .bottomLeading)
    }

    // MARK: - Колонка справа: сколько кнопок помещается

    private let idleCandidates: [(TripScreenLayout.ColumnExtra, Int)] =
        [(.layers, 1), (.overview, 1), (.threeD, 1), (.zoom, 2)]

    /// Первый кадр, кромки ещё не измерены: показать всё, а не пустую колонку.
    func testUnmeasuredRoomShowsEverything() {
        let shown = TripScreenLayout.columnExtras(available: 0, fixed: 2, candidates: idleCandidates)
        XCTAssertEqual(shown, [.layers, .overview, .threeD, .zoom])
    }

    /// Большой экран: всё влезает.
    func testTallRoomShowsEverything() {
        let shown = TripScreenLayout.columnExtras(available: 600, fixed: 2, candidates: idleCandidates)
        XCTAssertEqual(shown, [.layers, .overview, .threeD, .zoom])
    }

    /// SE в покое с маршрутом: прежде зум и звук уходили под карточку
    /// маршрута. Теперь лишнее уходит по важности — зум первым (он и щипком).
    func testSmallRoomDropsTheLeastNeededFirst() {
        // 250 pt — четыре места по 56: два обязательных и ещё два.
        let shown = TripScreenLayout.columnExtras(available: 250, fixed: 2, candidates: idleCandidates)
        XCTAssertEqual(shown, [.layers, .overview])
        XCTAssertFalse(shown.contains(.zoom), "зум уходит первым")
    }

    /// Обязательные не прячутся: если места нет даже на них — нет только
    /// необязательных, сама колонка остаётся.
    func testNoRoomShowsOnlyTheRequired() {
        let shown = TripScreenLayout.columnExtras(available: 90, fixed: 2, candidates: idleCandidates)
        XCTAssertTrue(shown.isEmpty)
    }

    /// Зуму нужно два места: при одном свободном он не встаёт, а кнопка в
    /// одно место после него — встаёт.
    func testTwoSlotButtonDoesNotBlockSmallerOnes() {
        let shown = TripScreenLayout.columnExtras(available: 180, fixed: 2,
                                                  candidates: [(.zoom, 2), (.threeD, 1)])
        XCTAssertEqual(shown, [.threeD])
    }

    /// В поездке компас — единственная необязательная кнопка.
    func testTripCompassNeedsItsOwnSlot() {
        XCTAssertEqual(TripScreenLayout.columnExtras(available: 220, fixed: 3,
                                                     candidates: [(.compass, 1)]), [.compass])
        XCTAssertTrue(TripScreenLayout.columnExtras(available: 200, fixed: 3,
                                                    candidates: [(.compass, 1)]).isEmpty)
    }

    // MARK: - Прибытие

    /// Карточка прибытия стоит ВМЕСТО панели поездки: одна кнопка «завершить».
    func testArrivalReplacesTheTripBar() {
        let shown = TripScreenLayout.showsArrival(hasArrival: true, isTripActive: true,
                                                  showsTripEnd: false)
        XCTAssertTrue(shown)
        XCTAssertFalse(TripScreenLayout.showsTripBar(mode: .driving, arrivalShown: shown))
        XCTAssertFalse(TripScreenLayout.showsControlColumn(arrivalShown: shown,
                                                           isAddingCamera: false))
    }

    func testWithoutArrivalTheTripBarIsBack() {
        let shown = TripScreenLayout.showsArrival(hasArrival: false, isTripActive: true,
                                                  showsTripEnd: false)
        XCTAssertFalse(shown)
        XCTAssertTrue(TripScreenLayout.showsTripBar(mode: .driving, arrivalShown: shown))
        XCTAssertTrue(TripScreenLayout.showsTripBar(mode: .navigating, arrivalShown: shown))
        XCTAssertFalse(TripScreenLayout.showsTripBar(mode: .idle, arrivalShown: shown))
        XCTAssertTrue(TripScreenLayout.showsControlColumn(arrivalShown: shown,
                                                          isAddingCamera: false))
    }

    /// Поездка уже сохранена — итог показывает «Поездка сохранена», а не
    /// прибытие с теми же цифрами.
    func testArrivalYieldsToTripEndAfterTheTrip() {
        XCTAssertFalse(TripScreenLayout.showsArrival(hasArrival: true, isTripActive: false,
                                                     showsTripEnd: true))
        XCTAssertTrue(TripScreenLayout.showsArrival(hasArrival: true, isTripActive: false,
                                                    showsTripEnd: false))
    }

    // MARK: - Чип камеры

    func testCameraChipOnlyOnApproach() {
        XCTAssertFalse(TripScreenLayout.showsCameraChip(distance: 2_400, isAlerting: false,
                                                        isSignalStale: false))
        XCTAssertTrue(TripScreenLayout.showsCameraChip(distance: 600, isAlerting: false,
                                                       isSignalStale: false))
        XCTAssertTrue(TripScreenLayout.showsCameraChip(distance: 240, isAlerting: false,
                                                       isSignalStale: false))
        XCTAssertFalse(TripScreenLayout.showsCameraChip(distance: nil, isAlerting: false,
                                                        isSignalStale: false))
    }

    /// Камера уже говорит (трасса: радиус шире 600 м) — чип обязан быть.
    func testAlertAndLostSignalAlwaysShowTheChip() {
        XCTAssertTrue(TripScreenLayout.showsCameraChip(distance: 800, isAlerting: true,
                                                       isSignalStale: false))
        XCTAssertTrue(TripScreenLayout.showsCameraChip(distance: nil, isAlerting: false,
                                                       isSignalStale: true))
    }

    // MARK: - «Поездка сохранена»

    /// Характеризация бага: «после „Завершить“ поездка куда-то делась».
    /// Свежесть считалась по `endedAt` записи — это время последнего фикса, а
    /// на стоянке фиксы не приходят. Минута у подъезда — и карточка итога не
    /// показывалась, хотя поездка только что легла в историю.
    func testTripEndIsFreshBySaveTimeNotByLastFix() {
        let now = Date()
        let lastFix = now.addingTimeInterval(-180)   // три минуты стоим у подъезда
        XCTAssertFalse(now.timeIntervalSince(lastFix) < AppConfig.tripEndCardFreshSeconds,
                       "старое правило по endedAt молчало бы")
        XCTAssertTrue(TripScreenLayout.isTripEndFresh(savedAt: now.addingTimeInterval(-1),
                                                      now: now))
    }

    func testOldOrMissingSaveIsNotFresh() {
        let now = Date()
        XCTAssertFalse(TripScreenLayout.isTripEndFresh(savedAt: nil, now: now),
                       "короткая поездка не сохранилась — карточки нет")
        XCTAssertFalse(TripScreenLayout.isTripEndFresh(savedAt: now.addingTimeInterval(-120),
                                                       now: now))
        XCTAssertFalse(TripScreenLayout.isTripEndFresh(savedAt: now.addingTimeInterval(60),
                                                       now: now), "время из будущего не верим")
    }
}
