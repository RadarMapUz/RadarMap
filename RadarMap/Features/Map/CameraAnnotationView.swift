//
//  CameraAnnotationView.swift
//  RadarMap
//
//  Маркер камеры на карте — неоновый круг, цвет/иконка по типу.
//

import SwiftUI

struct CameraAnnotationView: View {
    let camera: Camera
    var selected: Bool = false
    /// Средний зум: маленькая точка вместо полного пина — экран не забит кружками.
    var compact: Bool = false

    var body: some View {
        if compact && !selected {
            Circle()
                .fill(camera.kind.tint)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 1))
                .frame(width: 30, height: 30)       // тап-мишень больше самой точки
                .contentShape(Circle())
        } else {
            fullPin
        }
    }

    private var fullPin: some View {
        ZStack {
            if selected {
                Circle()
                    .fill(camera.kind.tint.opacity(0.25))
                    .frame(width: 54, height: 54)
            }
            Circle()
                .fill(camera.kind.tint.gradient)
                .frame(width: selected ? 38 : 28, height: selected ? 38 : 28)
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                // Тень только у выбранного маркера: shadow = offscreen-проход рендера,
                // на ~220 аннотациях при панорамировании это заметно.
                .shadow(color: camera.kind.tint.opacity(selected ? 0.7 : 0), radius: selected ? 9 : 0)

            Image(systemName: camera.kind.symbolName)
                .font(.rounded(selected ? 16 : 13, .bold))
                .foregroundStyle(.white)

            if camera.isApproximate {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.radar)
                    .background(Circle().fill(.black).frame(width: 10, height: 10))
                    .offset(x: 13, y: -13)
            }
        }
        .animation(.spring(duration: 0.25), value: selected)
    }
}

/// Кластер на широком зуме: кружок с числом камер, тап — приближение.
struct ClusterAnnotationView: View {
    let count: Int

    var body: some View {
        Text(count > 999 ? "999+" : "\(count)")
            .font(.rounded(count > 99 ? 12 : 14, .bold))
            .foregroundStyle(Theme.background)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.accent.gradient))
            .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 2))
    }

    private var size: CGFloat {
        count > 99 ? 46 : count > 19 ? 40 : 34
    }
}
