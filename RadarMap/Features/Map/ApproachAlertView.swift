//
//  ApproachAlertView.swift
//  RadarMap
//
//  Полноэкранное предупреждение при приближении к камере — крупно, читается боковым зрением.
//
//  Внизу — две кнопки: «без звука» и «Радар!». Окно закрывает собой всю карту
//  вместе с колонкой и панелью поездки, а тап в любом месте его скрывает —
//  то есть ровно в те секунды, когда хочется заглушить голос или отметить
//  стоящую рядом треногу, обе кнопки были недоступны, и тап, адресованный
//  им, просто закрывал окно. Кнопки получают касание сами; мимо них — как
//  раньше, «скрыть».
//

import SwiftUI

struct ApproachAlertView: View {
    @Environment(AppEnvironment.self) private var env
    let camera: Camera
    let distance: Double
    let speedKmh: Double
    let relativeBearing: Double?
    let alertRadius: Double
    let onDismiss: () -> Void

    @State private var pulse = false

    private var tint: Color { camera.kind.tint }
    /// 0…1 — насколько близко (для кольца прогресса).
    private var proximity: Double {
        max(0, min(1, 1 - distance / max(alertRadius, 1)))
    }

    var body: some View {
        ZStack {
            // Затемняем карту, подсвечиваем цветом типа камеры.
            LinearGradient(colors: [tint.opacity(0.28), Theme.background.opacity(0.96)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Иконка типа + название
                VStack(spacing: 12) {
                    ZStack {
                        Circle().fill(tint.opacity(0.18)).frame(width: 130, height: 130)
                            .scaleEffect(pulse ? 1.12 : 0.92)
                            // Несколько вдохов и покой: вечный пульс держал
                            // перерисовку на 60 Гц весь показ (аудит 11.10).
                            .motionAnimation(.easeInOut(duration: 0.9).repeatCount(5, autoreverses: true), value: pulse)
                        Circle()
                            .trim(from: 0, to: proximity)
                            .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .frame(width: 118, height: 118)
                            .rotationEffect(.degrees(-90))
                        Image(systemName: camera.kind.symbolName)
                            .font(.system(size: 48, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Text(camera.kind.displayName)
                        .font(.rounded(20, .bold))
                        .foregroundStyle(.white)
                }

                // Расстояние — крупно
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text("\(Int(distance.rounded()))")
                        .font(.system(size: 88, weight: .heavy, design: .rounded))
                        .foregroundStyle(tint)
                        .liveNumber()
                    Text("м").font(.rounded(30, .bold)).foregroundStyle(Theme.textSecondary)
                }

                // Направление + скорость
                HStack(spacing: 22) {
                    if let rel = relativeBearing {
                        label(icon: "location.north.fill",
                              value: directionText(rel),
                              rotate: CameraDirection.arrowAngle(relativeBearing: rel))
                    }
                    label(icon: "gauge.with.dots.needle.67percent",
                          value: String(format: String(localized: "%lld км/ч"), Int(speedKmh)),
                          rotate: nil)
                }

                if !camera.location.isEmpty {
                    Text(camera.location)
                        .font(.rounded(14))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 32)
                }

                Spacer()
            }
            // VoiceOver: сведения — одна фраза + действие «скрыть»; кнопки ниже
            // остаются отдельными элементами.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Нажмите, чтобы скрыть"))
            .accessibilityAction { onDismiss() }

            VStack(spacing: 12) {
                Spacer()
                HStack(spacing: 12) {
                    muteButton
                    ReportRadarButton()
                }
                .padding(.horizontal, 24)
                Text("Нажмите, чтобы скрыть")
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 20)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .onAppear { pulse = true }
        .transition(.opacity.combined(with: .scale(scale: 1.05)))
    }

    /// «Без звука» во всю оставшуюся ширину: голос и сигнал обрываются сразу
    /// (AlertPlayer.hush), вибрация и само окно остаются — камера не исчезает,
    /// она молчит, как и у кнопки звука на карте.
    private var muteButton: some View {
        let muted = env.settings.isMuted
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            env.settings.setMuted(!muted)
            if !muted { env.alerts.hush() }
        } label: {
            Label(muted ? "Включить звук" : "Без звука",
                  systemImage: muted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.rounded(17, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 56)
                // Сплошная заливка, не материал: под окном — живая карта, и
                // размытие пересчитывалось бы на каждом её кадре.
                .background(Theme.surface,
                            in: RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }

    /// «Радар через 220 метров, прямо. Скорость 47 км/ч» — для VoiceOver.
    private var accessibilitySummary: String {
        var text = "\(camera.kind.displayName) — \(Formatting.distance(distance))"
        if let rel = relativeBearing { text += ", \(directionText(rel))" }
        text += ". " + String(format: String(localized: "Скорость %lld км/ч"), Int(speedKmh))
        return text
    }

    private func label(icon: String, value: String, rotate: Double?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.rounded(16, .semibold))
                .foregroundStyle(tint)
                .rotationEffect(.degrees(rotate ?? 0))
            Text(value).font(.rounded(18, .semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.surface, in: Capsule())
    }

    private func directionText(_ rel: Double) -> String {
        switch CameraDirection.classify(relativeBearing: rel) {
        case .ahead:       return String(localized: "прямо")
        case .right:       return String(localized: "справа")
        case .behindRight: return String(localized: "сзади справа")
        case .behindLeft:  return String(localized: "сзади слева")
        case .left:        return String(localized: "слева")
        }
    }
}
