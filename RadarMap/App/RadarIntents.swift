//
//  RadarIntents.swift
//  RadarMap
//
//  App Intents: Siri / Shortcuts / кнопка «Действие». «Начать поездку» работает
//  без открытия приложения — intent запускает процесс в фоне, а доступ «Всегда»
//  позволяет включить непрерывный GPS прямо оттуда. Руки остаются на руле.
//

import AppIntents
import CoreLocation
import Foundation

struct StartTripIntent: AppIntent {
    static let title: LocalizedStringResource = "Начать поездку"
    static let description = IntentDescription(
        "Включает оповещения о камерах и запись поездки.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = AppEnvironment.shared
        // Именно «Всегда», а не любой доступ: фраза Сири может поднять процесс
        // В ФОНЕ, и с «При использовании» непрерывный GPS не запустится —
        // ответ «Поехали» был бы ложным обещанием ровно в сценарии
        // «руки на руле».
        guard env.location.authorizationStatus == .authorizedAlways else {
            return .result(dialog: IntentDialog(
                "Нет доступа к геолокации. Откройте RadarMap и разрешите «Всегда»."))
        }
        if env.location.isTripActive {
            return .result(dialog: IntentDialog("Поездка уже идёт."))
        }
        env.location.startTrip()
        return .result(dialog: IntentDialog("Поехали. Слежу за камерами."))
    }
}

struct EndTripIntent: AppIntent {
    static let title: LocalizedStringResource = "Завершить поездку"
    static let description = IntentDescription(
        "Останавливает запись и сохраняет итоги поездки.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = AppEnvironment.shared
        guard env.location.isTripActive else {
            return .result(dialog: IntentDialog("Поездка не идёт."))
        }
        let distance = Formatting.distance(env.trip.distanceMeters)
        let cameras = env.trip.camerasPassed
        env.location.endTrip()
        return .result(dialog: IntentDialog(
            "Готово: \(distance), камер — \(cameras). Итоги в приложении."))
    }
}

struct ReportRadarIntent: AppIntent {
    static let title: LocalizedStringResource = "Радар здесь"
    static let description = IntentDescription(
        "Отмечает передвижной радар в текущей точке — другие водители увидят его на карте.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = AppEnvironment.shared
        // Холодный старт из Siri: GPS ещё не тикал — просим одноразовый фикс и ждём.
        guard let coordinate = await env.location.awaitCoordinate() else {
            return .result(dialog: IntentDialog("Не вижу геопозицию — попробуйте ещё раз."))
        }
        switch await env.mobile.report(at: coordinate) {
        case .created:
            return .result(dialog: IntentDialog("Радар отмечен. Спасибо, что предупредили!"))
        case .confirmed:
            return .result(dialog: IntentDialog("Радар здесь уже отмечен — подтвердили."))
        case .failed:
            return .result(dialog: IntentDialog("Не получилось отправить — нет связи."))
        }
    }
}

/// Фразы для Siri без настройки: «Начать поездку в RadarMap» и т.п.
struct RadarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTripIntent(),
            phrases: [
                "Начать поездку в \(.applicationName)",
                "Включи \(.applicationName)",
                "Start trip in \(.applicationName)",
            ],
            shortTitle: "Начать поездку",
            systemImageName: "car.fill"
        )
        AppShortcut(
            intent: EndTripIntent(),
            phrases: [
                "Завершить поездку в \(.applicationName)",
                "Выключи \(.applicationName)",
                "End trip in \(.applicationName)",
            ],
            shortTitle: "Завершить поездку",
            systemImageName: "flag.checkered"
        )
        AppShortcut(
            intent: ReportRadarIntent(),
            phrases: [
                "Радар здесь в \(.applicationName)",
                "Отметь радар в \(.applicationName)",
                "Radar here in \(.applicationName)",
            ],
            shortTitle: "Радар здесь",
            systemImageName: "dot.radiowaves.left.and.right"
        )
    }
}
