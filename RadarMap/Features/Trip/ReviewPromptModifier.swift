//
//  ReviewPromptModifier.swift
//  RadarMap
//
//  Просьба об оценке App Store — только на позитиве: после завершения
//  «чистой» поездки, когда таких набралось три. Не чаще раза на версию,
//  системный диалог (iOS сам решит, показывать ли вообще).
//

import SwiftUI
import StoreKit

struct ReviewPromptModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.requestReview) private var requestReview

    func body(content: Content) -> some View {
        content.onChange(of: env.location.isTripActive) { wasActive, isActive in
            guard wasActive, !isActive else { return }   // поездка только что завершилась
            maybeAskReview()
        }
    }

    private func maybeAskReview() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        guard Storage.string(.reviewAskedVersion) != version else { return }
        // Свежая поездка чистая и таких минимум три — водитель доволен приложением,
        // а не закрывает алерт о «письме счастья».
        guard env.trip.history.first?.isClean == true,
              env.trip.history.filter(\.isClean).count >= 3 else { return }
        Storage.set(version, for: .reviewAskedVersion)
        Task {
            await Task.pause(seconds: 2)   // итоговые панели улеглись, диалог не влезает в анимации
            requestReview()
        }
    }
}
