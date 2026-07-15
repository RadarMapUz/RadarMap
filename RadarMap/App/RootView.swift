//
//  RootView.swift
//  RadarMap
//
//  Корневой экран: онбординг → карта. Управляет foreground/background режимом геолокации.
//

import SwiftUI
import WidgetKit

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if hasCompletedOnboarding {
                MapScreen()
                    .transition(.opacity)
            } else {
                OnboardingView {
                    env.location.bootstrap()
                    withAnimation(.easeInOut) { hasCompletedOnboarding = true }
                }
                .transition(.opacity)
            }
        }
        .task {
            // Тихая проверка обновлений базы (не чаще раза в сутки), не блокирует UI.
            Task { await env.sync.autoCheckIfNeeded() }
            env.speedLimits.start()   // база лимитов: локально сразу, сервер раз в неделю
            guard hasCompletedOnboarding else { return }
            env.location.bootstrap()
            env.location.setForeground(true)
            env.mobile.startPolling()
            env.motion.start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard hasCompletedOnboarding else { return }
            switch phase {
            case .active:
                env.location.setForeground(true)
                env.mobile.startPolling()
                env.motion.start()
            case .background, .inactive:
                env.location.setForeground(false)   // в поездке непрерывный GPS продолжит работать
                env.mobile.stopPolling()             // в фоне не опрашиваем сервер — батарея
                snapshotForWidget()
            @unknown default:
                break
            }
        }
    }

    /// Снимок данных для домашнего виджета (через App Group).
    private func snapshotForWidget() {
        SharedDefaults.write(SharedDefaults.Snapshot(
            dbCount: env.cameras.cameras.count,
            dbVersion: env.cameras.dbVersion,
            mobileCount: env.cameras.mobile.count,
            tripCameras: env.trip.camerasPassed,
            tripMaxSpeed: env.trip.maxSpeedKmh,
            tripDistance: env.trip.distanceMeters
        ))
        WidgetCenter.shared.reloadAllTimelines()
    }
}
