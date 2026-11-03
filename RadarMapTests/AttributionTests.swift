//
//  AttributionTests.swift
//  RadarMapTests
//
//  Лицензии, которые обязаны ехать в сборке (28.F). Лицензия, которую нельзя
//  показать, — нарушение лицензии, и узнавать об этом из письма App Review
//  поздно: файл мог выпасть из бандла при переносе папок.
//

import XCTest
@testable import RadarMap

final class AttributionTests: XCTestCase {

    /// Каждый компонент читается из бандла приложения, и текст — дословный
    /// оригинал, а не пересказ: проверяем по ключевым фразам лицензий.
    func testEveryLicenseIsBundledVerbatim() throws {
        let mapLibre = try LicenseText.load(.mapLibre)
        XCTAssertTrue(mapLibre.contains("BSD 2-Clause License"))
        XCTAssertTrue(mapLibre.contains("Copyright (c) 2021 MapLibre contributors"))
        XCTAssertTrue(mapLibre.contains("Redistributions in binary form must reproduce the above copyright"))
        // Уведомления вшитых библиотек — именно их нет в xcframework.
        for library in ["Boost", "RapidJSON", "Metal-cpp", "FreeType", "HarfBuzz"] {
            XCTAssertTrue(mapLibre.contains(library), library)
        }

        let bright = try LicenseText.load(.osmBright)
        XCTAssertTrue(bright.contains("BSD 3-Clause License"))
        XCTAssertTrue(bright.contains("Copyright (c) 2014, Mapbox."))

        let noto = try LicenseText.load(.notoSans)
        XCTAssertTrue(noto.contains("SIL OPEN FONT LICENSE Version 1.1"))
        XCTAssertTrue(noto.contains("Copyright 2012 Google Inc."))
    }

    /// Подпись карты — та, что требует OpenMapTiles: обе ссылки на месте.
    func testMapSourcesLinkWhereLicensesAsk() {
        XCTAssertEqual(DataSource.map, [.openMapTiles, .openStreetMap])
        XCTAssertEqual(DataSource.openMapTiles.url.host(), "openmaptiles.org")
        XCTAssertEqual(DataSource.openStreetMap.url.absoluteString, "https://www.openstreetmap.org/copyright")
        XCTAssertEqual(DataSource.openMeteo.url.host(), "open-meteo.com")
        XCTAssertEqual(DataSource.openData.url.host(), "data.egov.uz")
        XCTAssertEqual(DataSource.wikipedia.url.host(), "ru.wikipedia.org")
    }

    /// В навигации угол занят кругом скорости — «i» встаёт над ним, а не под
    /// ним; в остальных режимах — прямо над нижней панелью.
    func testAttributionClearsSpeedClusterInNavigation() {
        XCTAssertEqual(MapAttributionPlacement.lift(speedPlacement: .bottomLeading, isAddingCamera: false),
                       AppConfig.mapAttributionSpeedLift)
        XCTAssertGreaterThanOrEqual(AppConfig.mapAttributionSpeedLift, 62 + 10, "круг скорости 62 pt + отступ")
        XCTAssertEqual(MapAttributionPlacement.lift(speedPlacement: .top, isAddingCamera: false), 0)
        XCTAssertEqual(MapAttributionPlacement.lift(speedPlacement: .bottomLeading, isAddingCamera: true), 0,
                       "при добавлении камеры круга скорости нет")
        XCTAssertEqual(MapMode.navigating.speedPlacement, .bottomLeading)
    }

    /// Абзацы режутся по пустым строкам, отступы и переносы внутри абзаца
    /// сохраняются — в тексте лицензии они значимы.
    func testBlocksSplitOnBlankLinesOnly() {
        let text = "Title\n\nline one\n  indented two\n\n\n   \nlast"
        XCTAssertEqual(LicenseText.blocks(text), ["Title", "line one\n  indented two", "last"])
        XCTAssertEqual(LicenseText.blocks(""), [])
    }

    /// Склеиваются только строки, оборванные по ширине; слова не теряются,
    /// короткие строки (копирайты) и пункты списка остаются отдельными.
    func testReflowJoinsOnlyWrappedLines() {
        let block = """
        Redistribution and use in source and binary forms, with or without
        modification, are permitted provided that the following conditions are
        met:
        """
        XCTAssertEqual(LicenseText.reflow(block),
                       "Redistribution and use in source and binary forms, with or without "
                       + "modification, are permitted provided that the following conditions are met:")

        let list = """
        * Redistributions of source code must retain the above copyright
          notice, this list of conditions and the following disclaimer.
        * Redistributions in binary form must reproduce the above copyright
          notice.
        """
        XCTAssertEqual(LicenseText.reflow(list).split(separator: "\n").count, 2)

        let copyrights = "Copyright (c) 2014, Mapbox.\nCopyright (c) 2024, MapTiler.com."
        XCTAssertEqual(LicenseText.reflow(copyrights), copyrights)

        // Ни одно слово настоящего текста не потеряно.
        let original = (try? LicenseText.load(.osmBright)) ?? ""
        let words = { (text: String) in text.split(whereSeparator: \.isWhitespace) }
        let reflowed = LicenseText.blocks(original).map(LicenseText.reflow).joined(separator: "\n\n")
        XCTAssertEqual(words(reflowed), words(original))
    }
}
