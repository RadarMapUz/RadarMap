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
        // Siri/Кнопка действия поднимают процесс В ФОНЕ — телефонная сцена не
        // создавалась, и без этого вызова поездка шла без лимитов (ни рейтинга,
        // ни штрафов) и БЕЗ автозавершения: CoreMotion не запущен, «Завершить»
        // некому, и Best-GPS висел часами после парковки. Тот же баг уже чинили
        // для CarPlay-сцены (CarPlaySceneDelegate) — все старты идемпотентны.
        env.startDrivingServices()
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

/// Общая работа всех голосовых отметок.
///
/// Раньше голосом можно было поставить только радар, и это делало Siri
/// бесполезной ровно там, где она нужнее всего: тренога и патруль — те самые
/// вещи, ради которых водитель тянется к телефону, а руки заняты рулём. Теперь
/// у каждого типа своя фраза: «отметь треногу», «здесь ДПС» — одно
/// высказывание, без уточняющих вопросов Siri посреди дороги.
@MainActor
private func reportBySiri(_ kind: ReportKind) async -> IntentDialog {
    let env = AppEnvironment.shared
    // Холодный старт из Siri: GPS ещё не тикал — просим одноразовый фикс и ждём.
    guard let coordinate = await env.location.awaitCoordinate() else {
        return IntentDialog("Не вижу геопозицию — попробуйте ещё раз.")
    }
    // Через ту же дверь, что и кнопка: интент шёл мимо и терял защиту от
    // дублей — «Привет Siri, радар здесь» на том же посту через квартал
    // ставило вторую точку, а дневной счётчик отметок его не видел вовсе.
    let outcome = await env.mobile.quickReport(
        kind: kind,
        coordinate: coordinate,
        speedKmh: env.location.speedKmh,
        isTripActive: env.location.isTripActive,
        course: env.location.currentCourse)
    switch outcome {
    case .sent(.created):
        return IntentDialog(stringLiteral:
            String(format: String(localized: "Отмечено: %@. Спасибо, что предупредили!"),
                   kind.title))
    case .sent(.confirmed):
        return IntentDialog(stringLiteral:
            String(format: String(localized: "Здесь уже отмечено — подтвердили: %@"), kind.title))
    case .sent(.amended):
        // Своя свежая отметка другого типа рядом превращает эту в уточнение:
        // сервер переписал тип той же точки, а не создал вторую.
        return IntentDialog("Тип отметки уточнён.")
    case .queued:
        return IntentDialog("Связи нет — отправлю, как только появится.")
    case .sent(.failed), .refused:
        // Причина уже разложена на человеческую фразу — Siri произносит её как
        // есть, а не «нет связи» поверх «слишком часто» или «выключено».
        return IntentDialog(stringLiteral: outcome.spoken)
    }
}

struct ReportRadarIntent: AppIntent {
    static let title: LocalizedStringResource = "Радар здесь"
    static let description = IntentDescription(
        "Отмечает передвижной радар в текущей точке — другие водители увидят его на карте.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await reportBySiri(.radar))
    }
}

struct ReportTripodIntent: AppIntent {
    static let title: LocalizedStringResource = "Тренога здесь"
    static let description = IntentDescription(
        "Отмечает треногу в текущей точке — другие водители увидят её на карте.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await reportBySiri(.tripod))
    }
}

struct ReportPostIntent: AppIntent {
    static let title: LocalizedStringResource = "Пост ДПС здесь"
    static let description = IntentDescription(
        "Отмечает пост ДПС в текущей точке — другие водители увидят его на карте.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await reportBySiri(.post))
    }
}

struct ReportAccidentIntent: AppIntent {
    static let title: LocalizedStringResource = "ДТП здесь"
    static let description = IntentDescription(
        "Отмечает ДТП в текущей точке — другие водители увидят его на карте.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await reportBySiri(.accident))
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
        AppShortcut(
            intent: ReportTripodIntent(),
            phrases: [
                "Тренога здесь в \(.applicationName)",
                "Отметь треногу в \(.applicationName)",
                "Tripod here in \(.applicationName)",
            ],
            shortTitle: "Тренога здесь",
            systemImageName: "camera.on.rectangle"
        )
        AppShortcut(
            intent: ReportPostIntent(),
            phrases: [
                "Пост здесь в \(.applicationName)",
                "Отметь ДПС в \(.applicationName)",
                "Police here in \(.applicationName)",
            ],
            shortTitle: "Пост ДПС здесь",
            systemImageName: "figure.wave"
        )
        AppShortcut(
            intent: ReportAccidentIntent(),
            phrases: [
                "ДТП здесь в \(.applicationName)",
                "Отметь аварию в \(.applicationName)",
                "Accident here in \(.applicationName)",
            ],
            shortTitle: "ДТП здесь",
            systemImageName: "exclamationmark.triangle"
        )
    }
}
