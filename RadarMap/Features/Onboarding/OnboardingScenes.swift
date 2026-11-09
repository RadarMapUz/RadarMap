//
//  OnboardingScenes.swift
//  RadarMap
//
//  Иллюстрации онбординга — из самого приложения, а не стоковые значки.
//
//  До 13.10 каждая страница открывалась большим SF-символом в синем круге:
//  колокольчик, микрофон, карта — одинаковые и ни о чём. Человек, который
//  видит приложение впервые, должен увидеть ТО, что увидит на дороге: дорогу
//  с камерой впереди и плашку «240 м до камеры», фразы, которые скажет
//  голос, жёлтую кнопку «Радар!» и отметку с «?». Все сцены собраны из тех же
//  элементов, что и экран поездки (знак лимита, значок «я», маркер камеры),
//  поэтому обещание на иллюстрации совпадает с тем, что будет на экране.
//
//  Движется только сцена первого экрана: это обещание приложения в семи секундах.
//

import SwiftUI

/// Едем к камере: расстояние тает, голос предупреждает, камера проезжает мимо.
/// Те же элементы, что на экране поездки. При «Уменьшении движения» — один
/// неподвижный кадр.
struct OnboardingRoadScene: View {
    var playing = true
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cycleSeconds = 7.0
    private static let startMeters = 420.0
    /// Доля цикла, на которой камера поравнялась с машиной.
    private static let passedAt = 0.82
    /// Неподвижный кадр: 240 м до камеры.
    private static let stillProgress = (1 - 240 / startMeters) * passedAt

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing || reduceMotion)) { context in
            let moving = playing && !reduceMotion
            let seconds = moving ? context.date.timeIntervalSinceReferenceDate : 0
            frame(progress: moving ? (seconds / Self.cycleSeconds).truncatingRemainder(dividingBy: 1)
                               : Self.stillProgress,
                  seconds: seconds, moving: moving)
        }
        .frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .accessibilityHidden(true)
    }

    private func frame(progress p: Double, seconds: Double, moving: Bool) -> some View {
        let approach = min(1, p / Self.passedAt)
        let meters = Self.startMeters * (1 - approach)
        let passed = p >= Self.passedAt
        let voiceOn = moving && meters < 310 && meters > 170
        // История целиком: 72 при лимите 60, голос, сбросили до 58, проехали.
        let braking = moving ? Self.ease((p - 0.26) / 0.3) : 1
        let speed = Int((72 - 14 * braking).rounded())
        let depth = pow(approach, 1.7)
        let cameraFade = passed ? max(0, 1 - (p - Self.passedAt) / 0.08) : (moving ? min(1, p / 0.05) : 1)
        // На стыке циклов плашка гаснет и загорается, а не прыгает.
        let plate = moving ? min(1, min(p, 1 - p) / 0.03) : 1
        return GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                    .fill(Theme.Scene.grass)
                trees(seconds: seconds, size: geo.size)
                RoadStripe(phase: CGFloat(-seconds * 90))
                CameraMark(kind: .stationaryCamera, alert: true)
                    .scaleEffect(0.7 + 0.5 * depth)
                    .position(x: geo.size.width / 2 + 34 + 62 * depth, y: 96 + 190 * depth)
                    .opacity(cameraFade)
                MeCursor(scale: 1.4, style: env.settings.cursorStyle)
                    .frame(width: 42, height: 50)
                    .position(x: geo.size.width / 2, y: geo.size.height - 56)
                voice(on: voiceOn, moving: moving)
                    .position(x: geo.size.width / 2, y: geo.size.height - 112)
                plateView(meters: meters, speed: speed, passed: passed)
                    .opacity(plate)
                    .position(x: geo.size.width / 2, y: 44)
            }
        }
    }

    private static func ease(_ t: Double) -> Double {
        let x = max(0, min(1, t))
        return x * x * (3 - 2 * x)
    }

    /// Деревья на обочине растут к краю кадра: скорость чувствуется боковым зрением.
    private func trees(seconds: Double, size: CGSize) -> some View {
        ForEach(0..<8, id: \.self) { index in
            let t = (seconds * 0.34 + Double(index) / 8).truncatingRemainder(dividingBy: 1)
            let side: CGFloat = index.isMultiple(of: 2) ? -1 : 1
            let diameter = CGFloat(10 + 30 * t * t)
            let edge = size.width * CGFloat(0.30 + 0.14 * t)
            Circle()
                .fill(Theme.success.opacity(0.26))
                .frame(width: diameter, height: diameter)
                .position(x: size.width / 2 + side * (edge + 10 + diameter / 2),
                          y: size.height * CGFloat(t * t))
        }
    }

    private func voice(on: Bool, moving: Bool) -> some View {
        HStack(spacing: 8) {
            OnboardingVoiceBars(playing: on)
            Text("«Камера, 300 метров»")
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .liftedBackground(Theme.surface, in: Capsule())
        .scaleEffect(on ? 1 : 0.85, anchor: .bottom)
        .opacity(on ? 1 : 0)
        .animation(moving ? .spring(response: 0.3, dampingFraction: 0.7) : nil, value: on)
    }

    private func plateView(meters: Double, speed: Int, passed: Bool) -> some View {
        HStack(spacing: 10) {
            if passed {
                Image(systemName: "checkmark.seal.fill")
                    .font(.rounded(24))
                    .foregroundStyle(Theme.success)
                Text("Проехали в лимите")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
            } else {
                CameraIcon(kind: .stationaryCamera, side: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: Formatting.distance((meters / 10).rounded() * 10))
                        .font(.numeral(20, .heavy).monospacedDigit())
                        .foregroundStyle(meters < 310 ? Theme.danger : Theme.textPrimary)
                    Text("до камеры").font(.rounded(11)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            SpeedLimitSign(limit: 60, diameter: 30)
            Text(verbatim: "\(speed)")
                .font(.numeral(20, .heavy).monospacedDigit())
                .foregroundStyle(speed > 60 ? Theme.danger : Theme.textPrimary)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .liftedBackground(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        .padding(.horizontal, 14)
    }
}

/// Маркер камеры как на карте (вариант B, значок «Монета» 29.C): цвет типа,
/// белый кант; тревога крупнее и с ореолом; неподтверждённая — пунктир и «?».
private struct CameraMark: View {
    let kind: CameraType
    var alert = false
    var ghost = false

    var body: some View {
        let side: CGFloat = alert ? 48 : 40
        ZStack(alignment: .topTrailing) {
            ZStack {
                if alert {
                    Circle().fill(Theme.Types.camera.opacity(0.18)).frame(width: side + 34, height: side + 34)
                }
                CameraIcon(kind: kind, side: side, shadow: true, dashedRim: ghost)
                    .opacity(ghost ? 0.65 : 1)
            }
            if ghost {
                Text("?")
                    .font(.rounded(11, .heavy)).foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Theme.Types.post, in: Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .offset(x: 4, y: -2)
            }
        }
        .frame(width: side + 34, height: side + 34)
    }
}

/// Дорога снизу вверх с лёгкой перспективой и пунктиром.
private struct RoadStripe: View {
    var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let top = CGFloat(0.30), bottom = CGFloat(0.44)
            Path { p in
                p.move(to: CGPoint(x: w * (0.5 - top), y: 0))
                p.addLine(to: CGPoint(x: w * (0.5 + top), y: 0))
                p.addLine(to: CGPoint(x: w * (0.5 + bottom), y: h))
                p.addLine(to: CGPoint(x: w * (0.5 - bottom), y: h))
                p.closeSubpath()
            }
            .fill(Theme.Scene.asphalt)
            Path { p in
                p.move(to: CGPoint(x: w * 0.5, y: 0))
                p.addLine(to: CGPoint(x: w * 0.5, y: h))
            }
            .stroke(Theme.Scene.marking, style: StrokeStyle(lineWidth: 3, dash: [14, 12], dashPhase: phase))
            ForEach([0.5 - top, 0.5 + top], id: \.self) { x0 in
                let x1 = x0 < 0.5 ? 0.5 - bottom : 0.5 + bottom
                Path { p in
                    p.move(to: CGPoint(x: w * x0, y: 0))
                    p.addLine(to: CGPoint(x: w * x1, y: h))
                }
                .stroke(Theme.Scene.kerb, lineWidth: 2)
            }
        }
    }
}
