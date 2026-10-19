//
//  WidgetPaletteTests.swift
//  RadarMapTests
//
//  Виджет — та же палитра А, что и приложение, а не своя (до 19.10 там жил
//  неоновый «радар-детектор»). Числа WidgetPalette сверяются с Theme в обеих
//  темах, текст — по контрасту WCAG на обеих частях подложки, балл — по тем
//  же ступеням, что DrivingScore.tier.
//

import SwiftUI
import XCTest
@testable import RadarMap

final class WidgetPaletteTests: XCTestCase {

    private func rgb(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    private func hex(_ color: Color, _ style: UIUserInterfaceStyle) -> UInt32 {
        let ui = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    private func luminance(_ hex: UInt32) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (r, g, b) = rgb(hex)
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testWidgetColoursAreTheAppPalette() {
        let pairs: [(WidgetPalette.Pair, Color, String)] = [
            (WidgetPalette.accent, Theme.accent, "accent"),
            (WidgetPalette.danger, Theme.danger, "danger"),
            (WidgetPalette.success, Theme.success, "success"),
            (WidgetPalette.warning, Theme.warning, "warning"),
            (WidgetPalette.primary, Theme.textPrimary, "textPrimary"),
            (WidgetPalette.secondary, Theme.textSecondary, "textSecondary"),
            (WidgetPalette.tertiary, Theme.textTertiary, "textTertiary"),
        ]
        for (pair, theme, name) in pairs {
            XCTAssertEqual(pair.light, hex(theme, .light), "\(name) днём разошёлся с Theme")
            XCTAssertEqual(pair.dark, hex(theme, .dark), "\(name) ночью разошёлся с Theme")
        }
    }

    /// Каждый цвет, которым на виджете написан текст, читается на обеих
    /// частях градиента подложки — днём и ночью.
    func testTextIsReadableOnTheWholeBackground() {
        let text: [(WidgetPalette.Pair, String)] = [
            (WidgetPalette.primary, "primary"), (WidgetPalette.secondary, "secondary"),
            (WidgetPalette.tertiary, "tertiary"), (WidgetPalette.accent, "accent"),
            (WidgetPalette.danger, "danger"), (WidgetPalette.success, "success"),
            (WidgetPalette.warning, "warning"),
        ]
        for (pair, name) in text {
            for (bg, part) in [(WidgetPalette.top, "верх"), (WidgetPalette.bottom, "низ")] {
                XCTAssertGreaterThanOrEqual(contrast(pair.light, bg.light), 4.5, "\(name) днём, \(part)")
                XCTAssertGreaterThanOrEqual(contrast(pair.dark, bg.dark), 4.5, "\(name) ночью, \(part)")
            }
        }
    }

    /// Белый значок кладётся только на заливки — и днём, и ночью. Ночные
    /// accent/danger — цвета ТЕКСТА, светлые: белый на них 2,5:1 (ревью 19.10).
    func testWhiteGlyphsSitOnFillsInBothThemes() {
        XCTAssertEqual(WidgetPalette.accentFill.light, hex(Theme.accentFill, .light))
        XCTAssertEqual(WidgetPalette.accentFill.dark, hex(Theme.accentFill, .dark))
        XCTAssertEqual(WidgetPalette.dangerFill.light, hex(Theme.dangerFill, .light))
        for fill in [WidgetPalette.accentFill, WidgetPalette.dangerFill, WidgetPalette.successFill] {
            XCTAssertGreaterThanOrEqual(contrast(0xFFFFFF, fill.light), 4.5, "днём")
            XCTAssertGreaterThanOrEqual(contrast(0xFFFFFF, fill.dark), 4.5, "ночью")
        }
    }

    /// Плашка поездки (Live Activity) — ночные значения палитры: заливки
    /// под белым значком совпадают с Theme и держат контраст, подложка — с
    /// окном тревоги.
    func testLiveActivityColoursAreTheNightPalette() {
        XCTAssertEqual(WidgetPalette.dangerFill.dark, hex(Theme.dangerFill, .dark))
        XCTAssertEqual(WidgetPalette.successFill.dark, hex(Theme.successFill, .dark))
        XCTAssertEqual(WidgetPalette.alertSurface, hex(Theme.alertSurface, .dark))
        for fill in [WidgetPalette.dangerFill.dark, WidgetPalette.successFill.dark] {
            XCTAssertGreaterThanOrEqual(contrast(0xFFFFFF, fill), 4.5, "белый значок на заливке")
        }
        for text in [WidgetPalette.accent.dark, WidgetPalette.danger.dark,
                     WidgetPalette.primary.dark, WidgetPalette.secondary.dark] {
            XCTAssertGreaterThanOrEqual(contrast(text, WidgetPalette.alertSurface), 4.5)
        }
    }

    func testScoreTiersMatchTheApp() {
        for rating in 0...100 {
            XCTAssertEqual(WidgetPalette.scoreTier(rating), DrivingScore.tier(for: rating), "балл \(rating)")
        }
    }

    /// Подписи дней — на языке приложения, порядок — от календаря: при
    /// регионе «США» и русском приложении было «S M T W».
    func testDayLabelsFollowTheAppLanguageButTheCalendarOrder() {
        var sunday = Calendar(identifier: .gregorian)
        sunday.locale = Locale(identifier: "en_US")
        sunday.firstWeekday = 1
        let labels = WidgetWeek.dayLabels(calendar: sunday, locale: Locale(identifier: "ru"))
        XCTAssertEqual(labels.count, 7)
        XCTAssertEqual(labels.first, "В", "неделя с воскресенья — первым «В»")
        XCTAssertEqual(labels[1], "П")
    }
}
