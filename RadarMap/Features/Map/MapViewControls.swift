//
//  MapViewControls.swift
//  RadarMap
//
//  Кнопки вида карты, как у навигаторов: компас, 2D/3D, масштаб, звук.
//
//  Все — ЛИСТЬЯ: каждая читает только своё (поворот карты, 3D, звук), и
//  главный экран из-за них не пересобирается — его body и так на пределе
//  (docs/perf_audit_2026-10-07.md). Действуют на общий MapState, поэтому
//  значат одно и то же на карте Apple и на движке.
//

import SwiftUI

/// Компас: виден, только когда карта повёрнута. Стрелка показывает север;
/// тап — север вверх и слежение за машиной. Вечный компас при карте строго
/// на север не значит ничего — поэтому он и прячется (как у системных карт).
struct MapCompassButton: View {
    @Environment(AppEnvironment.self) private var env
    let map: MapState

    var body: some View {
        if map.isRotated {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                map.showNorth(coordinate: env.location.currentCoordinate,
                              inTrip: env.location.isTripActive)
            } label: {
                ZStack {
                    Image(systemName: "location.north.fill")
                        .font(.rounded(17, .bold))
                        .foregroundStyle(Theme.danger)
                        .rotationEffect(.degrees(-map.displayedDirection))
                }
                .controlCircle()
            }
            .buttonStyle(PressableStyle())
            .tapTarget()
            .accessibilityLabel(Text("Север вверху"))
            .transition(.scale.combined(with: .opacity))
        }
    }
}

/// 2D / 3D. Подпись — то, что сейчас НА ЭКРАНЕ (как у Яндекса: «3D» горит,
/// когда карта наклонена).
struct Map3DToggle: View {
    @Environment(AppEnvironment.self) private var env
    let map: MapState

    var body: some View {
        let on = env.settings.map3D
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            env.settings.map3D.toggle()
            map.prefers3D = env.settings.map3D
        } label: {
            Text(on ? "3D" : "2D")
                .font(.rounded(15, .heavy))
                .foregroundStyle(on ? Theme.accent : Theme.textPrimary)
                .controlCircle()
        }
        .buttonStyle(PressableStyle())
        .tapTarget()
        .accessibilityLabel(Text(on ? "Объёмный вид, включён" : "Плоский вид"))
        .onAppear { map.prefers3D = on }
    }
}

/// «+ / −» одной капсулой. Сдвигают автозум вдвое за нажатие, а не
/// выключают его: на скорости карта по-прежнему отодвигается сама.
struct MapZoomButtons: View {
    let map: MapState

    var body: some View {
        VStack(spacing: 0) {
            zoomButton("plus", delta: 1, label: "Приблизить")
            Rectangle().fill(Theme.stroke).frame(width: 24, height: 1)
            zoomButton("minus", delta: -1, label: "Отдалить")
        }
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.edgeControl, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    private func zoomButton(_ symbol: String, delta: Double, label: LocalizedStringKey) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            map.zoomStep(delta)
        } label: {
            Image(systemName: symbol)
                .font(.rounded(17, .bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: Theme.controlSize, height: Theme.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text(label))
    }
}

/// Звук одной кнопкой: голос и сигналы. Вибрация и экран тревоги остаются —
/// камера не пропадает, она молчит; перечёркнутый динамик это и говорит.
struct MapMuteButton: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let muted = env.settings.isMuted
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            env.settings.setMuted(!muted)
        } label: {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.rounded(17, .semibold))
                .foregroundStyle(muted ? Theme.danger : Theme.textPrimary)
                .controlCircle()
        }
        .buttonStyle(PressableStyle())
        .tapTarget()
        .accessibilityLabel(Text(muted ? "Звук выключен" : "Звук включён"))
        .accessibilityHint(Text(muted ? "Включить голос и сигналы" : "Выключить голос и сигналы"))
    }
}
