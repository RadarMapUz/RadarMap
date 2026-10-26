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
    /// Глиф типа.
    nonisolated var glyph: CameraGlyph {
        switch self {
        case .stationaryCamera: return .camera
        case .stationaryRadar:  return .radar
        case .intelligentRadar: return .intelligent
        case .mobileRadar:      return .mobile
        case .tripod:           return .tripod
        case .dpsPost:          return .post
        case .accident:         return .accident
        case .other:            return .other
        }
    }
}

/// Значок камеры: круг цвета типа, белый кант, глиф типа.
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
            Image(systemName: name).font(.rounded(size, weight))
        }
    }
}

/// Растры значка (UIKit) — для движка карты и CarPlay. Та же отрисовка, что у
/// `CameraIcon`, другим холстом.
enum CameraIconArt {

    /// Значок стороной `side`, с полем `pad` вокруг круга (под тень).
    nonisolated static func image(_ kind: CameraType, side: CGFloat, fill: UInt32? = nil, ink: UInt32? = nil,
                                  rim: UInt32 = 0xFFFFFF, shadow: Bool, pad: CGFloat = 0,
                                  scale: CGFloat = 0) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        if scale > 0 { format.scale = scale }
        let full = side + 2 * pad
        return UIGraphicsImageRenderer(size: CGSize(width: full, height: full), format: format).image { context in
            CameraCoin.draw(kind.glyph, in: context.cgContext,
                            disc: CGRect(x: pad, y: pad, width: side, height: side),
                            fill: Theme.rgb(fill ?? kind.markerRGB).cgColor,
                            ink: ink.map { Theme.rgb($0).cgColor } ?? glyphColor(kind),
                            rim: Theme.rgb(rim).cgColor, shadow: shadow)
        }
    }

    /// Облик значка на карте (CameraMarkerLook.rasters): с тенью и полем под неё.
    nonisolated static func marker(_ kind: CameraType, look: CameraMarkerLook.Raster) -> UIImage {
        image(kind, side: CGFloat(look.side), fill: look.fill, ink: look.ink, rim: look.rim,
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

    /// Цвет глифа на заливке типа (тот же выбор, что `CameraType.glyphTint`).
    nonisolated static func glyphColor(_ kind: CameraType) -> CGColor {
        Theme.rgb(kind.glyph.inkRGB).cgColor
    }
}
