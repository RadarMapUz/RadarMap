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

    init() {
        #if DEBUG
        // Сторож подвисаний main (см. HitchWatch): каждый дебаг-прогон сам
        // ловит фризы дольше 250 мс и пишет их фолтом в лог.
        HitchWatch.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                // Тёмный «радар-детектор» стиль. Двумя модификаторами намеренно:
                // preferredColorScheme просит систему о тёмном окне (статус-бар),
                // а environment ЗАДАЁТ схему нашему дереву — материалы, стекло и
                // карта берут её оттуда. Одного первого мало: если вид приложения
                // переопределён в настройках iOS, окно остаётся светлым, стекло
                // становится белёсым и белые иконки на нём пропадают.
                .preferredColorScheme(.dark)
                .environment(\.colorScheme, .dark)
                .tint(Theme.accent)
        }
    }
}
