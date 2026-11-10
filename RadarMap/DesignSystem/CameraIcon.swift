//
//  CameraIcon.swift
//  RadarMap
//
//  Значок камеры в приложении — стиль A «Монета» (29.C): глиф и основа из
//  Shared/CameraGlyph, цвета типа из Theme. Любое место, где показывается
//  тип камеры (HUD, оповещение, карточка, списки, онбординг, CarPlay, растры
//  движка), берёт значок отсюда — до 29.C каждый экран рисовал свой круг с
//  SF Symbol, и рядом стояли значки разного рода.
//

import SwiftUI
import UIKit

extension CameraType {
    /// Значок типа: все камеры — один (29.C2, владелец 26.10: «все камеры —
    /// одна иконка, они вроде все радары»); тип остаётся словом.
    nonisolated var glyph: CameraGlyph {
        switch self {
        case .stationaryCamera, .stationaryRadar, .intelligentRadar, .mobileRadar, .tripod:
            return .camera
        case .dpsPost:  return .post
        case .accident: return .accident
        case .other:    return .other
        }
    }
}

/// Значок камеры: красный круг камеры (у поста и ДТП — свои), белый кант, глиф.
struct CameraIcon: View, Equatable {
    let kind: CameraType
    let side: CGFloat
    /// Мягкая тень — над картой и на крупных значках; в строках списка не нужна.
    var shadow = false
    /// Неподтверждённая отметка водителей — пунктирный кант.
    var dashedRim = false

    var body: some View {
        CameraCoinView(glyph: kind.glyph, fill: kind.tint, ink: kind.glyphTint,
                       side: side, shadow: shadow, dashedRim: dashedRim)
    }
}

/// Символ строки: «камеры» — глиф камеры (29.C, как на карте), остальное —
/// SF Symbol. Цвет — из foregroundStyle, как у обычного символа; `size` —
/// кегль символа, глиф камеры чуть крупнее его (у символа есть поля).
struct SymbolIcon: View {
    let name: String
    let size: CGFloat
    var weight: Font.Weight = .semibold

    init(_ name: String, size: CGFloat, weight: Font.Weight = .semibold) {
        self.name = name
        self.size = size
        self.weight = weight
    }

    var body: some View {
        if let glyph = CameraGlyph(symbol: name) {
            CameraGlyphShape(glyph: glyph)
                .frame(width: (size * 1.3).rounded(), height: (size * 1.3).rounded())
                .accessibilityHidden(true)
        } else {
            Image(systemName: name).font(.dense(size, weight))
        }
    }
}

/// Растры значка (UIKit) — для движка карты и CarPlay. Та же отрисовка, что у
/// `CameraIcon`, другим холстом.
enum CameraIconArt {

    /// Значок стороной `side`, с полем `pad` вокруг круга (под тень).
    /// `fill`/`ink` nil — цвета самого значка (`CameraGlyph.fillRGB`/`inkRGB`).
    nonisolated static func image(_ glyph: CameraGlyph, side: CGFloat, fill: UInt32? = nil, ink: UInt32? = nil,
                                  rim: UInt32 = 0xFFFFFF, shadow: Bool, pad: CGFloat = 0,
                                  scale: CGFloat = 0) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        if scale > 0 { format.scale = scale }
        let full = side + 2 * pad
        return UIGraphicsImageRenderer(size: CGSize(width: full, height: full), format: format).image { context in
            CameraCoin.draw(glyph, in: context.cgContext,
                            disc: CGRect(x: pad, y: pad, width: side, height: side),
                            fill: Theme.rgb(fill ?? glyph.fillRGB).cgColor,
                            ink: Theme.rgb(ink ?? glyph.inkRGB).cgColor,
                            rim: Theme.rgb(rim).cgColor, shadow: shadow)
        }
    }

    /// Облик значка на карте (CameraMarkerLook.rasters): с тенью и полем под неё.
    nonisolated static func marker(_ glyph: CameraGlyph, look: CameraMarkerLook.Raster) -> UIImage {
        image(glyph, side: CGFloat(look.side), fill: look.fill, ink: look.ink, rim: look.rim,
              shadow: true, pad: CameraCoin.shadowPad)
    }

    /// Один глиф цветом `ink` (кнопки шаблонов CarPlay, баннеры без основы).
    nonisolated static func glyph(_ glyph: CameraGlyph, side: CGFloat, ink: UIColor,
                                  scale: CGFloat = 0) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        if scale > 0 { format.scale = scale }
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            glyph.draw(in: context.cgContext, rect: CGRect(x: 0, y: 0, width: side, height: side),
                            ink: ink.cgColor)
        }
    }
}
