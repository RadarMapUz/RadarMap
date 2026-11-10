//
//  UnifiedPaletteTests.swift
//  RadarMapTests
//
//  Единая палитра (10.11): всё приложение стоит на токенах Theme, а не на
//  сырых цветах экранов. Линт по образцу MotionTests ловит новый сырой цвет,
//  остальное — что сведённые места держат свои роли: белый знак на значке
//  карты читается, ничто кроме камеры не красное, ночь не неоновая, а
//  числа стиля движка и моделей взяты из того же источника, что Theme.
//

import SwiftUI
import XCTest
@testable import RadarMap

final class UnifiedPaletteTests: XCTestCase {

    // MARK: - Линт

    /// Файлы, где сырой цвет законен, — с причиной.
    private let rawColourExceptions: [String: String] = [
        "Shared/WidgetPalette.swift": "источник чисел палитры для виджетов и часов",
    ]

    private let rawColourPatterns = ["Color(red:", "Color(hex", "UIColor(red:", "Color(hue:", "UIColor(hue:",
                                     "Color(.sRGB", "rgb(0x", "adaptive(0x"]

    /// Сырой цвет вне DesignSystem/ — мимо палитры: такой цвет не проверит ни
    /// один тест контраста, и экран снова заживёт своим оттенком.
    func testNoRawColoursRemainInSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RadarMapTests
            .deletingLastPathComponent()      // корень проекта
        var offenders: [String] = []
        var scanned = 0
        for folder in ["RadarMap", "RadarMapWidgets", "RadarWatch", "RadarWatchWidgets", "Shared"] {
            let base = root.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                if relative.hasPrefix("RadarMap/DesignSystem/") || rawColourExceptions[relative] != nil { continue }
                scanned += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//") else { continue }
                    if rawColourPatterns.contains(where: { code.contains($0) }) {
                        offenders.append("\(relative):\(index + 1)")
                    }
                }
            }
        }
        try XCTSkipIf(scanned == 0, "исходники не найдены — тест запущен вне дерева проекта")
        XCTAssertTrue(offenders.isEmpty, "сырой цвет мимо Theme: " + offenders.joined(separator: ", "))
    }

    // MARK: - Значки карты

    /// Белый знак на каждой заливке значка карты — ≥ 4,5:1, и ни одна
    /// заливка не читается красным камеры (ΔE ≥ 25).
    func testMapIconFillsCarryWhiteAndAreNotTheCameraRed() {
        let fills: [(String, UInt32)] = [
            ("graphite", MapIconColors.graphite), ("accentFill", MapIconColors.accentFill),
            ("warning", MapIconColors.warning), ("success", MapIconColors.success),
            ("ghost", MapIconColors.ghost), ("stopSign", MapIconColors.stopSign),
        ]
        for (name, fill) in fills {
            XCTAssertGreaterThanOrEqual(contrast(0xFFFFFF, fill), 4.5, "белый на \(name)")
            XCTAssertGreaterThanOrEqual(deltaE(fill, CameraGlyph.camera.fillRGB), 25, "\(name) ≈ камера")
        }
        XCTAssertGreaterThanOrEqual(contrast(MapIconColors.signalDot, MapIconColors.graphite), 3, "огни светофора")
        XCTAssertGreaterThanOrEqual(contrast(MapIconColors.ink, 0xFFFFFF), 4.5, "подпись на белой пилюле")
    }

    /// Значки карты — те же токены, что интерфейс (дневные значения: растр
    /// один на обе темы).
    func testMapIconsAreTheThemeTokens() {
        XCTAssertEqual(MapIconColors.accentFill, hex(Theme.accentFill, .light))
        XCTAssertEqual(MapIconColors.warning, hex(Theme.warning, .light))
        XCTAssertEqual(MapIconColors.success, hex(Theme.successFill, .light))
        XCTAssertEqual(MapIconColors.ink, hex(Theme.textPrimary, .light))
        XCTAssertEqual(MapIconColors.ghost, hex(Theme.Types.post, .light))
    }

    // MARK: - Один источник

    /// Числа стиля движка и моделей с тем же смыслом, что токены, взяты из
    /// того же источника — а не свои почти такие же.
    func testEngineAndModelColoursComeFromTheTokens() {
        XCTAssertEqual(EngineMapStyle.hotspotHex, RouteColors.hex(hex(Theme.warning, .dark)), "зона треноги — warning")
        XCTAssertEqual(CompassRing.northRGB, hex(Theme.accent, .dark), "север — accent")
        XCTAssertEqual(Drive3D.day.fill, hex(Theme.route, .light), "лента 3D днём — маршрут")
        XCTAssertEqual(Drive3D.night.fill, hex(Theme.accentFill, .dark), "лента 3D ночью — accentFill")
        XCTAssertEqual(CameraZone.Colors.day.hex, hex(Theme.Types.camera, .light), "зона камеры — красный камеры")
        XCTAssertEqual(CameraMarkerLook.calmNightInkRGB, hex(Theme.alertSurface, .dark))
    }

    // MARK: - Гармония

    /// Ночь без неона: ни один цвет интерфейса, «Итогов» и пробок ночью не
    /// насыщеннее OKLCH C 0,18 (состояния — ≤ 0,165). До 10.11 концы колец
    /// «риск» и «пробег» были 0,20–0,25 — кислотнее красного камеры.
    func testNightIsNotNeon() {
        var night: [(String, UInt32)] = [
            ("accent", hex(Theme.accent, .dark)), ("warning", hex(Theme.warning, .dark)),
            ("danger", hex(Theme.danger, .dark)), ("success", hex(Theme.success, .dark)),
            ("route", hex(Theme.route, .dark)),
            ("commute", hex(Theme.Stats.commute, .dark)), ("commuteTop", hex(Theme.Stats.commuteTop, .dark)),
            ("commuteText", hex(Theme.Stats.commuteText, .dark)), ("other", hex(Theme.Stats.other, .dark)),
            ("otherTop", hex(Theme.Stats.otherTop, .dark)), ("otherText", hex(Theme.Stats.otherText, .dark)),
        ]
        for (name, ring) in [("calm", WidgetPalette.ringCalm), ("watch", WidgetPalette.ringWatch),
                             ("risk", WidgetPalette.ringRisk), ("road", WidgetPalette.ringRoad)] {
            night += ring.dark.map { ("ring \(name)", $0) }
        }
        let c = TrafficPalette.active
        night += [("free", c.free.night), ("slow", c.slow.night), ("jam", c.jam.night), ("stand", c.stand.night)]
        for (name, value) in night {
            XCTAssertLessThanOrEqual(oklchChroma(value), 0.18, "\(name) ночью — неон (#\(String(value, radix: 16)))")
        }
    }

    /// Подписи «Итогов» — текст (≥ 4,5:1 на карточке и фоне), столбики —
    /// графика (≥ 3:1 на карточке), в обеих темах.
    func testStatsColoursAreReadable() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let theme = style == .light ? "днём" : "ночью"
            let surface = hex(Theme.surface, style), background = hex(Theme.background, style)
            for (name, colour) in [("commuteText", Theme.Stats.commuteText), ("otherText", Theme.Stats.otherText)] {
                XCTAssertGreaterThanOrEqual(contrast(hex(colour, style), surface), 4.5, "\(name) на карточке \(theme)")
                XCTAssertGreaterThanOrEqual(contrast(hex(colour, style), background), 4.5, "\(name) на фоне \(theme)")
            }
            for (name, colour) in [("commute", Theme.Stats.commute), ("other", Theme.Stats.other)] {
                XCTAssertGreaterThanOrEqual(contrast(hex(colour, style), surface), 3, "\(name) на карточке \(theme)")
            }
        }
    }

    /// Календарь колец следует теме (до 10.11 был прибит тёмным и днём
    /// оставался чёрным листом): подложка — карточка темы, дуги ≥ 3:1 к ней,
    /// числа дней и подписи ≥ 4,5:1, «сегодня» — onAction на жёлтом.
    func testRingsCalendarFollowsTheTheme() {
        let rings: [(String, [Color])] = [("calm", Theme.Stats.ringCalm), ("watch", Theme.Stats.ringWatch),
                                          ("risk", Theme.Stats.ringRisk), ("road", Theme.Stats.ringRoad)]
        for style in [UIUserInterfaceStyle.light, .dark] {
            let theme = style == .light ? "днём" : "ночью"
            let ground = hex(Theme.Stats.ringGround, style)
            XCTAssertEqual(ground, hex(Theme.surface, style), "подложка календаря \(theme)")
            for (name, colours) in rings {
                for colour in colours {
                    XCTAssertGreaterThanOrEqual(contrast(hex(colour, style), ground), 3, "кольцо \(name) \(theme)")
                }
            }
            for (name, colour) in [("primary", Theme.textPrimary), ("secondary", Theme.textSecondary),
                                   ("tertiary", Theme.textTertiary)] {
                XCTAssertGreaterThanOrEqual(contrast(hex(colour, style), ground), 4.5, "\(name) \(theme)")
            }
            XCTAssertGreaterThanOrEqual(contrast(hex(Theme.onAction, style), hex(Theme.action, style)), 4.5,
                                        "«сегодня» \(theme)")
        }
        XCTAssertGreaterThan(luminance(hex(Theme.Stats.ringGround, .light)), 0.8, "днём подложка светлая")
        XCTAssertLessThan(luminance(hex(Theme.Stats.ringGround, .dark)), 0.05, "ночью — графит")
    }

    /// Тёмными при любой теме прибиты только тревога, шеринг, заставка
    /// CarPlay и плашка поездки — лист данных следует теме приложения.
    func testOnlyAlertsAndSharingPinTheDarkScheme() throws {
        let allowed: Set<String> = [
            "RadarMap/Features/Map/ApproachAlertView.swift", "RadarMap/Features/Map/MapTickGates.swift",
            "RadarMap/Features/Map/AlertSampleView.swift", "RadarMap/DesignSystem/ShareCardShell.swift",
            "RadarMap/Features/Map/CarPlayHandoffView.swift", "RadarMapWidgets/CameraActivityWidget.swift",
        ]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        var scanned = 0
        for folder in ["RadarMap", "RadarMapWidgets", "RadarWatch", "Shared"] {
            let files = FileManager.default.enumerator(at: root.appendingPathComponent(folder),
                                                       includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                scanned += 1
                guard !allowed.contains(relative) else { continue }
                let text = try String(contentsOf: file, encoding: .utf8)
                if text.contains("colorScheme, .dark)") || text.contains("preferredColorScheme(.dark)") {
                    offenders.append(relative)
                }
            }
        }
        try XCTSkipIf(scanned == 0, "исходники не найдены — тест запущен вне дерева проекта")
        XCTAssertTrue(offenders.isEmpty, "тёмная тема прибита мимо списка: " + offenders.joined(separator: ", "))
    }

    /// Уровни пробок не путаются с заливками значков: ΔE ≥ 40 к красному
    /// камеры и ≥ 30 к посту, ДТП и «прочему» — в обеих темах.
    func testTrafficLevelsAreNotCameraTypes() {
        let c = TrafficPalette.active
        let levels: [(String, UInt32)] = [
            ("free", c.free.day), ("slow", c.slow.day), ("jam", c.jam.day), ("stand", c.stand.day),
            ("free", c.free.night), ("slow", c.slow.night), ("jam", c.jam.night), ("stand", c.stand.night),
        ]
        for (name, level) in levels {
            XCTAssertGreaterThanOrEqual(deltaE(level, CameraGlyph.camera.fillRGB), 40, "\(name) ≈ камера")
            for glyph in [CameraGlyph.post, .accident, .other] {
                XCTAssertGreaterThanOrEqual(deltaE(level, glyph.fillRGB), 30, "\(name) ≈ \(glyph)")
            }
        }
    }

    // MARK: - Измерения

    private func hex(_ color: Color, _ style: UIUserInterfaceStyle) -> UInt32 {
        let ui = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(1, max(0, v)) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    private func channels(_ value: UInt32) -> (Double, Double, Double) {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return (linear(Double((value >> 16) & 0xFF) / 255), linear(Double((value >> 8) & 0xFF) / 255),
                linear(Double(value & 0xFF) / 255))
    }

    private func luminance(_ v: UInt32) -> Double {
        let (r, g, b) = channels(v)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func deltaE(_ a: UInt32, _ b: UInt32) -> Double {
        func lab(_ v: UInt32) -> (Double, Double, Double) {
            let (r, g, b) = channels(v)
            let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
            func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
            return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        let (l1, a1, b1) = lab(a), (l2, a2, b2) = lab(b)
        return ((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2)).squareRoot()
    }

    /// Насыщенность OKLCH (Björn Ottosson, 2020).
    private func oklchChroma(_ value: UInt32) -> Double {
        let (r, g, b) = channels(value)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return (a * a + bb * bb).squareRoot()
    }
}
