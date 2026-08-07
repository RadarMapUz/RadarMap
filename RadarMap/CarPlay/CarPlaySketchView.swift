//
//  CarPlaySketchView.swift
//  RadarMap
//
//  Режим «Схема» на CarPlay: чертим сами, без MKMapView — а значит, без
//  тайлов, аннотаций и вообще самого дорогого GPU-рендера приложения.
//  Картинка в машину стримится С ТЕЛЕФОНА, так что карту в машине рисует и
//  греет именно телефон в держателе; схема оставляет те же предупреждения,
//  манёвры и док скорости, но за копейки: растр раз в сотни метров плюс три
//  transform'а на тик (тот же SketchState, что на приборке телефона).
//

import SwiftUI

struct CarPlaySketchView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var sketch = SketchState()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let scene = sketch.scene, sketch.hasCourse, !scene.isEmpty {
                RoadSketchView(scene: scene, state: sketch, tint: alertColor)
                    // Схема живёт над доком: линейка масштаба и нижний край
                    // не должны утонуть под панелью скорости.
                    .padding(.bottom, AppConfig.carPlayDockBottomInset)
                    // Стоим и курса нет: рисуем «последнее, что знали»,
                    // приглушённо — как на приборке телефона.
                    .opacity(env.location.currentCourse < 0 ? 0.45 : 1)
                    .animation(.easeOut(duration: 0.4),
                               value: env.location.currentCourse < 0)
            } else {
                Label("Схема появится с началом движения", systemImage: "road.lanes")
                    .font(.rounded(15, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, AppConfig.carPlayDockBottomInset)
            }
        }
        // Тик GPS → точка зрения схемы (гейт неподвижности внутри refresh).
        .onChange(of: env.location.locationTick) { sketch.refresh(env) }
        .onAppear {
            // Фиксы чаще, пока схема на экране машины, — с тем же
            // термо-предохранителем, что у приборки (tuneAdaptiveAccuracy).
            env.location.setCarPlaySketchVisible(true)
            sketch.refresh(env)
        }
        .onDisappear { env.location.setCarPlaySketchVisible(false) }
        .accessibilityHidden(true)   // цифры дока CarPlay уже озвучены
    }

    /// То же правило близости, что у приборки телефона: схема и док не должны
    /// расходиться в оценке тревоги.
    private var alertColor: Color {
        guard let distance = env.location.distanceToNearest else { return Theme.accent }
        let radius = AlertEngine.effectiveRadius(speedKmh: env.location.speedKmh,
                                                 baseRadius: env.settings.alertRadius)
        if distance <= radius * 0.3 { return Theme.danger }
        if distance <= radius * 0.6 { return Theme.warning }
        return Theme.accent
    }
}
