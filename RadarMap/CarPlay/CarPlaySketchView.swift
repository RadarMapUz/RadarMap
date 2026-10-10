//
//  CarPlaySketchView.swift
//  RadarMap
//
//  Режим «Схема» на CarPlay: чертим сами, без MKMapView — а значит, без
//  тайлов, аннотаций и вообще самого дорогого GPU-рендера приложения.
//  Картинка в машину стримится С ТЕЛЕФОНА, так что карту в машине рисует и
//  греет именно телефон в держателе; схема оставляет те же предупреждения,
//  манёвры и док скорости, но за копейки: растр раз в сотни метров плюс три
//  transform'а на тик (модель схемы — SketchState; телефонной приборки,
//  делившей её раньше, больше нет).
//

import SwiftUI

struct CarPlaySketchView: View {
    @Environment(AppEnvironment.self) private var env
    /// Приходит от модели экрана: осмотр в машине начинает шаблон CarPlay,
    /// и состояние обязано быть общим с делегатом сцены.
    let sketch: SketchState

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Экран машины — не растянутый телефон. Он в два-три раза шире,
            // чем высок, а схема — вид ВПЕРЁД: полезное живёт на вертикальной
            // оси. Масштаб схемы считается от высоты, поэтому на всю ширину
            // она показывала втрое больше метров вбок, чем вперёд, и дорога
            // превращалась в нитку посреди чёрного поля. Поэтому широкий экран
            // делим: схеме — её пропорция, остальное отдаём ленте «что
            // впереди», которая отвечает на вопрос, не покрытый ничем другим:
            // а что будет ПОСЛЕ ближайшей камеры.
            GeometryReader { geometry in
                let wide = geometry.size.width >= AppConfig.carPlayWidePointsThreshold
                    || Self.forceWide
                let sketchHeight = geometry.size.height - AppConfig.carPlayDockReserve
                    - AppConfig.carPlayContentGap
                HStack(spacing: 14) {
                    canvas
                        .frame(maxWidth: wide
                               ? min(geometry.size.width - AppConfig.carPlayAheadPanelWidth - 14,
                                     sketchHeight * AppConfig.carPlaySketchMaxAspect)
                               : .infinity)
                    if wide {
                        CarPlayAheadPanel()
                            .frame(width: AppConfig.carPlayAheadPanelWidth)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, AppConfig.carPlayDockReserve + AppConfig.carPlayContentGap)
                .padding(.horizontal, 12)
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

    /// Широкая раскладка принудительно. Превью CarPlay на симуляторе имеет
    /// форму телефона — портрет, — и деления экрана в нём не увидеть вовсе,
    /// хотя именно оно и есть весь смысл правки. Хук позволяет снять
    /// композицию, не садясь в машину.
    private static var forceWide: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-carplayWide")
        #else
        false
        #endif
    }

    /// Сама схема или её ожидание — в одном месте, чтобы раскладка выше не
    /// повторяла условие дважды.
    @ViewBuilder
    private var canvas: some View {
        // Без курса схема рисуется севером вверху, а не прячется: где мы —
        // известно точно, и это стоит показать.
        if let scene = sketch.scene, !scene.isEmpty {
            RoadSketchView(scene: scene, state: sketch, tint: alertColor,
                           strokeScale: AppConfig.carPlaySketchStrokeScale,
                           trim: env.thermal.mode.sketchTrim,
                           cursorStyle: env.settings.cursorStyle)
                // Стоим и курса нет: рисуем «последнее, что знали»,
                // приглушённо — как на приборке телефона.
                .opacity(env.location.currentCourse < 0 ? 0.45 : 1)
                .motionAnimation(.easeOut(duration: 0.4),
                           value: env.location.currentCourse < 0)
        } else {
            sketchWaiting
        }
    }

    /// Схема ждёт движения. Один круг, не два: двойное кольцо было
    /// декоративным шумом, а состояние должно выглядеть состоянием.
    private var sketchWaiting: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Theme.stroke, lineWidth: 1)
                    .frame(width: 84, height: 84)
                Image(systemName: "road.lanes")
                    .font(.rounded(26, .medium))
                    .foregroundStyle(Theme.accent.opacity(0.9))
            }
            VStack(spacing: 4) {
                Text("Схема появится в движении")
                    .font(.rounded(19, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text("Пока машина стоит, направление неизвестно")
                    .font(.rounded(15))
                    .foregroundStyle(Theme.textTertiary)
            }
            .multilineTextAlignment(.center)
        }
    }

    /// Тон тревоги. Первое слово — за уровнем конвейера оповещений: это тот же
    /// уровень, что красит кромку дока, и расходиться им нельзя (раньше пороги
    /// были разные, и схема могла гореть янтарным при красном доке). Дистанция
    /// остаётся фолбэком для «камера уже в охвате, но алерт ещё не начался».
    private var alertColor: Color {
        switch env.location.alertLevel {
        case 3...: return Theme.danger
        case 2:    return Theme.warning
        case 1:    return Theme.warning
        default: break
        }
        guard let distance = env.location.distanceToNearest else { return Theme.accent }
        let radius = AlertEngine.effectiveRadius(speedKmh: env.location.speedKmh,
                                                 baseRadius: env.settings.alertRadius,
                                                 context: env.location.alertContext)
        if distance <= radius * 0.3 { return Theme.danger }
        if distance <= radius * 0.6 { return Theme.warning }
        return Theme.accent
    }
}
