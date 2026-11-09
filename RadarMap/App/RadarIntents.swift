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
import os

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

/// «Поехали домой» / «На работу» голосом: руки на руле, в том числе в машине
/// с CarPlay, где набирать адрес за рулём нельзя вовсе.
///
/// Адрес — заданный руками, а без него выученный по поездкам: то же правило,
/// что у строки «Домой» на главном экране (ручной выбор старше догадки).
@MainActor
private func routeBySiri(_ slot: PlaceSlot) async -> IntentDialog {
    let env = AppEnvironment.shared
    // Процесс мог подняться в фоне (Siri) — без этого ни лимитов, ни
    // выученных мест (refreshLearnedPlaces внутри).
    env.startDrivingServices()
    guard env.location.authorizationStatus == .authorizedAlways else {
        return IntentDialog("Нет доступа к геолокации. Откройте RadarMap и разрешите «Всегда».")
    }
    // Холодный старт из Siri: история поездок едет с диска отдельной задачей,
    // а выученные места считаются по ней (onHistoryLoaded). Без ожидания
    // водитель без ручного адреса всегда слышал «не знаю, где дом».
    for _ in 0..<AppConfig.siriHistoryWaitSteps where !env.trip.isLoaded {
        // Ошибка sleep — только отмена интента: тогда просто перестаём ждать.
        try? await Task.sleep(for: .milliseconds(100))
    }
    let manual = env.settings.place(for: slot)
    let learned = env.learnedPlaces.first { $0.kind.rawValue == slot.rawValue }
    guard let destination = manual?.coordinate ?? learned?.coordinate else {
        return slot == .home
            ? IntentDialog("Не знаю, где дом. Задайте его в RadarMap — или поездите, я выучу сам.")
            : IntentDialog("Не знаю, где работа. Задайте её в RadarMap — или поездите, я выучу сам.")
    }
    // Только «Дом»/«Работа»: подпись маршрута уходит на плашку экрана
    // блокировки, адрес из поиска там увидел бы любой рядом с телефоном.
    if let failure = await buildSiriRoute(env, to: destination, title: slot.name) { return failure }
    let time = Formatting.duration(env.route.remainingTime)
    // Прибытие — та же минута, что на панели и в машине (RouteService.arrival).
    let clock = env.route.arrivalText
    let cameras = env.route.ourCameraCount
    return slot == .home
        ? IntentDialog("Едем домой: \(time), прибытие в \(clock), камер на пути — \(cameras).")
        : IntentDialog("Едем на работу: \(time), прибытие в \(clock), камер на пути — \(cameras).")
}

/// Маршрут по команде Siri; nil — построен, иначе что сказать водителю.
@MainActor
private func buildSiriRoute(_ env: AppEnvironment, to destination: CLLocationCoordinate2D,
                            title: String) async -> IntentDialog? {
    // Поездка — ДО ожидания точки: в тихом фоне GPS даёт один фикс по
    // запросу, и забракованный фильтром он оставлял нас без позиции. В
    // поездке GPS непрерывный — точная точка приходит за секунды.
    if !env.location.isTripActive { env.location.startTrip() }
    guard let from = await env.location.awaitPreciseCoordinate() else {
        return IntentDialog("Не вижу геопозицию — попробуйте ещё раз.")
    }
    await env.route.build(from: from, heading: env.location.routeHeading,
                          to: destination, name: title,
                          cameras: env.cameras.cameras, alternatives: false)
    // Не построился — RouteService оставляет ПРЕЖНИЙ маршрут: «есть ли
    // маршрут» отвечало бы цифрами старой цели. Сверяем, что он — наш.
    guard env.route.errorMessage == nil, let built = env.route.destinationCoordinate,
          GeoMath.fastDistance(built.latitude, built.longitude,
                               destination.latitude, destination.longitude) < 50 else {
        return IntentDialog("Маршрут не построился — попробуйте позже.")
    }
    env.settings.addRecent(title: title, lat: destination.latitude, lon: destination.longitude)
    return nil
}

/// Адрес голосом — путь на ходу, когда клавиатуры в машине нет: тот же поиск,
/// лучшее совпадение, и ответ называет место, чтобы водитель слышал, куда едет.
@MainActor
private func routeToAddressBySiri(_ text: String) async -> IntentDialog {
    let env = AppEnvironment.shared
    env.startDrivingServices()
    guard env.location.authorizationStatus == .authorizedAlways else {
        return IntentDialog("Нет доступа к геолокации. Откройте RadarMap и разрешите «Всегда».")
    }
    guard let place = await CarPlaySearch(onPick: { _ in }).firstPlace(for: text) else {
        return IntentDialog(stringLiteral: String(format: String(localized: "Не нашёл «%@». Попробуйте сказать иначе."), text))
    }
    if let failure = await buildSiriRoute(env, to: place.coordinate, title: place.title) { return failure }
    return IntentDialog(stringLiteral: String(format: String(localized: "Едем: %1$@. %2$@, прибытие в %3$@, камер на пути — %4$lld."),
                                              place.title, Formatting.duration(env.route.remainingTime),
                                              env.route.arrivalText, env.route.ourCameraCount))
}

struct RouteToAddressIntent: AppIntent {
    static let title: LocalizedStringResource = "Маршрут по адресу"
    static let description = IntentDescription("Ищет адрес или место и строит маршрут — голосом, руки на руле.")

    @Parameter(title: "Куда", requestValueDialog: IntentDialog("Куда едем?"))
    var destination: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await routeToAddressBySiri(destination))
    }
}

struct RouteHomeIntent: AppIntent {
    static let title: LocalizedStringResource = "Маршрут домой"
    static let description = IntentDescription("Строит маршрут домой и включает оповещения о камерах.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await routeBySiri(.home))
    }
}

struct RouteWorkIntent: AppIntent {
    static let title: LocalizedStringResource = "Маршрут на работу"
    static let description = IntentDescription("Строит маршрут на работу и включает оповещения о камерах.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await routeBySiri(.work))
    }
}

/// Общая работа всех голосовых отметок.
///
/// У каждого типа своя фраза: «отметь треногу», «здесь ДПС» — одно
/// высказывание, без уточняющих вопросов Siri посреди дороги. Дверь — та же,
/// что у кнопки (ReportFlow): одна отметка в полёте на все входы, точка — по
/// своему треку с поправкой на фразу Siri, а тип, названный голосом, закрывает
/// открытый на экране выбор. Ответ говорит сама Siri — свой голос молчит.
@MainActor
private func reportBySiri(_ kind: ReportKind) async -> IntentDialog {
    let env = AppEnvironment.shared
    let answer = await env.reports.report(kind, from: .siri, speak: false)
    switch answer {
    case .busy:
        return IntentDialog("Отметка уже отправляется.")
    case .choosing, .cancelled:
        return IntentDialog(stringLiteral: ReportWords.notMarked)
    case .done(let outcome):
        switch outcome {
        case .sent(.created):
            // «Тренога отмечена. Отменить — «Отмени отметку»» — отмена голосом
            // есть (CancelReportIntent), и её надо назвать.
            return IntentDialog(stringLiteral:
                String(format: String(localized: "%@. Отменить — «Отмени отметку в RadarMap»"),
                       ReportWords.marked(kind)))
        case .sent(.confirmed):
            return IntentDialog(stringLiteral:
                String(format: String(localized: "Здесь уже отмечено — подтвердили: %@"), ReportWords.title(kind)))
        case .sent(.amended):
            return IntentDialog("Тип отметки уточнён.")
        case .queued(.serverBroken):
            return IntentDialog("Сервер не отвечает — отправлю, как только ответит.")
        case .queued:
            return IntentDialog("Связи нет — отправлю, как только появится.")
        case .sent(.failed), .refused:
            // Причина уже разложена на человеческую фразу — Siri произносит её как
            // есть, а не «нет связи» поверх «слишком часто» или «выключено».
            return IntentDialog(stringLiteral: outcome.spoken)
        }
    }
}

/// «Отмени отметку» — то же «Отменить», что на экране, часах и плашке, пока
/// открыто окно отмены.
struct CancelReportIntent: AppIntent {
    static let title: LocalizedStringResource = "Отменить отметку"
    static let description = IntentDescription("Убирает только что поставленную отметку.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = AppEnvironment.shared
        // Окно сервера (10 мин), а не 8 с экрана: подсказка Siri, фраза и
        // распознавание сами занимают 8–9 с (ревью 40b, Н5).
        guard let text = await env.reports.undoLatest(speak: false) else {
            return .result(dialog: IntentDialog("Отменять нечего."))
        }
        return .result(dialog: IntentDialog(stringLiteral: text))
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

/// Кнопки плашки поездки (9.1б). Плашка живёт только в поездке и только
/// при свёрнутом приложении, так что ответ — голосом и самой плашкой: ✓ или
/// ✕ на месте «Радар!», значок динамика у «Звука».
extension AppEnvironment {
    func performActivityAction(_ action: ActivityAction) async {
        switch action {
        case .toggleSound:
            settings.setMuted(!settings.isMuted)
            Log.alerts.info("Плашка: звук \(self.settings.isMuted ? "выключен" : "включён", privacy: .public)")
            location.refreshLiveActivity()
        case .report:
            guard let ok = await remoteRadarReport(from: .liveActivity) else { return }
            // Повтор на том же месте — точка уже стоит: ✓, а не «✕ Не
            // отправлено» поверх голоса «Уже отметили здесь» (ревью 20.10).
            // Ушла новая — 8 с на месте кнопки «Отменить» (02.11).
            let undo = ok && reports.canUndo()
            let flash = liveActivity.flashReport(ok, undo: undo)
            location.refreshLiveActivity()
            // Снять отметку — отдельной задачей: намерению плашки система даёт
            // секунды, и ждать внутри него незачем.
            Task { [weak self] in
                await Task.pause(seconds: undo ? AppConfig.reportUndoSeconds
                                                : AppConfig.liveActivityReportFlashSeconds)
                self?.liveActivity.clearReportFlash(flash)
                self?.location.refreshLiveActivity()
            }
        case .cancelReport:
            await reports.undo()
            liveActivity.clearReport()
            location.refreshLiveActivity()
        }
    }
}

extension AppEnvironment {
    /// «Отметить» без взгляда на телефон — с плашки и с часов. Та же дверь,
    /// что у кнопки на карте (ReportFlow): тренога по умолчанию, точка по
    /// своему треку от момента касания, одна отметка в полёте на все входы.
    /// Итог произносится: на экран за рулём не смотрят.
    ///
    /// true/false — точка есть (ушла, в очереди или уже стояла) или нет;
    /// nil — прошлая отметка ещё в пути: не «✕», а «в пути».
    func remoteRadarReport(from source: ReportDraft.Source) async -> Bool? {
        await reports.begin(from: source).pointExists
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
            intent: RouteHomeIntent(),
            phrases: [
                "Поехали домой в \(.applicationName)",
                "Домой в \(.applicationName)",
                "Take me home in \(.applicationName)",
            ],
            shortTitle: "Домой",
            systemImageName: "house.fill"
        )
        AppShortcut(
            intent: RouteWorkIntent(),
            phrases: [
                "Поехали на работу в \(.applicationName)",
                "На работу в \(.applicationName)",
                "Take me to work in \(.applicationName)",
            ],
            shortTitle: "На работу",
            systemImageName: "briefcase.fill"
        )
        AppShortcut(
            intent: RouteToAddressIntent(),
            phrases: [
                "Найди адрес в \(.applicationName)",
                "Маршрут по адресу в \(.applicationName)",
                "Find address in \(.applicationName)",
            ],
            shortTitle: "Маршрут по адресу",
            systemImageName: "magnifyingglass"
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
            intent: CancelReportIntent(),
            phrases: [
                "Отмени отметку в \(.applicationName)",
                "Cancel report in \(.applicationName)",
            ],
            shortTitle: "Отменить отметку",
            systemImageName: "arrow.uturn.backward"
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
