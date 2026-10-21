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
                       Icon.pointHere, Icon.pointGone, Icon.pointMisplaced, Icon.placesLayer, Icon.buildingsLayer,
                       Icon.noCameras, Icon.trafficLayer, Icon.sidewalksLayer, Icon.zoomButtons,
                       Icon.alertSignal, Icon.vibration, Icon.noGPSSignal, Icon.noLocationAccess]

    /// Значки меню на карте и плашки GPS (20.10) — вместе с теми, что не
    /// живут в словаре: шкала голоса, шапка и кнопка слоёв.
    @MainActor private var menuSymbols: [String] {
        [Icon.trafficLayer, Icon.placesLayer, Icon.buildingsLayer, Icon.sidewalksLayer, Icon.zoomButtons,
         Icon.alertSignal, Icon.vibration, Icon.noGPSSignal, Icon.noLocationAccess,
         "square.3.layers.3d", "xmark.circle.fill", "checkmark.circle.fill", "circle"]
            + VoiceMode.allCases.map(\.symbol)
    }

    func testEveryMeaningHasItsOwnSymbol() {
        XCTAssertEqual(Set(all).count, all.count, "два смысла на одном значке — путаница на дороге")
    }

    func testEverySymbolExists() {
        for name in all {
            XCTAssertNotNil(UIImage(systemName: name), "нет символа \(name)")
        }
    }

    /// Каждый значок меню существует и на iOS 18 — цели сборки, а не только
    /// на iOS 26 симулятора: символ новее цели рисуется у людей пустым местом,
    /// а `UIImage(systemName:)` на свежем симуляторе этого не покажет. Год
    /// появления символа — из таблицы SF Symbols самой системы.
    @MainActor func testMenuSymbolsExistOnTheDeploymentTarget() throws {
        let availability = try Self.symbolAvailability()
        for name in menuSymbols {
            XCTAssertNotNil(UIImage(systemName: name), "нет символа \(name)")
            let ios = try XCTUnwrap(availability[name], "символа \(name) нет в таблице SF Symbols")
            XCTAssertNotEqual(ios.compare("18.0", options: .numeric), .orderedDescending,
                              "\(name) появился в iOS \(ios) — новее цели сборки 18.0")
        }
    }

    /// Шкала голоса — три разных значка, и ни один не совпадает с сигналом
    /// («Звук») рядом: до 20.10 «Обо всех» и «Звук» были одним динамиком, а
    /// «Умно» — волшебной палочкой.
    @MainActor func testVoiceScaleIsDistinctFromTheSignalToggle() {
        let voice = VoiceMode.allCases.map(\.symbol)
        XCTAssertEqual(Set(voice).count, voice.count)
        XCTAssertFalse(voice.contains(Icon.alertSignal))
        XCTAssertFalse(voice.contains("wand.and.stars"), "палочка значит «авто», а не голос")
    }

    /// Один выбор звука — один значок на телефоне и в машине.
    @MainActor func testCarPlaySoundListUsesThePhoneSymbols() {
        XCTAssertEqual(CarPlaySoundChoice.all.symbol, VoiceMode.always.symbol)
        XCTAssertEqual(CarPlaySoundChoice.smart.symbol, VoiceMode.smart.symbol)
        XCTAssertEqual(CarPlaySoundChoice.silent.symbol, VoiceMode.off.symbol)
        XCTAssertEqual(CarPlaySoundChoice.beepOnly.symbol, Icon.alertSignal)
    }

    /// «Нет сигнала» и «нет доступа» — разные причины и разные значки;
    /// сигнал — не стрелкой геопозиции (читалась самолётом, 21.10).
    func testNoSignalIsNotTheLocationArrow() {
        XCTAssertNotEqual(Icon.noGPSSignal, Icon.noLocationAccess)
        XCTAssertFalse(Icon.noGPSSignal.hasPrefix("location"))
    }

    /// Таблица «символ → версия iOS» из CoreGlyphs симулятора: тот же файл,
    /// по которому приложение SF Symbols показывает доступность.
    private static func symbolAvailability() throws -> [String: String] {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        let candidates = [
            root + "/System/Library/PrivateFrameworks/SFSymbols.framework/CoreGlyphs.bundle/name_availability.plist",
            root + "/System/Library/CoreServices/CoreGlyphs.bundle/name_availability.plist",
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("таблица доступности SF Symbols не найдена — только на симуляторе")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let symbols = try XCTUnwrap(plist["symbols"] as? [String: String])
        let releases = try XCTUnwrap(plist["year_to_release"] as? [String: [String: String]])
        return symbols.compactMapValues { releases[$0]?["iOS"] }
    }

    /// «Радар!» — значок передвижного радара, а не треугольник опасности:
    /// то, что водитель отмечает, и то, что потом видит на карте, совпадают.
    func testReportRadarMatchesTheMobileRadarMarker() {
        XCTAssertEqual(Icon.reportRadar, CameraType.mobileRadar.symbolName)
        XCTAssertNotEqual(Icon.reportRadar, Icon.hazard)
    }

    /// «На месте / нет» — не печать с галочкой: она уже значит «в лимите» и
    /// достижения в «Итогах» (ревью 4.1).
    func testPointAnswersDoNotReuseTheInLimitSeal() {
        XCTAssertNotEqual(Icon.pointHere, "checkmark.seal.fill")
        XCTAssertNotEqual(Icon.pointGone, "xmark.seal.fill")
    }

    /// Символы, которые жили в коде строкой и молча не существовали: кнопка
    /// «Камеры больше нет» (camera.slash.fill) и «Ждут ответа» в Итогах
    /// (envelope.badge.clock) рисовались с пустым местом (найдено 19.10).
    func testFormerlyMissingSymbolsAreReal() {
        XCTAssertNotNil(UIImage(systemName: "envelope.open.badge.clock"))
        XCTAssertNil(UIImage(systemName: "camera.slash.fill"), "если появится — можно вернуть, но не молча")
    }
}
