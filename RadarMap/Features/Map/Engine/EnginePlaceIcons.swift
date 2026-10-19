//
//  EnginePlaceIcons.swift
//  RadarMap
//
//  Значки мест на карте — те же символы, что в поиске и в «Куда» CarPlay
//  (Venue.Kind.symbol), одной сетки 22 pt (план 4.7, 20.10). Раньше АЗС
//  рисовалась значком «fuel_11» чужого спрайта выпуска, а парковка — буквой
//  «P» на синем ореоле текста: на одной карте три разных языка значков.
//
//  Рисуются в приложении и встают в стиль под своими именами — как светофор
//  (EngineMapView.trafficLightIcon): спрайт выпуска, пришедший с сервера
//  позже стиля, их не перебьёт, и выпуск спрайта ради них не нужен.
//

#if canImport(MapLibre)
import UIKit

enum EnginePlaceIcons {
    static let fuel = "radar-place-fuel"
    static let parking = "radar-place-parking"

    /// Сторона значка, pt. Слой масштабирует его по зуму (EngineModernStyle).
    static let side: CGFloat = 22

    static var all: [(name: String, image: UIImage)] {
        [(fuel, icon(symbol: Venue.Kind.fuel.symbol, fill: Theme.rgb(0x3B4047))),
         (parking, icon(symbol: Venue.Kind.parking.symbol, fill: Theme.rgb(0x2563D9)))]
    }

    /// Скруглённый квадрат цвета места с белой кромкой и белым символом: та
    /// же графитовая гамма, что у светофора, — красный и цвета типов на этой
    /// карте заняты камерами. Парковка — синяя, как дорожный знак.
    static func icon(symbol: String, fill: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            let shell = UIBezierPath(roundedRect: CGRect(x: 0.75, y: 0.75, width: side - 1.5, height: side - 1.5),
                                     cornerRadius: 5.5)
            fill.setFill()
            shell.fill()
            UIColor.white.withAlphaComponent(0.9).setStroke()
            shell.lineWidth = 1.2
            shell.stroke()
            let configuration = UIImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
            guard let glyph = UIImage(systemName: symbol, withConfiguration: configuration)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
            glyph.draw(at: CGPoint(x: (side - glyph.size.width) / 2, y: (side - glyph.size.height) / 2))
        }
    }
}
#endif
