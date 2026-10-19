//
//  IconsTests.swift
//  RadarMapTests
//
//  Словарь значков (4.1): у каждого смысла свой символ, и каждый символ
//  существует в системе — опечатка в имени рисует пустое место молча.
//

import UIKit
import XCTest
@testable import RadarMap

final class IconsTests: XCTestCase {
    private let all = [Icon.reportRadar, Icon.hazard, Icon.ownCamera, Icon.cameras, Icon.myPlaces,
                       Icon.pointHere, Icon.pointGone, Icon.pointMisplaced, Icon.placesLayer, Icon.noCameras]

    func testEveryMeaningHasItsOwnSymbol() {
        XCTAssertEqual(Set(all).count, all.count, "два смысла на одном значке — путаница на дороге")
    }

    func testEverySymbolExists() {
        for name in all {
            XCTAssertNotNil(UIImage(systemName: name), "нет символа \(name)")
        }
    }

    /// «Радар!» — значок передвижного радара, а не треугольник опасности:
    /// то, что водитель отмечает, и то, что потом видит на карте, совпадают.
    func testReportRadarMatchesTheMobileRadarMarker() {
        XCTAssertEqual(Icon.reportRadar, CameraType.mobileRadar.symbolName)
        XCTAssertNotEqual(Icon.reportRadar, Icon.hazard)
    }

    /// Символы, которые жили в коде строкой и молча не существовали: кнопка
    /// «Камеры больше нет» (camera.slash.fill) и «Ждут ответа» в Итогах
    /// (envelope.badge.clock) рисовались с пустым местом (найдено 19.10).
    func testFormerlyMissingSymbolsAreReal() {
        XCTAssertNotNil(UIImage(systemName: "envelope.open.badge.clock"))
        XCTAssertNil(UIImage(systemName: "camera.slash.fill"), "если появится — можно вернуть, но не молча")
    }
}
