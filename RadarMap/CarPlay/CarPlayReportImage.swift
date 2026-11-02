//
//  CarPlayReportImage.swift
//  RadarMap
//
//  Картинка «Отметить» для кнопки карты в машине (25.H3, вариант B 02.11).
//  Значок — тренога (тип по умолчанию): волны без слова читались AirPlay.
//
//  Та же кнопка, что на телефоне: жёлтая заливка главного действия
//  (`Theme.action`), тёмные значок волн и слово «Радар!» (`Theme.onAction`,
//  11,9:1). Слово обязательно: значок волн без подписи читался как AirPlay
//  или «вещание» (владелец 21.10), а в машине учить значок некогда.
//
//  Жёлтый один и днём, и ночью: на тёмном круге ночной кнопки он горит сам, а
//  на светлом дневном круге его отделяет тонкое тёмное кольцо — жёлтое на
//  белом без кольца сливается (1,4:1).
//
//  Картинка — оригинальных цветов (`alwaysOriginal`), а не шаблон: шаблоном
//  CarPlay закрасил бы её по альфе в одно пятно, и слово пропало бы. По той
//  же причине `focusedImage` задаём сами — система сделала бы его «из альфы
//  исходной картинки», то есть сплошным кругом. В фокусе цвета меняются
//  местами: тёмный диск, жёлтые значок и слово.
//

import UIKit

nonisolated enum CarPlayReportImage {

    /// Отрисовать диск диаметром `diameter` pt в масштабе экрана машины.
    static func render(title: String,
                       symbol: String = CameraType.tripod.symbolName,
                       diameter: CGFloat = AppConfig.carPlayReportButtonPoints,
                       scale: CGFloat,
                       focused: Bool = false) -> UIImage {
        let fill = focused ? Theme.onActionUIColor : Theme.actionUIColor
        let ink = focused ? Theme.actionUIColor : Theme.onActionUIColor
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(1, scale)
        format.opaque = false
        let size = CGSize(width: diameter, height: diameter)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let ring: CGFloat = max(1, diameter / 24)
            let disc = CGRect(origin: .zero, size: size).insetBy(dx: ring / 2, dy: ring / 2)
            let path = UIBezierPath(ovalIn: disc)
            fill.setFill()
            path.fill()
            // Кольцо отделяет жёлтый от светлого круга дневной кнопки.
            Theme.onActionUIColor.withAlphaComponent(focused ? 1 : 0.35).setStroke()
            path.lineWidth = ring
            path.stroke()

            // Значок — сверху, слово — под ним, чуть ниже центра, где хорда
            // круга ещё почти во весь диаметр. Слово крупнее значка: оно и
            // есть смысл кнопки. Слово не влезает кеглем ≥ 9 pt («Отметить»,
            // «Belgilash» в 40 pt выходят около 6) — только значок, крупно и
            // по центру: нечитаемое слово хуже никакого (CarPlay, A2).
            let attributes = titleAttributes(title, diameter: diameter, color: ink)
            let showsTitle = CarPlayReportChoice.discShowsTitle(fittedPoints: fittedPoints(attributes))
            let glyphSide = diameter * (showsTitle ? 0.3 : 0.5)
            let config = UIImage.SymbolConfiguration(pointSize: glyphSide * 0.8, weight: .bold)
            if let glyph = UIImage(systemName: symbol, withConfiguration: config)?
                .withTintColor(ink, renderingMode: .alwaysOriginal) {
                let fit = min(glyphSide / max(glyph.size.width, 1), glyphSide / max(glyph.size.height, 1), 1)
                let glyphSize = CGSize(width: glyph.size.width * fit, height: glyph.size.height * fit)
                glyph.draw(in: CGRect(x: (diameter - glyphSize.width) / 2,
                                      y: showsTitle ? diameter * 0.44 - glyphSize.height
                                                    : (diameter - glyphSize.height) / 2,
                                      width: glyphSize.width, height: glyphSize.height))
            }

            guard showsTitle else { return }
            let textSize = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: CGPoint(x: (diameter - textSize.width) / 2,
                                                 y: diameter * 0.6 - textSize.height / 2),
                                     withAttributes: attributes)
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// Шрифт слова: крупно, сколько влезет в хорду круга на уровне строки
    /// (86 % диаметра) — узбекское «Radar!» и любое длиннее ужимается, а не
    /// вылезает за диск.
    static func titleAttributes(_ title: String, diameter: CGFloat,
                                color: UIColor = .black) -> [NSAttributedString.Key: Any] {
        let maxWidth = diameter * titleWidthShare
        var fontSize = diameter * 0.3
        // Ширина растёт с кеглем не строго пропорционально (оптические
        // размеры шрифта) — пара уточнений, пока не влезет.
        for _ in 0..<4 {
            let width = (title as NSString).size(withAttributes: textAttributes(size: fontSize, color: color)).width
            guard width > maxWidth else { break }
            fontSize *= maxWidth / width * 0.99
        }
        return textAttributes(size: fontSize, color: color)
    }

    static let titleWidthShare: CGFloat = 0.86

    /// Кегль, которым слово влезло в диск.
    static func fittedPoints(_ attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        (attributes[.font] as? UIFont)?.pointSize ?? 0
    }

    private static func textAttributes(size: CGFloat, color: UIColor) -> [NSAttributedString.Key: Any] {
        let base = UIFont.systemFont(ofSize: size, weight: .heavy)
        let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
        return [.font: font, .foregroundColor: color]
    }
}
