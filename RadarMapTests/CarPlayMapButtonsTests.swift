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
        // Макет столбика кнопок карты в поездке и правой половины бара — днём
        // и ночью. Круги и капсулы рисует здесь тест, а не CarPlay: это
        // приближение, чтобы увидеть картинку среди соседей.
        for night in [false, true] {
            let mock = mockColumn(night: night)
            let file = url.appendingPathComponent("carplay_buttons_mock_\(night ? "night" : "day").png")
            do { try mock.pngData()?.write(to: file) } catch { XCTFail("\(error)") }
        }
    }

    private func mockColumn(night: Bool) -> UIImage {
        let circle: CGFloat = 44, gap: CGFloat = 8
        let barHeight: CGFloat = 36
        let size = CGSize(width: 260, height: barHeight + 24 + 4 * circle + 3 * gap + 16)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let map = night ? UIColor(white: 0.13, alpha: 1) : UIColor(white: 0.93, alpha: 1)
            let button = night ? UIColor(white: 0.24, alpha: 1) : UIColor.white
            let ink = night ? UIColor.white : UIColor(white: 0.11, alpha: 1)
            map.setFill(); UIRectFill(CGRect(origin: .zero, size: size))
            // Правая половина бара: «Куда» (лупа) и «Радар!» словом.
            let font = UIFont.systemFont(ofSize: 15, weight: .semibold)
            let title = "Радар!" as NSString
            let titleSize = title.size(withAttributes: [.font: font])
            let radar = CGRect(x: size.width - 12 - titleSize.width - 24, y: 8,
                               width: titleSize.width + 24, height: barHeight)
            let search = CGRect(x: radar.minX - 8 - 52, y: 8, width: 52, height: barHeight)
            for rect in [search, radar] {
                button.setFill(); UIBezierPath(roundedRect: rect, cornerRadius: barHeight / 2).fill()
            }
            title.draw(at: CGPoint(x: radar.midX - titleSize.width / 2, y: radar.midY - titleSize.height / 2),
                       withAttributes: [.font: font, .foregroundColor: ink])
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            if let glass = UIImage(systemName: "magnifyingglass", withConfiguration: symbolConfig)?
                .withTintColor(ink, renderingMode: .alwaysOriginal) {
                glass.draw(at: CGPoint(x: search.midX - glass.size.width / 2, y: search.midY - glass.size.height / 2))
            }
            // Столбик кнопок карты в поездке: «Радар!», +, −, осмотр.
            let x = size.width - 12 - circle
            var y = barHeight + 24
            let report = CarPlayReportImage.render(title: "Радар!", scale: 3)
            let mapConfig = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
            let images: [UIImage?] = [report] + ["plus", "minus", "arrow.up.and.down.and.arrow.left.and.right"]
                .map { UIImage(systemName: $0, withConfiguration: mapConfig)?.withTintColor(ink, renderingMode: .alwaysOriginal) }
            for image in images {
                let rect = CGRect(x: x, y: y, width: circle, height: circle)
                button.setFill(); UIBezierPath(ovalIn: rect).fill()
                if let image {
                    let fit = min(1, (circle - 4) / max(image.size.width, image.size.height))
                    let w = image.size.width * fit, h = image.size.height * fit
                    image.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
                }
                y += circle + gap
            }
        }
    }
}
