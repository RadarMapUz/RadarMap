//
//  MapViewStateTests.swift
//  RadarMapTests
//
//  Вид карты — общий для карты Apple и движка: масштаб кнопками, компас,
//  «моё местоположение». Кнопки на карте обязаны значить одно и то же на
//  любой подложке; здесь — правила, на которых это держится.
//

import XCTest
@testable import RadarMap

final class MapViewStateTests: XCTestCase {

    func testZoomButtonsShiftAutoZoomWithinBounds() {
        let map = MapState()
        for _ in 0..<10 { map.zoomStep(1) }
        XCTAssertEqual(map.zoomBias, 3, "приближение ограничено: автозум не теряется совсем")
        for _ in 0..<20 { map.zoomStep(-1) }
        XCTAssertEqual(map.zoomBias, -3)
        XCTAssertEqual(map.lastZoomDelta, -1)
        XCTAssertEqual(map.zoomCommand, 30, "каждое нажатие доходит до движка")
    }

    func testCompassAppearsOnlyWhenRotated() {
        let map = MapState()
        map.noteMapDirection(0)
        XCTAssertFalse(map.isRotated)
        map.noteMapDirection(1.5)
        XCTAssertFalse(map.isRotated, "дрожание у севера — не поворот")
        map.noteMapDirection(358.5)
        XCTAssertFalse(map.isRotated, "359° — тоже север")
        map.noteMapDirection(37)
        XCTAssertTrue(map.isRotated)
        XCTAssertEqual(map.displayedDirection, 40, "стрелка — шагом 10°")
    }

    func testDeviceCompassFollowCountsAsRotated() {
        let map = MapState()
        map.setMapHeading(nil)
        XCTAssertTrue(map.isRotated, "карту крутит компас телефона — компас нужен")
        map.setMapHeading(0)
        XCTAssertFalse(map.isRotated)
    }

    func testLocationButtonReturnsFromFreeThenTogglesHeading() {
        let map = MapState()
        map.releaseToFree()
        XCTAssertEqual(map.orientation, .free)
        map.cycleOrientation(coordinate: nil, course: -1, inTrip: false)
        XCTAssertEqual(map.orientation, .following, "1-й тап — к машине, север вверху")
        map.cycleOrientation(coordinate: nil, course: -1, inTrip: false)
        XCTAssertEqual(map.orientation, .heading, "2-й тап — по ходу движения")
    }

    func testCompassTapShowsNorthAndFollows() {
        let map = MapState()
        map.releaseToFree()
        map.showNorth(coordinate: nil, inTrip: true)
        XCTAssertEqual(map.orientation, .following)
        XCTAssertFalse(map.isRotated)
    }

    /// «К машине» из свободной карты в поездке — «по ходу», а не север, и
    /// это не ручной выбор: следующая поездка повернёт карту сама.
    func testRecenterInTripGoesHeadingUp() {
        XCTAssertEqual(MapState.recenterOrientation(lastTracking: .following, inTrip: true,
                                                    chosenByHand: false), .heading)
        XCTAssertEqual(MapState.recenterOrientation(lastTracking: .following, inTrip: false,
                                                    chosenByHand: false), .following)
        XCTAssertEqual(MapState.recenterOrientation(lastTracking: .following, inTrip: true,
                                                    chosenByHand: true), .following,
                       "север, выбранный рукой, — выбор человека")
    }

    func testRecenterDoesNotCountAsHandChoice() {
        let map = MapState()
        map.releaseToFree()
        map.cycleOrientation(coordinate: nil, course: -1, inTrip: true)
        XCTAssertEqual(map.orientation, .heading)
        XCTAssertFalse(map.orientationChosenByHand)
    }
}
