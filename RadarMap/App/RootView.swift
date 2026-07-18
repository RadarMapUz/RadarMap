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
    @AppStorage(Storage.Key.hasCompletedOnboarding.rawValue) private var hasCompletedOnboarding = false
    #if DEBUG
    /// Скриншот-автоматизация: CarPlay-экран на телефоне (симулятор не даёт
    /// открыть CarPlay-дисплей без ручного клика по меню).
    @State private var carPlayPreview = ProcessInfo.processInfo.arguments.contains("-carplayPreview")
    #endif

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if hasCompletedOnboarding {
                MapScreen()
                    .transition(.opacity)
                    .modifier(ReviewPromptModifier())   // оценка App Store после 3-й чистой поездки
            } else {
                OnboardingView {
                    env.location.bootstrap()
                    withAnimation(.easeInOut) { hasCompletedOnboarding = true }
                }
                .transition(.opacity)
            }
        }
        // Виджет локскрина: radarmap://start-trip — поездка одним тапом с
        // заблокированного экрана. Активную поездку диплинк никогда не трогает.
        .onOpenURL { url in
            guard url.scheme == "radarmap", url.host() == "start-trip",
                  !env.location.isTripActive else { return }
            env.location.startTrip()
        }
        #if DEBUG
        .fullScreenCover(isPresented: $carPlayPreview) {
            CarPlayMapScreen(model: CarPlayMapModel())
                .environment(env)
                .background(Theme.background)
        }
        #endif
        .task {
            // Тихая проверка обновлений базы (не чаще раза в сутки), не блокирует UI.
            Task { await env.sync.autoCheckIfNeeded() }
            // Дослать репорты/фидбек, не ушедшие в прошлый раз (офлайн-очередь).
            Task { await env.feedback.flushPending() }
            env.speedLimits.start()   // база лимитов: локально сразу, сервер раз в неделю
            env.metrics.start()       // MetricKit: суточные отчёты о батарее/крашах
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
