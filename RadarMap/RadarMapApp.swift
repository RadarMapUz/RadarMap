//
//  RadarMapApp.swift
//  RadarMap
//
//  Created by Zafarbek Polvonboev on 14/07/26.
//

import SwiftUI

@main
struct RadarMapApp: App {
    @State private var env = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .preferredColorScheme(.dark)   // тёмный «радар-детектор» стиль (в т.ч. тёмная карта)
                .tint(Theme.accent)
        }
    }
}
