//
//  MapViewportTests.swift
//  RadarMapTests
//
//  Кадр карты: «я» на своей доле ВИДИМОГО прямоугольника и кэш окрестной
//  сети (ритм анимации — TickPacingTests). Остаток прежних
//  RoadSketchTests: геометрию схемы дороги (удалена 11.10) вычистили 19.10
//  вместе с её тестами.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class MapViewportTests: XCTestCase {

    private let me = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.25)

    func testMeStandsInsideTheVisibleRect() {
        // «Я» держится на своей доле ВИДИМОГО, а не экрана: иначе с высокой
        // карточкой стрелка уезжает к нижней панели и впереди видно меньше,
        // чем позади.
        for top in [0.0, 0.17, 0.26] {
            let insets = MapViewport.Insets(top: top, bottom: 0.08)
            XCTAssertGreaterThan(insets.meY, insets.safeTop)
            XCTAssertLessThan(insets.meY, 1 - insets.safeBottom)
            let share = (insets.meY - insets.safeTop) / insets.visible
            XCTAssertEqual(share, MapViewport.meY, accuracy: 1e-9,
                           "доля «я» внутри видимого обязана быть одной и той же")
        }
    }

    /// Считает обращения к настоящему источнику. Только для тестов и только
    /// с одного потока — потому и @unchecked.
    private final class CountingNetwork: RoadNetworkSource, @unchecked Sendable {
        var calls = 0
        func roads(near coordinate: CLLocationCoordinate2D,
                   radius: CLLocationDistance) -> [RoadLine] {
            calls += 1
            return []
        }
    }

    func testCachedNetworkQueriesOncePerNeighbourhood() {
        // Два километра пути тиками по 20 м. Без кэша — сто сеточных запросов,
        // с кэшем — раз в ~200 м (полуторный запас на радиусе 400 м).
        let counting = CountingNetwork()
        let cached = CachedRoadNetwork(counting)
        for tick in 0..<100 {
            _ = cached.roads(near: .init(latitude: me.latitude + Double(tick) * 20 / 111_320,
                                         longitude: me.longitude),
                             radius: 400)
        }
        XCTAssertLessThan(counting.calls, 15,
                          "кэш окрестности обязан гасить подавляющую часть запросов")
        XCTAssertGreaterThan(counting.calls, 1,
                             "но по мере движения — честно обновляться")
    }
}
