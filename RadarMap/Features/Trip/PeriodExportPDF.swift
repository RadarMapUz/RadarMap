//
//  PeriodExportPDF.swift
//  RadarMap
//
//  PDF выгрузки периода (31E, п. 6): A4, заголовок, итог, таблица поездок и
//  — для режима водителя — таблица смен. Только системный
//  UIGraphicsPDFRenderer, без сторонних пакетов.
//
//  Все строки (даты, числа, подписи) готовит вызывающий на главном акторе —
//  форматтеры приложения живут там; здесь только раскладка и рисование, и
//  это можно делать вне main.
//

import UIKit

nonisolated enum PeriodExportPDF {

    struct Table: Sendable {
        let title: String
        let headers: [String]
        /// Доли ширины колонок, в сумме 1.
        let widths: [CGFloat]
        let rows: [[String]]
    }

    struct Document: Sendable {
        let title: String
        let subtitle: String
        let totals: [String]
        let tables: [Table]
        let footer: String
    }

    private static let page = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4, pt
    private static let margin: CGFloat = 40

    static func render(_ document: Document) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextCreator as String: "RadarMap",
                               kCGPDFContextTitle as String: document.title]
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)
        return renderer.pdfData { context in
            var y = margin
            let width = page.width - margin * 2
            func newPage() {
                context.beginPage()
                y = margin
            }
            func ensure(_ height: CGFloat) {
                if y + height > page.height - margin - 24 { newPage() }
            }
            @discardableResult
            func draw(_ text: String, font: UIFont, color: UIColor = .black, x: CGFloat = margin,
                      width w: CGFloat? = nil) -> CGFloat {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color,
                                                                 .paragraphStyle: style]
                let box = CGSize(width: w ?? width, height: .greatestFiniteMagnitude)
                let height = ceil((text as NSString).boundingRect(with: box, options: .usesLineFragmentOrigin,
                                                                   attributes: attributes, context: nil).height)
                (text as NSString).draw(with: CGRect(x: x, y: y, width: box.width, height: height),
                                        options: .usesLineFragmentOrigin, attributes: attributes, context: nil)
                return height
            }

            newPage()
            y += draw(document.title, font: .boldSystemFont(ofSize: 20)) + 4
            y += draw(document.subtitle, font: .systemFont(ofSize: 12), color: .darkGray) + 14
            for line in document.totals {
                y += draw(line, font: .systemFont(ofSize: 12)) + 2
            }
            y += 14

            for table in document.tables {
                ensure(60)
                y += draw(table.title, font: .boldSystemFont(ofSize: 14)) + 8
                func header() {
                    var x = margin
                    var tallest: CGFloat = 0
                    for (index, title) in table.headers.enumerated() {
                        let w = width * table.widths[index]
                        tallest = max(tallest, draw(title, font: .boldSystemFont(ofSize: 9), color: Theme.rgb(WidgetPalette.secondary.light),
                                                    x: x, width: w - 4))
                        x += w
                    }
                    y += tallest + 4
                    Theme.rgb(WidgetPalette.tertiary.light).setFill()
                    UIRectFill(CGRect(x: margin, y: y, width: width, height: 0.5))
                    y += 4
                }
                header()
                for row in table.rows {
                    let font = UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
                    // Высота строки — по самой высокой ячейке (район переносится).
                    let rowHeight = row.enumerated().map { index, text in
                        ceil((text as NSString).boundingRect(
                            with: CGSize(width: width * table.widths[index] - 4, height: .greatestFiniteMagnitude),
                            options: .usesLineFragmentOrigin, attributes: [.font: font], context: nil).height)
                    }.max() ?? 12
                    if y + rowHeight > page.height - margin - 24 {
                        newPage()
                        header()
                    }
                    var x = margin
                    for (index, text) in row.enumerated() {
                        let w = width * table.widths[index]
                        draw(text, font: font, x: x, width: w - 4)
                        x += w
                    }
                    y += rowHeight + 3
                }
                y += 16
            }
            ensure(40)
            draw(document.footer, font: .systemFont(ofSize: 9), color: Theme.rgb(WidgetPalette.tertiary.light))
        }
    }
}
