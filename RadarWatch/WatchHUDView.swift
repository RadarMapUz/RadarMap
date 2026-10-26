//
//  WatchHUDView.swift
//  RadarWatch
//
//  HUD на запястье (9.3). Главное — дистанция до камеры и знак ограничения:
//  взгляд на часы длится секунду, и спрашивает он «далеко ли камера и сколько
//  тут можно». Скорость — только в тревоге или при превышении и цветом против
//  лимита: в спокойном режиме она шла ступенью 5 км/ч раз в 10 с, то есть
//  была старой цифрой на руке. Внизу — «Радар!»: телефон в держателе, рука на
//  руле, запястье ближе экрана.
//

import SwiftUI

struct WatchHUDView: View {
    @Environment(WatchSession.self) private var session

    var body: some View {
        Group {
            if session.isTripActive {
                tripHUD
            } else {
                idleView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: - Поездка

    private var tripHUD: some View {
        VStack(spacing: 6) {
            cameraRow
            Spacer(minLength: 0)
            speedRow
            Spacer(minLength: 0)
            reportButton
        }
        .padding(.horizontal, 4)
        .animation(.easeOut(duration: 0.25), value: session.alertLevel)
    }

    /// Камера: значок типа на диске, дистанция цветом уровня, адрес в строку.
    @ViewBuilder
    private var cameraRow: some View {
        if let distance = session.distanceMeters {
            HStack(spacing: 8) {
                // Значок «Монета» типа (29.C) — как на карте и в HUD телефона.
                let glyph = CameraGlyph(symbol: session.cameraSymbol) ?? .camera
                CameraCoinView(glyph: glyph, fill: color(glyph.fillRGB), ink: color(glyph.inkRGB), side: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(distanceText(distance))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WatchTheme.level(session.alertLevel))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text(session.cameraTitle ?? String(localized: "до камеры"))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(WatchTheme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(WatchTheme.successFill, in: Circle())
                    .accessibilityHidden(true)
                Text("Камер рядом нет")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(WatchTheme.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
        }
    }

    /// Скорость (в тревоге или при превышении) слева, знак ограничения справа.
    private var speedRow: some View {
        HStack(alignment: .center, spacing: 6) {
            if let speed = session.speedKmh {
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text("\(speed)")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(session.isOverspeeding ? WatchTheme.danger : WatchTheme.primary)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .layoutPriority(1)
                    // «km/soat» на 40 мм переносился и ломал базовую линию.
                    Text("км/ч")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(WatchTheme.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
            if let limit = session.limitKmh {
                WatchLimitSign(limit: limit, size: session.speedKmh == nil ? 46 : 38)
            }
        }
    }

    private var reportButton: some View {
        Button {
            session.sendReport()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: reportSymbol)
                    .font(.system(size: 13, weight: .bold))
                    .accessibilityHidden(true)
                reportTitle
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(reportForeground)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(reportFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(session.report == .sending)
    }

    // MARK: - Ожидание

    private var idleView: some View {
        VStack(spacing: 8) {
            Image(systemName: "car.fill")
                .font(.system(size: 30))
                .foregroundStyle(WatchTheme.accent)
            Text("Поездка не идёт.")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(WatchTheme.primary)
            Text(session.isReachable
                 ? String(localized: "Начните поездку на iPhone — скорость и камеры появятся здесь.")
                 : String(localized: "Откройте RadarMap на iPhone."))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(WatchTheme.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Помощники

    private var reportSymbol: String {
        switch session.report {
        case .done(ok: true): return "checkmark"
        case .done(ok: false): return "xmark"
        case .pending: return "ellipsis"
        case .sending, nil: return "dot.radiowaves.left.and.right"
        }
    }

    @ViewBuilder
    private var reportTitle: some View {
        switch session.report {
        case .done(ok: true): Text("Отмечено")
        case .done(ok: false): Text("Не отправлено")
        case .pending: Text("Отправляется")
        case .sending, nil: Text("Радар!")
        }
    }

    private var reportForeground: Color {
        switch session.report {
        case .done?, .pending?: return .white
        case .sending?, nil: return WatchTheme.onAction
        }
    }

    private var reportFill: Color {
        switch session.report {
        case .done(ok: true): return WatchTheme.successFill
        case .done(ok: false), .pending: return WatchTheme.primary.opacity(0.22)
        case .sending: return WatchTheme.action.opacity(0.6)
        case nil: return WatchTheme.action
        }
    }

    private func distanceText(_ meters: Int) -> String {
        if meters >= 1000 {
            // По языку приложения, не по региону часов (Shared/NumberFormat).
            let km = NumberFormat.decimal(Double(meters) / 1000)
            return String(format: String(localized: "%@ км"), km)
        }
        return String(format: String(localized: "%@ м"), String(meters))
    }

    private func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

/// Знак ограничения — белый круг с красной каймой, как на дороге, на
/// карточке скорости в приложении и на плашке.
private struct WatchLimitSign: View {
    let limit: Int
    let size: CGFloat

    var body: some View {
        Text("\(limit)")
            .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
            .foregroundStyle(.black)
            .minimumScaleFactor(0.6)
            .frame(width: size, height: size)
            .background(Circle().fill(.white))
            .overlay(Circle().stroke(Color(red: 0.86, green: 0.16, blue: 0.16), lineWidth: size * 0.12))
            .accessibilityLabel(Text(String(format: String(localized: "Ограничение %lld"), limit)))
    }
}
