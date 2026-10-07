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
                // Тема: днём светлая, ночью тёмная — по настройке подложки
                // (env.interfaceIsDaylight). Двумя модификаторами намеренно:
                // preferredColorScheme просит систему об окне нужной темы
                // (статус-бар), а environment ЗАДАЁТ схему нашему дереву —
                // адаптивные токены Theme, материалы и стекло берут её оттуда.
                // Одного первого мало: если вид приложения переопределён в
                // настройках iOS, окно осталось бы в чужой теме.
                .preferredColorScheme(env.interfaceIsDaylight ? .light : .dark)
                .environment(\.colorScheme, env.interfaceIsDaylight ? .light : .dark)
                .tint(Theme.accent)
        }
    }
}
