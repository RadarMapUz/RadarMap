//
//  CarPlayBannerArtTests.swift
//  RadarMapTests
//
//  Растры машины на iOS 27 (25.H1): картинка и аватар баннера камеры
//  нужного размера и оригинальных цветов, знак в тексте манёвра — вложение
//  в пределах 64×25 pt (CPManeuver.h). Снимки для глаз — в
//  RADARMAP_SHOTS_DIR (`TEST_RUNNER_RADARMAP_SHOTS_DIR=… xcodebuild test`).
//

import UIKit
import XCTest
@testable import RadarMap

final class CarPlayBannerArtTests: XCTestCase {

    func testAlertImageHasTheRequestedSizeAndOriginalColours() {
        let art = CarPlayCameraBannerLook.art(limit: 60, distance: 150, radius: 400)
        let image = CarPlayBannerArt.alertImage(art, type: .stationaryCamera,
                                                size: AppConfig.carPlayBannerAlertImageSize, onDark: true)
        XCTAssertEqual(image.size, AppConfig.carPlayBannerAlertImageSize)
        XCTAssertEqual(image.renderingMode, .alwaysOriginal, "шаблоном CarPlay закрасил бы знак в пятно")
    }

    func testAvatarFitsTheSmallerSide() {
        let image = CarPlayBannerArt.avatar(.tripod, size: CGSize(width: 40, height: 32))
        XCTAssertEqual(image.size, CGSize(width: 32, height: 32))
        XCTAssertEqual(image.renderingMode, .alwaysOriginal)
    }

    /// Знак — в конце КАЖДОГО варианта: система берёт первый, что влезет.
    func testLimitSignIsAnAttachmentWithinTheManeuverLimit() {
        let variants = CarPlayBannerArt.instructionVariants(["Поверните направо на ул. Лабзак", "Направо"],
                                                            limit: 40)
        XCTAssertEqual(variants.count, 2)
        for line in variants {
            var attachments: [NSTextAttachment] = []
            line.enumerateAttribute(.attachment, in: NSRange(location: 0, length: line.length)) { value, _, _ in
                if let attachment = value as? NSTextAttachment { attachments.append(attachment) }
            }
            XCTAssertEqual(attachments.count, 1)
            let bounds = attachments[0].bounds.size
            XCTAssertLessThanOrEqual(bounds.width, 64)
            XCTAssertLessThanOrEqual(bounds.height, 25)
            XCTAssertNotNil(attachments[0].image)
        }
        XCTAssertTrue(variants[1].string.hasPrefix("Направо "))
    }

    /// Снимки для глаз владельца: только если задан каталог.
    func testDumpForReview() throws {
        guard let dir = ProcessInfo.processInfo.environment["RADARMAP_SHOTS_DIR"] else {
            throw XCTSkip("RADARMAP_SHOTS_DIR не задан")
        }
        let url = URL(fileURLWithPath: dir)
        func save(_ image: UIImage, _ name: String) {
            do { try image.pngData()?.write(to: url.appendingPathComponent(name)) } catch { XCTFail("\(error)") }
        }
        let size = AppConfig.carPlayBannerAlertImageSize
        for dark in [false, true] {
            let theme = dark ? "night" : "day"
            for (distance, step) in [(380.0, "far"), (200.0, "mid"), (40.0, "near")] {
                let art = CarPlayCameraBannerLook.art(limit: 60, distance: distance, radius: 400)
                save(CarPlayBannerArt.alertImage(art, type: .stationaryCamera, size: size, onDark: dark),
                     "banner_camera_limit60_\(step)_\(theme).png")
            }
            let tripod = CarPlayCameraBannerLook.art(limit: nil, distance: 150, radius: 400)
            save(CarPlayBannerArt.alertImage(tripod, type: .tripod, size: size, onDark: dark),
                 "banner_tripod_nolimit_\(theme).png")
            let radar = CarPlayCameraBannerLook.art(limit: 100, distance: 120, radius: 600)
            save(CarPlayBannerArt.alertImage(radar, type: .stationaryRadar, size: size, onDark: dark),
                 "banner_radar_limit100_\(theme).png")
            save(mockBanner(dark: dark), "banner_mock_\(theme).png")
        }
        for type in [CameraType.stationaryCamera, .stationaryRadar, .mobileRadar, .tripod, .dpsPost] {
            save(CarPlayBannerArt.avatar(type, size: AppConfig.carPlayBannerAvatarSize), "avatar_\(type.symbolName).png")
        }
        save(CarPlayBannerArt.limitSign(40, diameter: AppConfig.carPlayManeuverLimitSignPoints), "maneuver_sign_40.png")
        save(mockManeuverCard(), "maneuver_card_mock.png")
    }

    /// Приближение баннера машины: подложку, заголовок и кнопку рисует здесь
    /// тест, а не CarPlay, — чтобы увидеть картинку среди соседей.
    private func mockBanner(dark: Bool) -> UIImage {
        let size = CGSize(width: 300, height: 150)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            (dark ? UIColor(white: 0.16, alpha: 1) : UIColor(white: 0.96, alpha: 1)).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 16).fill()
            let ink: UIColor = dark ? .white : .black
            CarPlayBannerArt.avatar(.stationaryCamera, size: CGSize(width: 32, height: 32))
                .draw(at: CGPoint(x: 12, y: 12))
            ("Камера через 300 м" as NSString).draw(at: CGPoint(x: 52, y: 12), withAttributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: ink])
            ("Ограничение 60 · Стационарная камера" as NSString).draw(at: CGPoint(x: 52, y: 31), withAttributes: [
                .font: UIFont.systemFont(ofSize: 11), .foregroundColor: ink.withAlphaComponent(0.6)])
            let art = CarPlayCameraBannerLook.art(limit: 60, distance: 300, radius: 400)
            CarPlayBannerArt.alertImage(art, type: .stationaryCamera, size: CGSize(width: 220, height: 40),
                                        onDark: dark).draw(at: CGPoint(x: 40, y: 58))
            let button = CGRect(x: 12, y: 108, width: 276, height: 32)
            (dark ? UIColor(white: 0.3, alpha: 1) : UIColor(white: 0.85, alpha: 1)).setFill()
            UIBezierPath(roundedRect: button, cornerRadius: 10).fill()
            let title = "Понятно" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14, weight: .semibold),
                                                             .foregroundColor: ink]
            let drawn = title.size(withAttributes: attributes)
            title.draw(at: CGPoint(x: button.midX - drawn.width / 2, y: button.midY - drawn.height / 2),
                       withAttributes: attributes)
        }
    }

    private func mockManeuverCard() -> UIImage {
        let size = CGSize(width: 300, height: 70)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            CarPlayGuidance.cardColor.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 12).fill()
            CarPlayGuidance.symbol("arrow.turn.up.right", pointSize: 28, onDark: true)?
                .draw(at: CGPoint(x: 12, y: 14))
            let line = NSMutableAttributedString(attributedString:
                CarPlayBannerArt.instructionVariants(["Направо, ул. Лабзак"], limit: 40)[0])
            line.addAttributes([.font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                                .foregroundColor: UIColor.white],
                               range: NSRange(location: 0, length: line.length))
            line.draw(at: CGPoint(x: 60, y: 22))
        }
    }
}
