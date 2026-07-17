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
        }
    }
}
