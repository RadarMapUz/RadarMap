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
                // Нейтральная «N» с остриём на север, а не красная стрелка:
                // красное на этой карте значит камеру, а стрелка путалась с
                // соседней кнопкой «по ходу» (аудит 19.10, 4.1).
                VStack(spacing: -1) {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.rounded(8, .bold))
                    Text(verbatim: "N")
                        .font(.rounded(14, .heavy))
                }
                .foregroundStyle(Theme.textPrimary)
                .rotationEffect(.degrees(-map.displayedDirection))
                .controlCircle()
            }
            .buttonStyle(PressableStyle())
            .tapTarget()
            .accessibilityLabel(Text("Север вверху"))
            .transition(.scale.combined(with: .opacity))
        }
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
        // Тень у капсулы, а не у глифов поверх неё (см. View.statCard).
        .background {
            Capsule().fill(Theme.surface)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
        .overlay(Capsule().strokeBorder(Theme.edgeControl, lineWidth: 1))
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
            if !muted { env.alerts.hush() }   // тишина сразу, а не после фразы
        } label: {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.rounded(17, .semibold))
                .foregroundStyle(muted ? Theme.danger : Theme.textPrimary)
                .controlCircle()
        }
        .buttonStyle(PressableStyle())
        .tapTarget()
        .accessibilityLabel((muted ? Text("Звук выключен") : Text("Звук включён")))
        .accessibilityHint((muted ? Text("Включить голос и сигналы") : Text("Выключить голос и сигналы")))
    }
}
