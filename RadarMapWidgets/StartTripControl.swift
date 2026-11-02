//
//  StartTripControl.swift
//  RadarMapWidgets
//
//  «Начать поездку» в Пункте управления, на экране блокировки и на кнопке
//  действия (iOS 18). Тот же диплинк, что у виджета локскрина:
//  radarmap://start-trip?k=<ключ> — RootView начинает поездку и никогда не
//  трогает уже идущую. Ссылка, а не своё намерение: намерение старта живёт в
//  приложении (AppEnvironment), и тащить его в расширение ради одной
//  кнопки — вторая копия логики старта.
//

import AppIntents
import SwiftUI
import WidgetKit

struct StartTripControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "uz.radarmap.ios.start-trip") {
            ControlWidgetButton(action: OpenURLIntent(Self.url)) {
                Label("Начать поездку", systemImage: "car.fill")
            }
        }
        .displayName("Начать поездку")
        .description("Поездка с предупреждениями о камерах — одним нажатием")
    }

    /// С ключом своих кнопок из App Group: по нему приложение стартует без
    /// вопроса (TripLink). Свойство, а не константа — ключ появляется после
    /// первого открытия приложения.
    private static var url: URL { TripLink.ownStartURL }
}
