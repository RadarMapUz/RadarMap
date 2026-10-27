//
//  CarPlayBannerArt.swift
//  RadarMap
//
//  Растры для машины на iOS 27 (25.H1): картинка и аватар баннера камеры,
//  знак ограничения в тексте манёвра. Что рисовать и когда перерисовывать —
//  CarPlayCameraBannerLook; здесь только кисть.
//
//  Всё — готовые битмапы оригинальных цветов (`alwaysOriginal`): шаблонную
//  картинку CarPlay закрасил бы по альфе в одно пятно, и знак «60» стал бы
//  кругом. Масштаб — `carPlaySymbolScale`: экран машины бывает @3x, а
//  картинка рисуется один раз.
//
//  Знак — тот же, что на телефоне (`SpeedLimitSign`): белый круг, красная
//  обводка, чёрная цифра. Значок типа — тот же диск, что у камеры на карте
//  (`CameraType.tint`, белое кольцо, глиф `glyphTint`).
//

import SwiftUI
import UIKit

enum CarPlayBannerArt {

    /// Красный обводки знака — `SpeedLimitSign`.
    private static let signRed = Theme.signRedUIColor

    // MARK: - Знак ограничения

    static func limitSign(_ limit: Int, diameter: CGFloat,
                          scale: CGFloat = AppConfig.carPlaySymbolScale) -> UIImage {
        render(CGSize(width: diameter, height: diameter), scale: scale) { _ in
            drawLimitSign(limit, in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        }
    }

    private static func drawLimitSign(_ limit: Int, in rect: CGRect) {
        let diameter = min(rect.width, rect.height)
        let border = diameter * 0.107
        let circle = CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                            width: diameter, height: diameter)
        UIColor.white.setFill()
        UIBezierPath(ovalIn: circle).fill()
        let ring = UIBezierPath(ovalIn: circle.insetBy(dx: border / 2, dy: border / 2))
        ring.lineWidth = border
        signRed.setStroke()
        ring.stroke()
        let text = "\(limit)" as NSString
        let size = diameter * (limit >= 100 ? 0.34 : 0.42)
        let attributes = roundedAttributes(size: size, weight: .heavy, color: .black)
        let drawn = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: circle.midX - drawn.width / 2, y: circle.midY - drawn.height / 2),
                  withAttributes: attributes)
    }

    // MARK: - Значок типа

    /// Диск цвета типа с белым кольцом и глифом — маркер камеры на карте.
    static func typeDisc(_ type: CameraType, diameter: CGFloat,
                         scale: CGFloat = AppConfig.carPlaySymbolScale) -> UIImage {
        render(CGSize(width: diameter, height: diameter), scale: scale) { _ in
            drawTypeDisc(type, in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        }
    }

    private static func drawTypeDisc(_ type: CameraType, in rect: CGRect) {
        let diameter = min(rect.width, rect.height)
        let circle = CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                            width: diameter, height: diameter)
        // Значок «Монета» (29.C) — тот же, что на карте и телефоне.
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        CameraCoin.draw(type.glyph, in: cg, disc: circle,
                        fill: Theme.rgb(type.glyph.fillRGB).cgColor, ink: Theme.rgb(type.glyph.inkRGB).cgColor,
                        rim: UIColor.white.cgColor, shadow: false)
    }

    // MARK: - Баннер камеры

    /// Аватар баннера: значок типа, вписанный в предел системы.
    static func avatar(_ type: CameraType, size: CGSize,
                       scale: CGFloat = AppConfig.carPlaySymbolScale) -> UIImage {
        typeDisc(type, diameter: min(size.width, size.height), scale: scale)
    }

    /// Картинка над кнопками: знак ограничения (или значок типа) и полоса
    /// приближения цвета типа. `onDark` — тема баннера (тема машины): от
    /// неё зависит дорожка полосы, чтобы пустая часть была видна и там, и там.
    static func alertImage(_ art: CarPlayCameraBannerLook.Art, type: CameraType, size: CGSize,
                           onDark: Bool, scale: CGFloat = AppConfig.carPlaySymbolScale) -> UIImage {
        render(size, scale: scale) { _ in
            let lead = CGRect(x: 0, y: 0, width: size.height, height: size.height)
            switch art.lead {
            case .limit(let limit): drawLimitSign(limit, in: lead)
            case .type: drawTypeDisc(type, in: lead)
            }
            let gap = size.height * 0.35
            let barHeight = max(4, size.height * 0.26)
            let track = CGRect(x: lead.maxX + gap, y: (size.height - barHeight) / 2,
                               width: max(0, size.width - lead.maxX - gap), height: barHeight)
            guard track.width > barHeight else { return }
            (onDark ? UIColor(white: 1, alpha: 0.22) : UIColor(white: 0, alpha: 0.12)).setFill()
            UIBezierPath(roundedRect: track, cornerRadius: barHeight / 2).fill()
            let share = CGFloat(art.step) / CGFloat(max(1, art.steps))
            // Пустой полосы не бывает: баннер есть — камера уже в радиусе.
            let filled = CGRect(x: track.minX, y: track.minY,
                                width: max(barHeight, track.width * share), height: barHeight)
            UIColor(type.tint).setFill()
            UIBezierPath(roundedRect: filled, cornerRadius: barHeight / 2).fill()
        }
    }

    // MARK: - Знак в тексте манёвра

    /// «Поверните направо на ул. Лабзак (60)» — вложение-знак в конце
    /// каждого варианта фразы. Вложение не больше 64×25 pt (CPManeuver.h).
    static func instructionVariants(_ variants: [String], limit: Int) -> [NSAttributedString] {
        let side = AppConfig.carPlayManeuverLimitSignPoints
        let attachment = NSTextAttachment(image: limitSign(limit, diameter: side))
        // Знак — по центру строки, а не на базовой линии: вниз на половину
        // разницы с высотой прописной буквы (~12 pt у текста карточки).
        attachment.bounds = CGRect(x: 0, y: -(side - 12) / 2, width: side, height: side)
        let sign = NSAttributedString(attachment: attachment)
        return variants.map { variant in
            let line = NSMutableAttributedString(string: variant + " ")
            line.append(sign)
            return line
        }
    }

    // MARK: - Кисть

    private static func render(_ size: CGSize, scale: CGFloat,
                               _ draw: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(1, scale)
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image(actions: draw)
            .withRenderingMode(.alwaysOriginal)
    }

    private static func roundedAttributes(size: CGFloat, weight: UIFont.Weight,
                                          color: UIColor) -> [NSAttributedString.Key: Any] {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
        return [.font: font, .foregroundColor: color]
    }
}
