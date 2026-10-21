//
//  EnergyIconsTests.swift
//  RadarMapTests
//
//  Значки «Машины и расходов» (21.10) существуют — и существуют на iOS 18,
//  на которой приложение запускается. Тесты идут на свежем симуляторе, где
//  есть всё; символ, появившийся позже 18.0, на телефоне владельца нарисовал
//  бы пустое место. Год появления символа берём из таблицы самой системы
//  (CoreGlyphs, name_availability.plist).
//

import UIKit
import XCTest
@testable import RadarMap

final class EnergyIconsTests: XCTestCase {
    private var symbols: [String] {
        VehicleEnergy.allCases.map { EnergyText.symbol($0) }
            + ChargeSchedule.allCases.map { EnergyText.scheduleSymbol($0) }
            + ChargePlace.allCases.map { EnergyText.placeSymbol($0) }
            + [SettingsItem.vehicle.symbol, "function", "list.bullet.clipboard", "gauge.with.dots.needle.33percent",
               "wrench.and.screwdriver.fill", "sun.max.fill", "road.lanes", "snowflake", "bolt.fill",
               "exclamationmark.circle", "checkmark.circle.fill", "circle", "chevron.down", "info.circle"]
    }

    func testEverySymbolExists() {
        for name in symbols {
            XCTAssertNotNil(UIImage(systemName: name), "нет символа \(name)")
        }
    }

    func testEverySymbolIsOnIOS18() throws {
        let path = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        let candidates = [root + path, path]
        guard let url = candidates.map(URL.init(fileURLWithPath:)).first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw XCTSkip("таблицы символов нет в этом окружении")
        }
        let table = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let plist = try XCTUnwrap(table as? [String: Any])
        let years = try XCTUnwrap(plist["symbols"] as? [String: String])
        let releases = try XCTUnwrap(plist["year_to_release"] as? [String: [String: String]])
        for name in symbols {
            let year = try XCTUnwrap(years[name], "\(name) нет в таблице")
            let iOS = try XCTUnwrap(releases[year]?["iOS"], "нет версии iOS для \(year)")
            XCTAssertNotEqual(iOS.compare("18.0", options: .numeric), .orderedDescending,
                              "\(name) — с iOS \(iOS), а приложение работает с 18.0")
        }
    }

    /// У типов машин — разные значки: на карточках выбора их различают глазом.
    func testVehicleSymbolsAreDistinct() {
        let all = VehicleEnergy.allCases.map { EnergyText.symbol($0) }
        XCTAssertEqual(Set(all).count, all.count)
    }
}
