//
//  ShareInstallQRTests.swift
//  RadarMapTests
//
//  28.J: QR на шеринг-карточке ведёт на страницу установки и РЕАЛЬНО
//  считывается — с той самой картинки, которую рендерит ImageRenderer, в
//  обоих форматах. Плюс геометрия: код не шире 15 % карточки, в сторис —
//  внизу, но выше полосы интерфейса соцсети.
//

import CoreImage
import SwiftUI
import XCTest
@testable import RadarMap

@MainActor
final class ShareInstallQRTests: XCTestCase {

    func testCaptionIsTheBareAddress() {
        XCTAssertEqual(ShareInstallLink.caption(for: URL(string: "https://soulmed.uz/radarmap/")!),
                       "soulmed.uz/radarmap")
        XCTAssertEqual(ShareInstallLink.caption(for: URL(string: "https://apps.apple.com/app/id1")!),
                       "apps.apple.com/app/id1")
        XCTAssertEqual(ShareInstallLink.caption(for: URL(string: "https://soulmed.uz")!), "soulmed.uz")
    }

    /// Карточки, QR и ссылки прибытия видят люди без приложения — на них свой
    /// домен, не soulmed.uz, чей сервер мы делим (владелец, 26.10).
    func testPublicLinksUseOwnDomain() {
        XCTAssertEqual(ShareInstallLink.caption, "radarmap.uz")
        for url in [AppConfig.installPageURL, AppConfig.projectPageURL,
                    AppConfig.privacyPolicyURL, AppConfig.publicBaseURL] {
            XCTAssertEqual(url.host, "radarmap.uz", url.absoluteString)
        }
        XCTAssertEqual(EtaShare.link(base: AppConfig.publicBaseURL, token: "t").absoluteString,
                       "https://radarmap.uz/radarmap/api/eta/t")
    }

    func testQRCarriesTheInstallPage() throws {
        let qr = try XCTUnwrap(ShareInstallLink.qr, "QR не построен")
        // Модуль на пиксель — детектору нужен крупнее и с тихой зоной.
        let image = CIImage(cgImage: qr).transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let padded = image.transformed(by: CGAffineTransform(translationX: 40, y: 40))
            .composited(over: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0,
                                                                         width: image.extent.width + 80,
                                                                         height: image.extent.height + 80)))
        XCTAssertEqual(decode(padded).map(\.message), [AppConfig.installPageURL.absoluteString])
    }

    func testCardQRReadsInBothFormats() throws {
        for format in ShareFormat.allCases {
            let renderer = ImageRenderer(content: ShareCardShell(subtitle: "Достижение", format: format) {
                Spacer()
            })
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(format.size)
            let card = try XCTUnwrap(renderer.cgImage, "\(format)")
            let width = CGFloat(card.width), height = CGFloat(card.height)
            let found = decode(CIImage(cgImage: card))
            XCTAssertEqual(found.map(\.message), [AppConfig.installPageURL.absoluteString],
                           "\(format): QR с карточки не читается")
            guard let bounds = found.first?.bounds else { continue }
            XCTAssertLessThanOrEqual(bounds.width, width * 0.15, "\(format): QR шире 15 % карточки")
            // CoreImage считает y снизу: код в нижних 20 % карточки…
            XCTAssertLessThan(bounds.maxY, height * 0.2, "\(format): QR не внизу")
            // …а в сторис — над полосой интерфейса соцсети (96 pt).
            if format == .story {
                XCTAssertGreaterThan(bounds.minY, 96 * renderer.scale, "сторис: QR под интерфейсом соцсети")
            }
        }
    }

    private func decode(_ image: CIImage) -> [(message: String, bounds: CGRect)] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: image) ?? []).compactMap { feature in
            guard let qr = feature as? CIQRCodeFeature, let message = qr.messageString else { return nil }
            return (message, qr.bounds)
        }
    }
}
