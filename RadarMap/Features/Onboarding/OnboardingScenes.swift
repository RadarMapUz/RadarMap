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
//  Всё статично: онбординг показывают один раз, и анимация здесь — батарея,
//  а не смысл.
//

import SwiftUI

/// Дорога с камерой впереди и плашкой расстояния — первое, что приложение
/// делает, и первое, что о нём надо понять.
struct OnboardingRoadScene: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .fill(Theme.adaptive(0xE4ECD8, 0x1A2420))
            // Дорога: полотно, кромки, пунктир осевой.
            RoadStripe()
            // Камера впереди — маркер «на пути» (цвет типа, белое кольцо, ореол).
            VStack(spacing: 0) {
                CameraMark(kind: .stationaryCamera, alert: true)
                    .padding(.top, 34)
                Spacer()
            }
            // «Я» — значок из настроек, носом вверх.
            VStack {
                Spacer()
                MeCursor(scale: 1.4, style: env.settings.cursorStyle)
                    .frame(width: 42, height: 50)
                    .padding(.bottom, 26)
            }
            // Плашка HUD — та же, что в поездке, только короче.
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    Circle().fill(Theme.Types.camera).frame(width: 30, height: 30)
                        .overlay(Image(systemName: "camera.fill").font(.rounded(13, .bold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("240 м").font(.rounded(20, .heavy)).foregroundStyle(Theme.danger)
                        Text("до камеры").font(.rounded(11)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    SpeedLimitSign(limit: 60, diameter: 30)
                    Text("58").font(.rounded(20, .heavy).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .liftedBackground(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                .padding(.horizontal, 18)
                .padding(.bottom, 96)
            }
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Фразы голоса: короткая в городе, полная на трассе, молчание у своей.
struct OnboardingVoiceScene: View {
    var body: some View {
        VStack(spacing: 10) {
            bubble("Камера, 300 метров", icon: "building.2.fill", tint: Theme.accent)
            bubble("По маршруту радар через 800 метров", icon: "road.lanes", tint: Theme.accent)
            bubble("Своя камера — молчу, только вибрация", icon: "checkmark.circle.fill", tint: Theme.success, quiet: true)
            bubble("Превышение! Камера, 200 метров", icon: "exclamationmark.triangle.fill", tint: Theme.danger)
        }
        .padding(16)
        .background(Theme.adaptive(0xE9EEF6, 0x1A1F26),
                    in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .accessibilityHidden(true)
    }

    private func bubble(_ text: LocalizedStringKey, icon: String, tint: Color, quiet: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.rounded(14, .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: Circle())
            Text(text)
                .font(.rounded(15, quiet ? .regular : .semibold))
                .foregroundStyle(quiet ? Theme.textSecondary : Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: quiet ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.rounded(12))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
    }
}

/// Кнопка «Радар!» и путь отметки: неподтверждённая «?» → подтверждённая.
struct OnboardingCommunityScene: View {
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            step {
                Image(systemName: Icon.reportRadar)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.onAction)
                    .frame(width: 74, height: 74)
                    .background(Theme.action, in: RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous))
            } caption: { Text("Радар!") }
            arrow
            step { CameraMark(kind: .mobileRadar, alert: false, ghost: true) } caption: { Text("отметка") }
            arrow
            step { CameraMark(kind: .mobileRadar, alert: false) } caption: { Text("подтверждена") }
        }
        .padding(.vertical, 24).padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(Theme.adaptive(0xE9EEF6, 0x1A1F26),
                    in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .accessibilityHidden(true)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.rounded(16, .bold)).foregroundStyle(Theme.textTertiary)
            .frame(height: 74)
    }

    /// Шаг пути отметки: картинка и подпись одной ширины, подпись в строку.
    private func step<Picture: View, Caption: View>(@ViewBuilder _ picture: () -> Picture,
                                                    @ViewBuilder caption: () -> Caption) -> some View {
        VStack(spacing: 8) {
            picture().frame(height: 74)
            caption()
                .font(.rounded(12, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Детали сцен

/// Маркер камеры как на карте (вариант B): цвет типа, белое кольцо; тревога
/// крупнее и с ореолом; неподтверждённая — пунктир и «?».
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
                Circle().fill(kind.tint).frame(width: side, height: side)
                    .overlay(Circle().strokeBorder(style: StrokeStyle(lineWidth: 3, dash: ghost ? [5, 4] : []))
                        .foregroundStyle(.white))
                    .opacity(ghost ? 0.6 : 1)
                Image(systemName: kind.symbolName)
                    .font(.system(size: alert ? 20 : 16, weight: .bold))
                    .foregroundStyle(kind.glyphTint)
                    .opacity(ghost ? 0.7 : 1)
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
            .fill(Theme.adaptive(0xC9D0DA, 0x2E353F))
            Path { p in
                p.move(to: CGPoint(x: w * 0.5, y: 0))
                p.addLine(to: CGPoint(x: w * 0.5, y: h))
            }
            .stroke(Theme.adaptive(0xFFFFFF, 0x6B7380), style: StrokeStyle(lineWidth: 3, dash: [14, 12]))
            ForEach([0.5 - top, 0.5 + top], id: \.self) { x0 in
                let x1 = x0 < 0.5 ? 0.5 - bottom : 0.5 + bottom
                Path { p in
                    p.move(to: CGPoint(x: w * x0, y: 0))
                    p.addLine(to: CGPoint(x: w * x1, y: h))
                }
                .stroke(Theme.adaptive(0xE3B341, 0x8C7033), lineWidth: 2)
            }
        }
    }
}
