//
//  SketchGlyphs.swift
//  RadarMap
//
//  Пиктограммы точечных объектов схемы.
//
//  Почему не SF Symbols. Системный «trafficlight» нарисован для списка, а не
//  для карты: на восьми пунктах он превращается в серое пятно, неотличимое от
//  лежачего полицейского. На схеме объект опознаётся ФОРМОЙ за долю секунды —
//  вертикальный корпус с тремя линзами читается светофором даже боковым
//  зрением, а глиф не читается никак.
//
//  Почему это View, а не рисование в Canvas. Canvas растеризует объявленный
//  символ ОДИН раз на весь растр и дальше только ставит копии: сто светофоров
//  стоят одной растеризации. Рисование фигурами обошлось бы в четыре примитива
//  на каждый объект при каждой перестройке.
//

import SwiftUI

/// Светофор: корпус с тремя линзами.
nonisolated struct TrafficLightGlyph: View {
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 0.9 * scale) {
            lens(SketchPalette.signalRed)
            lens(SketchPalette.signalAmber)
            lens(SketchPalette.signalGreen)
        }
        .padding(.vertical, 1.5 * scale)
        .padding(.horizontal, 1.6 * scale)
        .background {
            RoundedRectangle(cornerRadius: 1.9 * scale, style: .continuous)
                .fill(SketchPalette.markBody)
                .overlay {
                    RoundedRectangle(cornerRadius: 1.9 * scale, style: .continuous)
                        .strokeBorder(SketchPalette.markEdge.opacity(0.75),
                                      lineWidth: 0.8 * scale)
                }
        }
        // Тёмный ореол: корпус почти чёрный, и на тёмном асфальте без него
        // теряется край. Тень тут дешевле обводки — она вне растра не живёт.
        .shadow(color: .black.opacity(0.7), radius: 1.6 * scale)
    }

    private func lens(_ colour: Color) -> some View {
        Circle().fill(colour).frame(width: 2.6 * scale, height: 2.6 * scale)
    }
}

/// Лежачий полицейский: горб поперёк движения, с полосатой разметкой.
nonisolated struct SpeedBumpGlyph: View {
    let scale: CGFloat

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(SketchPalette.markBody)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(SketchPalette.markEdge.opacity(0.75),
                                      lineWidth: 0.8 * scale)
                }
            HStack(spacing: 1.4 * scale) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(SketchPalette.markEdge.opacity(0.9))
                        .frame(width: 1.1 * scale, height: 3.4 * scale)
                }
            }
        }
        .frame(width: 12 * scale, height: 6.4 * scale)
        .shadow(color: .black.opacity(0.7), radius: 1.6 * scale)
    }
}

/// Стоп-линия: поперечная полоса, какой её видно с водительского места.
nonisolated struct StopLineGlyph: View {
    let scale: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 0.8 * scale, style: .continuous)
            .fill(SketchPalette.markEdge)
            .frame(width: 12 * scale, height: 2.6 * scale)
            .overlay {
                RoundedRectangle(cornerRadius: 0.8 * scale, style: .continuous)
                    .strokeBorder(.black.opacity(0.55), lineWidth: 0.7 * scale)
            }
            .shadow(color: .black.opacity(0.7), radius: 1.4 * scale)
    }
}

/// Разворот: стрелка на плашке. Единственный из точечных объектов, который
/// говорит о МАНЁВРЕ, — поэтому он и единственный на круглой плашке, как
/// дорожный знак.
nonisolated struct UTurnGlyph: View {
    let scale: CGFloat

    var body: some View {
        Image(systemName: "arrow.uturn.left")
            .font(.rounded(7 * scale, .heavy))
            .foregroundStyle(SketchPalette.markEdge)
            .frame(width: 13 * scale, height: 13 * scale)
            .background {
                Circle()
                    .fill(SketchPalette.markBody)
                    .overlay {
                        Circle().strokeBorder(SketchPalette.markEdge.opacity(0.7),
                                              lineWidth: 0.8 * scale)
                    }
            }
            .shadow(color: .black.opacity(0.7), radius: 1.6 * scale)
    }
}

/// Камера на схеме: кольцо с линзой, а не заливка.
///
/// Тревожная крупнее и ярче остальных. Разница нужна ровно та, которую видно
/// краем глаза: десяток одинаковых точек по краям читается сыпью, а не картой.
nonisolated struct CameraDotGlyph: View {
    let scale: CGFloat
    let isAlert: Bool

    private var side: CGFloat { (isAlert ? 13 : 9.5) * scale }

    var body: some View {
        ZStack {
            Circle().fill(SketchPalette.cameraDotFill)
            Circle().strokeBorder(SketchPalette.cameraDotRing.opacity(isAlert ? 1 : 0.72),
                                  lineWidth: (isAlert ? 2.2 : 1.7) * scale)
            // Линза — только у тревожной: на девяти пунктах точка внутри
            // кольца сливается с ним и превращает значок обратно в пятно.
            if isAlert {
                Circle()
                    .fill(SketchPalette.cameraDotRing)
                    .frame(width: 3.4 * scale, height: 3.4 * scale)
            }
        }
        .frame(width: side, height: side)
        .shadow(color: .black.opacity(0.75), radius: 1.8 * scale)
    }
}

/// Ключ символа Canvas. Enum, а не строка: перепутать «камеру» с «маркой»
/// нельзя по типу, а не по внимательности.
nonisolated enum SketchSymbol: Hashable {
    case mark(SketchPoint.Kind)
    case camera(alert: Bool)
}

/// Пиктограмма по виду объекта. Отдельной функцией, чтобы список символов и
/// список видов не могли разойтись: новый вид без глифа не соберётся.
@ViewBuilder
nonisolated func sketchGlyph(for kind: SketchPoint.Kind, scale: CGFloat) -> some View {
    switch kind {
    case .trafficLight: TrafficLightGlyph(scale: scale)
    case .speedBump:    SpeedBumpGlyph(scale: scale)
    case .stopLine:     StopLineGlyph(scale: scale)
    case .uTurn:        UTurnGlyph(scale: scale)
    }
}
