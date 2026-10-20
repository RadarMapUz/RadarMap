//
//  RadarWatchApp.swift
//  RadarWatch
//
//  Часы — дисплей поездки (как CarPlay): телефон считает скорость, ближайшую
//  камеру и уровень тревоги, часы показывают HUD и «тукают» по запястью.
//  GPS на часах не включаем — батарея обоих устройств целее.
//

import SwiftUI

@main
struct RadarWatchApp: App {
    @State private var session = WatchSession()

    var body: some Scene {
        WindowGroup {
            WatchHUDView()
                .environment(session)
            #if DEBUG
                .onAppear {
                    if CommandLine.arguments.contains("-demo") { session.seedDemo() }
                }
            #endif
        }
        // Контекст с телефона, пока приложение спит, — ради компликации (9.3б).
        .backgroundTask(.watchConnectivity) {
            await WatchSession.drainPendingContent()
        }
    }
}
