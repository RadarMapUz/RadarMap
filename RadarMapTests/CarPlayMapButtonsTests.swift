//
//  CarPlayMapButtonsTests.swift
//  RadarMapTests
//
//  Кнопки карты в машине по состоянию (25.H3). Главное — что «Радар!» в
//  поездке есть, что лимиты шаблона не превышены и что осмотр остаётся
//  достижимым: на машинах без сенсора карту двигают только из него.
//

import XCTest
import UIKit
@testable import RadarMap

final class CarPlayMapButtonsTests: XCTestCase {

    private typealias M = CarPlayMapButtons

    private func layout(trip: Bool, following: Bool = true,
                        panning: Bool = false, previewing: Bool = false) -> [M.Kind] {
        M.layout(tripActive: trip, following: following, panning: panning, previewing: previewing)
    }

    /// Все сочетания состояния — для проверок «никогда».
    private var everyState: [(trip: Bool, following: Bool, panning: Bool, previewing: Bool)] {
        [false, true].flatMap { trip in [false, true].flatMap { following in
            [false, true].flatMap { panning in [false, true].map { previewing in
                (trip, following, panning, previewing) } } } }
    }

    func testWithoutTripTheSetIsUnchanged() {
        XCTAssertEqual(layout(trip: false), [.zoomIn, .zoomOut, .pan, .recenter(following: true)])
        XCTAssertEqual(layout(trip: false, following: false),
                       [.zoomIn, .zoomOut, .pan, .recenter(following: false)])
    }

    func testTripPutsReportFirst() {
        // Первая — и первая в фокусе крутилки.
        XCTAssertEqual(layout(trip: true).first, .report)
        XCTAssertEqual(layout(trip: true, following: false).first, .report)
    }

    func testTripFollowingOffersPanningInsteadOfUselessRecenter() {
        // Карта за машиной — «к себе» ничего не сделает; место у осмотра.
        XCTAssertEqual(layout(trip: true, following: true), [.report, .zoomIn, .zoomOut, .pan])
    }

    func testTripDetachedOffersTheWayBack() {
        // Сдвинули карту — нужен путь назад к машине.
        XCTAssertEqual(layout(trip: true, following: false),
                       [.report, .zoomIn, .zoomOut, .recenter(following: false)])
    }

    func testPanningShowsOnlyZoom() {
        // В осмотре система показывает не больше двух и прячет лишние с
        // конца: «Радар!» первой оттеснила бы «−».
        for trip in [false, true] {
            for following in [false, true] {
                XCTAssertEqual(layout(trip: trip, following: following, panning: true), [.zoomIn, .zoomOut])
            }
        }
    }

    func testRoutePreviewKeepsZoomAndNoReport() {
        // Выбор маршрута — машина стоит; «+ −» там нужны (аудит 18.10, п. 9).
        let set = layout(trip: true, previewing: true)
        XCTAssertFalse(set.contains(.report))
        XCTAssertEqual(Array(set.prefix(2)), [.zoomIn, .zoomOut])
    }

    func testTemplateLimitsAreNeverExceeded() {
        for s in everyState {
            let set = layout(trip: s.trip, following: s.following, panning: s.panning, previewing: s.previewing)
            XCTAssertLessThanOrEqual(set.count, M.limit, "\(s)")
            if s.panning { XCTAssertLessThanOrEqual(set.count, M.panningLimit, "\(s)") }
            XCTAssertEqual(Set(set).count, set.count, "без повторов: \(s)")
        }
    }

    func testZoomIsAlwaysThere() {
        for s in everyState {
            let set = layout(trip: s.trip, following: s.following, panning: s.panning, previewing: s.previewing)
            XCTAssertTrue(set.contains(.zoomIn) && set.contains(.zoomOut), "\(s)")
        }
    }

    func testPanningIsAlwaysReachable() {
        // Осмотр — сразу, либо через «к себе», которое вернёт слежение, а с
        // ним и кнопку осмотра (CarPlayBrowse: .recenter → following).
        for s in everyState where !s.panning {
            let set = layout(trip: s.trip, following: s.following, panning: false, previewing: s.previewing)
            if set.contains(.pan) { continue }
            XCTAssertTrue(set.contains(.recenter(following: false)), "\(s)")
            var browse = CarPlayBrowse.State(following: s.following, panning: false)
            _ = CarPlayBrowse.reduce(&browse, .recenter, previewing: s.previewing)
            let after = layout(trip: s.trip, following: browse.following, panning: false, previewing: s.previewing)
            XCTAssertTrue(after.contains(.pan), "после «к себе» осмотр в один тап: \(s)")
        }
    }

    func testLeavingPanningAfterMoveBringsReportBack() {
        // Осмотр в поездке → двигали → «Готово»: «Радар!» и «к себе» снова на месте.
        var browse = CarPlayBrowse.State()
        _ = CarPlayBrowse.reduce(&browse, .panningShown, previewing: false)
        XCTAssertEqual(layout(trip: true, following: browse.following, panning: browse.panning),
                       [.zoomIn, .zoomOut])
        _ = CarPlayBrowse.reduce(&browse, .moved, previewing: false)
        _ = CarPlayBrowse.reduce(&browse, .panningHidden, previewing: false)
        XCTAssertEqual(layout(trip: true, following: browse.following, panning: browse.panning),
                       [.report, .zoomIn, .zoomOut, .recenter(following: false)])
    }

    // MARK: - Картинка «Радар!»

    private func rgba(_ image: UIImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard let cg = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    func testReportImageIsADiscOfTheConfiguredSize() throws {
        let side = AppConfig.carPlayReportButtonPoints
        let image = CarPlayReportImage.render(title: "Радар!", scale: 2)
        XCTAssertEqual(image.size, CGSize(width: side, height: side))
        XCTAssertEqual(image.scale, 2)
        XCTAssertEqual(image.renderingMode, .alwaysOriginal, "шаблоном CarPlay закрасил бы слово в пятно")
        let px = Int(side * 2)
        // Углы прозрачны — это диск, а не квадрат.
        let corner = try XCTUnwrap(rgba(image, x: 1, y: 1))
        XCTAssertEqual(corner.a, 0)
        // У края диска, мимо значка и слова, — жёлтый главного действия.
        let edge = try XCTUnwrap(rgba(image, x: px * 15 / 100, y: px * 30 / 100))
        XCTAssertGreaterThan(edge.r, 200)
        XCTAssertGreaterThan(edge.g, 170)
        XCTAssertLessThan(edge.b, 120)
    }

    func testFocusedImageSwapsColours() throws {
        let px = Int(AppConfig.carPlayReportButtonPoints * 2)
        let focused = CarPlayReportImage.render(title: "Радар!", scale: 2, focused: true)
        let edge = try XCTUnwrap(rgba(focused, x: px * 15 / 100, y: px * 30 / 100))
        XCTAssertLessThan(edge.r, 60, "в фокусе — тёмный диск, а не тот же жёлтый")
        XCTAssertEqual(edge.a, 255)
    }

    func testLongTitleStillFitsTheDisc() throws {
        // Узбекское «Radar!» и любое длиннее — ужимается, а не обрезается.
        let side = AppConfig.carPlayReportButtonPoints
        for title in ["Радар!", "Radar!", "Radar! Radar!"] {
            let attributes = CarPlayReportImage.titleAttributes(title, diameter: side)
            let width = (title as NSString).size(withAttributes: attributes).width
            XCTAssertLessThanOrEqual(width, side * CarPlayReportImage.titleWidthShare + 0.5, title)
            let font = try XCTUnwrap(attributes[.font] as? UIFont)
            if title.count <= 6 {
                XCTAssertGreaterThanOrEqual(font.pointSize, 8, "короткое слово — не мельче 8 pt: \(title)")
            }
        }
        dumpForReview()
    }

    /// Снимки картинок для глаз владельца: только если задан каталог
    /// (`TEST_RUNNER_RADARMAP_SHOTS_DIR=… xcodebuild test`).
    private func dumpForReview() {
        guard let dir = ProcessInfo.processInfo.environment["RADARMAP_SHOTS_DIR"] else { return }
        let url = URL(fileURLWithPath: dir)
        for (name, title) in [("ru", "Радар!"), ("uz", "Radar!")] {
            for focused in [false, true] {
                let image = CarPlayReportImage.render(title: title, scale: 3, focused: focused)
                let file = url.appendingPathComponent("carplay_report_\(name)\(focused ? "_focused" : "").png")
                do { try image.pngData()?.write(to: file) } catch { XCTFail("\(error)") }
            }
        }
    }
}
