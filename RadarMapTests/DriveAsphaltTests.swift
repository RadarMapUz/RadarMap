//
//  DriveAsphaltTests.swift
//  RadarMapTests
//
//  Асфальт поездки (29.B): разница стиля в бандле разбирается целиком и
//  только в известные свойства цвета, ночная тема ничего не перекрашивает,
//  линия маршрута в поездке — ночным набором.
//

import XCTest
@testable import RadarMap

final class DriveAsphaltTests: XCTestCase {

    private func bundled(daylight: Bool) throws -> [DriveAsphalt.Override] {
        let name = DriveAsphalt.resource(daylight: daylight)
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "json")
            ?? Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "MapStyle"),
                                "\(name).json нет в бандле")
        return try DriveAsphalt.overrides(from: Data(contentsOf: url))
    }

    func testBundledDayDifferenceParsesIntoKnownColourKeys() throws {
        let day = try bundled(daylight: true)
        XCTAssertFalse(day.isEmpty, "днём асфальт поездки обязан отличаться")
        for item in day {
            XCTAssertEqual(DriveAsphalt.key(for: item.property), item.key)
        }
        // Полотно, кромки, площадь узла и имя улицы — среди правок.
        let layers = Set(day.map(\.layer))
        for id in ["radar-roads", "radar-roads-case", "radar-junction", "highway-name-major"] {
            XCTAssertTrue(layers.contains(id), id)
        }
        // Подписи дворов остаются тёмными на белом дворе.
        XCTAssertFalse(layers.contains("highway-name-minor"))
    }

    func testNightDrivesOnTheNightStyle() throws {
        XCTAssertTrue(try bundled(daylight: false).isEmpty)
    }

    func testUnknownPropertyRejectsTheWholeFile() {
        let data = Data(##"{"layers": {"radar-roads": {"line-color": "#000000", "line-width": 3}}}"##.utf8)
        XCTAssertThrowsError(try DriveAsphalt.overrides(from: data)) { error in
            XCTAssertEqual(error as? DriveAsphalt.Failure, .unknownProperty("line-width"))
        }
        XCTAssertThrowsError(try DriveAsphalt.overrides(from: Data("[]".utf8)))
    }

    func testOnlyColourPropertiesHaveKeys() {
        XCTAssertEqual(DriveAsphalt.key(for: "text-halo-color"), "textHaloColor")
        XCTAssertNil(DriveAsphalt.key(for: "line-width"))
        XCTAssertNil(DriveAsphalt.key(for: "visibility"))
    }

    func testCarDifferenceKeys() {
        // Разница машины (40J): земля, высота домов, сила свечения магистрали.
        XCTAssertEqual(DriveAsphalt.key(for: "background-color"), "backgroundColor")
        XCTAssertEqual(DriveAsphalt.key(for: "fill-extrusion-height"), "fillExtrusionHeight")
        XCTAssertEqual(DriveAsphalt.key(for: "line-opacity"), "lineOpacity")
        XCTAssertNil(DriveAsphalt.key(for: "text-size"), "кегль машины — EngineCarScale, не разница")
    }

    func testBareHexBecomesAColourOnly() {
        XCTAssertEqual(DriveAsphalt.colourHex("#3f4859"), 0x3F4859)
        XCTAssertNil(DriveAsphalt.colourHex("rgba(0,0,0,0.5)"))
        XCTAssertNil(DriveAsphalt.colourHex(["step", ["zoom"], "#000000", 15, "#ffffff"]))
        XCTAssertNil(DriveAsphalt.colourHex(0.5))
    }

    func testLightAcceptsOnlyIntensity() throws {
        XCTAssertNil(try DriveAsphalt.lightIntensity(from: Data(##"{"layers": {}}"##.utf8)))
        XCTAssertEqual(try DriveAsphalt.lightIntensity(from: Data(##"{"layers": {}, "light": {"intensity": 0.45}}"##.utf8)),
                       0.45)
        XCTAssertThrowsError(try DriveAsphalt.lightIntensity(
            from: Data(##"{"layers": {}, "light": {"intensity": 0.4, "color": "#fff"}}"##.utf8)))
        // Не число — ошибка файла, а не тихий пропуск.
        XCTAssertThrowsError(try DriveAsphalt.lightIntensity(
            from: Data(##"{"layers": {}, "light": {"intensity": "0.4"}}"##.utf8)))
    }

    func testFirstApplyAfterStyleLoadHasNoTransition() {
        // Машина кладёт разницу на каждую загрузку стиля: без перехода, иначе
        // 0,6 с телефонной палитры перетекают в машинную. Старт поездки на
        // показанной карте — с переходом.
        XCTAssertEqual(DriveAsphalt.transitionSeconds(firstAfterStyleLoad: true), 0)
        XCTAssertEqual(DriveAsphalt.transitionSeconds(firstAfterStyleLoad: false),
                       AppConfig.driveAsphaltTransitionSeconds)
        XCTAssertGreaterThan(AppConfig.driveAsphaltTransitionSeconds, 0)
    }

    func testRouteGoesNightOnlyInTheDriveMode() {
        XCTAssertTrue(DriveAsphalt.routeDaylight(daylight: true, active: false))
        XCTAssertFalse(DriveAsphalt.routeDaylight(daylight: true, active: true))
        XCTAssertFalse(DriveAsphalt.routeDaylight(daylight: false, active: false))
        XCTAssertFalse(DriveAsphalt.isActive(driving: true, modernStyle: false))
        XCTAssertTrue(DriveAsphalt.isActive(driving: true, modernStyle: true))
        XCTAssertFalse(DriveAsphalt.isActive(driving: false, modernStyle: true))
    }

    func testNightRouteHoldsOnTheDriveAsphalt() {
        // Копия чисел палитры поездки (make_style drive_*; palette_check сверяет
        // правило с генератором): светлое тело ночного маршрута ≥ 3:1 на
        // тёмном полотне, тёмная кайма — на светлом асфальте обзора.
        let drive: [UInt32] = [0x4B4F5A, 0x3F4859, 0x434C5E]
        for asphalt in drive {
            XCTAssertGreaterThanOrEqual(Self.contrast(RouteColors.body.night, asphalt), 3, String(asphalt, radix: 16))
        }
        XCTAssertGreaterThanOrEqual(Self.contrast(RouteColors.casing.night, 0xD2D6DD), 3)
        // Пройденное различимо на тёмном полотне (как RouteTraveledTests).
        for asphalt in drive {
            XCTAssertGreaterThan(Self.contrast(RouteColors.traveled.night, asphalt), 1.8)
        }
    }

    private static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
