//
//  CarMapStyleTests.swift
//  RadarMapTests
//
//  Стиль карты в машине (40J): A по умолчанию и в релизе, B — только ключом
//  запуска; разницы машины в бандле разбираются целиком; линия маршрута на
//  тёмном асфальте — ночным набором; новые цвета поверх карты держат
//  контраст и не красные; приборка и телефон стиля машины не получают.
//

import XCTest
@testable import RadarMap

final class CarMapStyleTests: XCTestCase {

    private func bundled(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "json")
            ?? Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "MapStyle"),
                                "\(name).json нет в бандле")
        return try Data(contentsOf: url)
    }

    func testLaunchKeyPicksTheLightVariantOnly() {
        XCTAssertEqual(CarMapStyle.launchChoice(arguments: []), .a)
        XCTAssertEqual(CarMapStyle.launchChoice(arguments: ["app", "-carMapStyle", "B"]), .b)
        XCTAssertEqual(CarMapStyle.launchChoice(arguments: ["-carMapStyle", "b"]), .b)
        XCTAssertEqual(CarMapStyle.launchChoice(arguments: ["-carMapStyle", "C"]), .a, "неизвестный — A")
        XCTAssertEqual(CarMapStyle.launchChoice(arguments: ["-carMapStyle"]), .a)
    }

    func testCarAndDashboardGetTheCarStyleClusterDoesNot() {
        XCTAssertNotNil(CarMapStyle.style(for: .car))
        XCTAssertNotNil(CarMapStyle.style(for: .dashboard))
        XCTAssertNil(CarMapStyle.style(for: .cluster))
        XCTAssertNil(CarMapStyle.scale(for: .cluster))
    }

    func testResourcesShareTheNight() {
        XCTAssertEqual(CarMapStyle.a.resource(daylight: true), "map_car_light")
        XCTAssertEqual(CarMapStyle.b.resource(daylight: true), "map_car_b_light")
        XCTAssertEqual(CarMapStyle.a.resource(daylight: false), "map_car_dark")
        XCTAssertEqual(CarMapStyle.b.resource(daylight: false), "map_car_dark")
    }

    func testBundledCarDifferencesParse() throws {
        for style in CarMapStyle.allCases {
            for daylight in [true, false] {
                let name = style.resource(daylight: daylight)
                let data = try bundled(name)
                let items = try DriveAsphalt.overrides(from: data)
                XCTAssertFalse(items.isEmpty, name)
                _ = try DriveAsphalt.lightIntensity(from: data)
                let layers = Set(items.map(\.layer))
                // Разница не трогает камеры, маршрут и пробки — их нет в стиле
                // файла вовсе, но и случайно попасть им туда нельзя.
                for id in layers {
                    XCTAssertFalse(id.hasPrefix("camera"), "\(name): \(id)")
                    XCTAssertFalse(id.hasPrefix("route"), "\(name): \(id)")
                    XCTAssertFalse(id.hasPrefix("traffic"), "\(name): \(id)")
                }
                // Голые строки в разнице — только цвета «#rrggbb»: другие
                // строки движок принял бы за текст и упал бы на mgl_color.
                for item in items {
                    if let text = item.value as? String {
                        XCTAssertNotNil(DriveAsphalt.colourHex(text), "\(name): \(item.layer).\(item.property) = \(text)")
                    }
                }
            }
        }
    }

    func testDayAOverridesAsphaltAndLightNightAddsNoLight() throws {
        let day = try bundled(CarMapStyle.a.resource(daylight: true))
        let layers = Set(try DriveAsphalt.overrides(from: day).map(\.layer))
        for id in ["radar-roads", "radar-junction", "highway-name-major", "building-3d", "background"] {
            XCTAssertTrue(layers.contains(id), id)
        }
        XCTAssertEqual(try DriveAsphalt.lightIntensity(from: day), 0.45)
        XCTAssertNil(try DriveAsphalt.lightIntensity(from: try bundled("map_car_dark")))
    }

    func testRouteThemeFollowsTheAsphalt() {
        // A днём — тёмный асфальт: линия ночным набором; B днём — дневным.
        XCTAssertFalse(CarMapStyle.a.routeDaylight(daylight: true, active: true))
        XCTAssertTrue(CarMapStyle.b.routeDaylight(daylight: true, active: true))
        XCTAssertFalse(CarMapStyle.b.routeDaylight(daylight: false, active: true))
        XCTAssertTrue(CarMapStyle.a.routeDaylight(daylight: true, active: false))
    }

    func testNightIsCalmer() {
        // N1: свечение маршрута и пятно под машиной слабее телефонных.
        for style in CarMapStyle.allCases {
            XCTAssertLessThan(style.glowOpacity(daylight: false), RouteColors.glowOpacity.night)
        }
        XCTAssertEqual(CarMapStyle.b.glowOpacity(daylight: true), 0, "B днём — без свечения")
        let night = CarMapStyle.a.compass(daylight: false)
        XCTAssertNotNil(night)
        XCTAssertLessThan(night?.poolAlpha ?? 1, Double(AppConfig.compassPoolAlpha))
        XCTAssertEqual(night?.letters, false, "в машине кольцо без букв")
        XCTAssertNil(CarMapStyle.b.compass(daylight: true), "B — без кольца")
        XCTAssertEqual(CompassRing.Look.phone.letters, true, "телефон — с буквами, как был")
    }

    func testScalesAreLargerOnTheCarThanOnTheTile() throws {
        let car = try XCTUnwrap(CarMapStyle.scale(for: .car))
        let tile = try XCTUnwrap(CarMapStyle.scale(for: .dashboard))
        XCTAssertGreaterThan(car.streets, tile.streets)
        XCTAssertGreaterThan(tile.streets, 1)
        XCTAssertGreaterThan(car.route, 1.3, "маршрут не ниткой на проспекте")
        XCTAssertEqual(tile.route, 1)
    }

    func testDashboardTileIsLowAndHouseless() {
        XCTAssertLessThanOrEqual(CarPlaySurface.dashboard.maxPitch, 30)
        XCTAssertFalse(CarPlaySurface.dashboard.houses(setting: true))
        XCTAssertEqual(CarPlaySurface.car.maxPitch, AppConfig.engineMapPitchDegrees)
    }

    // MARK: - Цвета поверх карты

    func testDayCameraLabelReadsOnTheDriveAsphalt() throws {
        let label = try XCTUnwrap(CarMapStyle.a.cameraLabel(daylight: true, active: true))
        // Ореол — асфальт проспекта поездки (make_style drive_primary).
        XCTAssertEqual(label.halo, 0x3F4859)
        XCTAssertGreaterThanOrEqual(Self.contrast(label.text, label.halo), 4.5)
        // Светлота текста — как имя улицы на том же асфальте, не красный.
        XCTAssertGreaterThan(Self.deltaE(label.text, 0xD93025), 40)
        XCTAssertNil(CarMapStyle.a.cameraLabel(daylight: false, active: true), "ночью — как в стиле")
        XCTAssertNil(CarMapStyle.b.cameraLabel(daylight: true, active: true), "B днём — светлая карта")
    }

    func testNorthMarkIsBlueNotRed() {
        // Метка севера на кольце видна и на тёмном асфальте, и на светлой
        // земле (с тёмной кромкой), и это не красный камеры.
        let north = CompassRing.northRGB
        XCTAssertGreaterThanOrEqual(Self.contrast(north, 0x3F4859), 3)
        XCTAssertGreaterThanOrEqual(Self.contrast(north, 0x383D46), 3)
        XCTAssertGreaterThan(Self.deltaE(north, 0xD93025), 40)
    }

    func testRouteHoldsOnTheCarAsphalt() {
        // Копия асфальта машины (make_style CAR_PALETTES; palette_check
        // .measure_car сверяет то же на генераторе): тело ночной линии ≥ 3:1.
        for asphalt: UInt32 in [0x504B43, 0x3F4859, 0x434C5E, 0x383D46, 0x33373F, 0x30343B] {
            XCTAssertGreaterThanOrEqual(Self.contrast(RouteColors.body.night, asphalt), 3, String(asphalt, radix: 16))
        }
        // Магистраль машины — тёплый графит: не похожа на проспект.
        XCTAssertGreaterThanOrEqual(Self.deltaE(0x504B43, 0x3F4859), 12)
        XCTAssertGreaterThanOrEqual(Self.deltaE(0x504B43, 0x383D46), 12)
    }

    // MARK: - Формулы (как PaletteTests)

    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func channels(_ hex: UInt32) -> (Double, Double, Double) {
        (linear(Double((hex >> 16) & 0xFF) / 255), linear(Double((hex >> 8) & 0xFF) / 255),
         linear(Double(hex & 0xFF) / 255))
    }

    private static func luminance(_ hex: UInt32) -> Double {
        let (r, g, b) = channels(hex)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func deltaE(_ a: UInt32, _ b: UInt32) -> Double {
        func lab(_ hex: UInt32) -> (Double, Double, Double) {
            let (r, g, b) = channels(hex)
            let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
            func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
            return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        let (l1, a1, b1) = lab(a), (l2, a2, b2) = lab(b)
        return ((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2)).squareRoot()
    }
}
