//
//  MeCursor.swift
//  RadarMap
//
//  Курсор «я» — по выбору водителя: стрелка или машина.
//
//  Отдельным файлом: курсор рисуют карта на движке (битмапом над картой),
//  плитки выбора и онбординг. Все значки — носом вверх; стрелка рисуется
//  здесь, машины — готовые картинки каталога (CursorStyle.assetName).
//

import SwiftUI

/// Значок «я» носом вверх — карта на движке поворачивает его по курсу.
struct MeCursor: View {
    var scale: CGFloat = 1
    /// Какой значок. По умолчанию — стрелка: вызовы, которые о выборе не
    /// знают (и картинка до появления выбора), рисуют ровно то, что рисовали.
    var style: CursorStyle = .arrow

    var body: some View {
        if let asset = style.assetName {
            // Картинка уже с полями под тень: шире рамки и выступает за неё,
            // как тень стрелки.
            let pad = CursorStyle.padding * 2
            Image(asset)
                .resizable()
                .interpolation(.high)
                .frame(width: (style.frameSize.width + pad) * scale,
                       height: (style.frameSize.height + pad) * scale)
                .frame(width: style.frameSize.width * scale, height: style.frameSize.height * scale)
                .accessibilityHidden(true)
        } else {
            ArrowCursor(scale: scale)
        }
    }
}

/// Стрелка-конус — курсор, каким он был до выбора значков, пиксель в пиксель.
private struct ArrowCursor: View {
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            // Тень: курсор садится НА полотно, а не висит над ним.
            Ellipse()
                .fill(.black.opacity(0.45))
                .frame(width: 26 * scale, height: 9 * scale)
                .blur(radius: 4 * scale)
                .offset(y: 15 * scale)
            // Основание: тот же силуэт чуть ниже и темнее — даёт толщину.
            MeCursorShape()
                .fill(MapPalette.meBase)
                .offset(y: 2.5 * scale)
            MeCursorShape()
                .fill(LinearGradient(colors: [MapPalette.meTop,
                                              MapPalette.meBody],
                                     startPoint: .top, endPoint: .bottom))
            // Боковое освещение: левая грань светлее, правая уходит в тень.
            // Градиентом, а не половиной фигуры под маской: жёсткая граница по
            // оси делила курсор надвое и читалась не конусом, а сложенным
            // веером — ровно та ошибка, ради которой этот слой и рисуется.
            MeCursorShape()
                .fill(LinearGradient(stops: [
                    .init(color: .white.opacity(0.32), location: 0),
                    .init(color: .white.opacity(0.04), location: 0.45),
                    .init(color: .black.opacity(0.26), location: 1),
                ], startPoint: .leading, endPoint: .trailing))
            MeCursorShape()
                .stroke(.white.opacity(0.85), lineWidth: 1.2 * scale)
        }
        .compositingGroup()
        .shadow(color: MapPalette.meBody.opacity(0.55), radius: 6 * scale)
    }
}

/// Силуэт курсора: остриё вверху, выпуклое книзу основание — конус, увиденный
/// чуть сверху. Выпуклое, а не плоское: плоский низ читается треугольником.
private struct MeCursorShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        // Уже рамки и выше: развал во всю ширину при основании на трёх
        // четвертях высоты давал приземистый треугольник с широкой юбкой.
        let half = rect.width * 0.40
        let shoulder = rect.minY + rect.height * 0.88
        var path = Path()
        path.move(to: CGPoint(x: cx, y: rect.minY))
        path.addLine(to: CGPoint(x: cx + half, y: shoulder))
        path.addQuadCurve(to: CGPoint(x: cx - half, y: shoulder),
                          control: CGPoint(x: cx, y: rect.minY + rect.height * 1.06))
        path.closeSubpath()
        return path
    }
}
