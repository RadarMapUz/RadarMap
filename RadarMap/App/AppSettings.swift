//
//  AppSettings.swift
//  RadarMap
//
//  Пользовательские настройки, сохраняются в UserDefaults.
//

import Foundation
import Observation
import CoreLocation
import os

// nonisolated: matches(_:) зовёт @concurrent-сборка слоя карты вне main.
nonisolated enum CameraFilter: String, CaseIterable, Identifiable {
    case all, cameras, radars
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all:     return String(localized: "Все")
        case .cameras: return String(localized: "Камеры")
        case .radars:  return String(localized: "Радары")
        }
    }
    func matches(_ camera: Camera) -> Bool {
        // «Интеллектуал + радар» фиксирует и нарушения, и скорость — попадает в оба фильтра.
        switch self {
        case .all:     return true
        case .cameras: return camera.kind == .stationaryCamera || camera.kind == .intelligentRadar
        case .radars:  return camera.kind == .stationaryRadar || camera.kind == .intelligentRadar
        }
    }
}

/// Сохранённое место для маршрута в один тап (Дом/Работа).
struct SavedPlace: Codable, Equatable {
    var title: String     // адрес из поиска
    var lat: Double
    var lon: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

/// Слот сохранённого места.
enum PlaceSlot: String, CaseIterable, Identifiable {
    case home, work
    var id: String { rawValue }
    var name: String {
        switch self {
        case .home: return String(localized: "Дом")
        case .work: return String(localized: "Работа")
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .work: return "briefcase.fill"
        }
    }
}

/// Режим оповещений. «Авто» сам различает контекст: в городе камер сотни —
/// голос только при превышении; на трассе камер мало и штрафы дорогие —
/// голосом о каждой. Вручную можно зафиксировать город/трассу.
enum AlertMode: String, CaseIterable, Identifiable {
    case auto, city, highway
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return String(localized: "Авто")
        case .city: return String(localized: "Город")
        case .highway: return String(localized: "Трасса")
        }
    }
    var symbol: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .city: return "building.2.fill"
        case .highway: return "road.lanes"
        }
    }
}

/// Фоновые баннеры о камерах: о чём предупреждать, когда приложение свёрнуто.
/// Звук/голос в поездке живут отдельно — это только про уведомления в фоне.
/// Как включается поездка. «Умный» — компромисс, ради которого этот переключатель
/// и появился: полный автостарт срабатывает и когда ты пассажир в такси (жжёт
/// заряд, портит статистику), а полностью ручной режим требуют не забыть нажать
/// кнопку — и о камерах узнаёшь уже по штрафу.
enum TripStartMode: String, CaseIterable, Identifiable {
    /// Всегда сама, как только CoreMotion увидел автомобиль.
    case auto
    /// Сама — только в знакомой машине (CarPlay или своя магнитола по Bluetooth).
    /// В чужой машине не стартует, а спрашивает «вы за рулём?».
    case smart
    /// Только кнопкой. CoreMotion не работает вовсе — ещё и экономия заряда.
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:   return String(localized: "Авто")
        case .smart:  return String(localized: "Умный")
        case .manual: return String(localized: "Ручной")
        }
    }

    var symbol: String {
        switch self {
        case .auto:   return "bolt.fill"
        case .smart:  return "wand.and.stars"
        case .manual: return "hand.tap.fill"
        }
    }

    /// Слежение CoreMotion нужно только если поездка может стартовать сама.
    var usesMotion: Bool { self != .manual }
}

enum BackgroundAlertMode: String, CaseIterable, Identifiable {
    case all, radarsOnly, off
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:        return String(localized: "Все камеры")
        case .radarsOnly: return String(localized: "Только радары")
        case .off:        return String(localized: "Выключены")
        }
    }

    /// Пропускает ли режим уведомление об этой камере.
    func allows(_ camera: Camera) -> Bool {
        switch self {
        case .all: return true
        case .radarsOnly:
            // Радары меряют скорость — самое важное; «обычные» камеры не будят.
            return camera.kind == .stationaryRadar || camera.kind == .intelligentRadar
                || camera.kind == .mobileRadar || camera.kind == .tripod
        case .off: return false
        }
    }
}

/// Тема карты. Интерфейс всегда тёмный («радар-детектор»), но тёмная карта
/// днём на солнце бликует — авто-режим переключает подложку по времени суток.
enum MapAppearance: String, CaseIterable, Identifiable {
    case dark, auto, light
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark:  return String(localized: "Тёмная")
        case .auto:  return String(localized: "Авто (день/ночь)")
        case .light: return String(localized: "Светлая")
        }
    }
}

/// Язык интерфейса. `.system` — как в настройках телефона; ru/uz форсируют язык
/// через ключ `AppleLanguages` (применяется при следующем запуске — так весь
/// текст, включая `String(localized:)`, переключается разом, без «каши» языков).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ru, uz
    var id: String { rawValue }

    /// Название в списке. Родные названия — эндонимы (всегда на своём языке),
    /// «Системный» переводится под текущий язык интерфейса.
    var title: String {
        switch self {
        case .system: return String(localized: "Системный")
        case .ru:     return "Русский"
        case .uz:     return "O'zbekcha"
        }
    }

    /// Значение для UserDefaults «AppleLanguages» (nil = следовать системе).
    var appleLanguages: [String]? {
        switch self {
        case .system: return nil
        case .ru:     return ["ru"]
        case .uz:     return ["uz"]
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    var soundEnabled: Bool { didSet { store.set(soundEnabled, forKey: Keys.sound) } }
    var voiceEnabled: Bool { didSet { store.set(voiceEnabled, forKey: Keys.voice) } }
    var alertRadius: CLLocationDistance { didSet { store.set(alertRadius, forKey: Keys.radius) } }
    var filter: CameraFilter { didSet { store.set(filter.rawValue, forKey: Keys.filter) } }
    /// Режим старта поездки (заменил тумблер «Автостарт», см. миграцию в init).
    var tripStartMode: TripStartMode {
        didSet { store.set(tripStartMode.rawValue, forKey: Keys.tripStartMode) }
    }
    var alertVolume: Double { didSet { store.set(alertVolume, forKey: Keys.volume) } }
    var homePlace: SavedPlace? { didSet { save(homePlace, forKey: Keys.home) } }
    var workPlace: SavedPlace? { didSet { save(workPlace, forKey: Keys.work) } }

    // Маршрут и скорость — каждую функцию можно выключить.
    var routeAlternatives: Bool { didSet { store.set(routeAlternatives, forKey: Keys.alternatives) } }
    var turnByTurnVoice: Bool { didSet { store.set(turnByTurnVoice, forKey: Keys.turnByTurn) } }
    var speedLimitsEnabled: Bool { didSet { store.set(speedLimitsEnabled, forKey: Keys.speedLimits) } }
    var overspeedTolerance: Double { didSet { store.set(overspeedTolerance, forKey: Keys.overspeed) } }
    var adaptiveGPS: Bool { didSet { store.set(adaptiveGPS, forKey: Keys.adaptive) } }
    var showNextCamera: Bool { didSet { store.set(showNextCamera, forKey: Keys.nextCamera) } }
    var weeklyDigest: Bool { didSet { store.set(weeklyDigest, forKey: Keys.digest) } }
    var recentPlaces: [SavedPlace] { didSet { saveRecents() } }

    /// Фоновые баннеры о камерах (Центр уведомлений). Звука в поездке не касается.
    var backgroundAlerts: BackgroundAlertMode {
        didSet { store.set(backgroundAlerts.rawValue, forKey: Keys.backgroundAlerts) }
    }

    /// Тактильные сигналы при приближении к камере.
    var hapticsEnabled: Bool { didSet { store.set(hapticsEnabled, forKey: Keys.haptics) } }
    /// Не гасить экран в активной поездке (телефон в держателе — как у навигаторов).
    var keepScreenOn: Bool { didSet { store.set(keepScreenOn, forKey: Keys.keepScreenOn) } }
    /// Имена знакомых автомобильных магнитол (BT): подключены к своей машине —
    /// автостарт не переспрашивает «вы за рулём?».
    var knownCarAudio: [String] { didSet { store.set(knownCarAudio, forKey: Keys.knownCarAudio) } }
    /// Режим оповещений: «Авто» сам различает город/трассу, вручную можно зафиксировать.
    var alertMode: AlertMode {
        didSet { store.set(alertMode.rawValue, forKey: Keys.alertMode) }
    }
    /// Полная тишина, пока едем в лимите: о камере предупредит только HUD и тук.
    /// По умолчанию выключено — на трассе спокойный анонс полезнее тишины.
    var voiceOnlyWhenOverspeeding: Bool {
        didSet { store.set(voiceOnlyWhenOverspeeding, forKey: Keys.voiceOnlyOverspeed) }
    }

    /// Подложка карты: тёмная / светлая / авто по времени суток.
    var mapAppearance: MapAppearance {
        didSet { store.set(mapAppearance.rawValue, forKey: Keys.mapAppearance) }
    }

    /// Выбранный язык интерфейса (применяется при следующем запуске — см. AppLanguage).
    var appLanguage: AppLanguage {
        didSet {
            store.set(appLanguage.rawValue, forKey: Keys.language)
            applyLanguage()
        }
    }

    @ObservationIgnored private let store = UserDefaults.standard

    private enum Keys {
        static let sound = "soundEnabled"
        static let voice = "voiceEnabled"
        static let radius = "alertRadius"
        static let filter = "cameraFilter"
        static let autoStart = "autoStartTrip"        // legacy, только для миграции
        static let tripStartMode = "tripStartMode"
        static let volume = "alertVolume"
        static let home = "homePlace"
        static let work = "workPlace"
        static let alternatives = "routeAlternatives"
        static let turnByTurn = "turnByTurnVoice"
        static let speedLimits = "speedLimitsEnabled"
        static let overspeed = "overspeedTolerance"
        static let adaptive = "adaptiveGPS"
        static let nextCamera = "showNextCamera"
        static let digest = "weeklyDigest"
        static let recents = "recentPlaces"
        static let language = "appLanguage"
        static let backgroundAlerts = "backgroundAlerts"
        static let haptics = "hapticsEnabled"
        static let mapAppearance = "mapAppearance"
        static let keepScreenOn = "keepScreenOn"
        static let alertMode = "alertMode"
        static let knownCarAudio = "knownCarAudio"
        static let voiceOnlyOverspeed = "voiceOnlyWhenOverspeeding"
    }

    /// Пишем/снимаем override языка приложения. iOS читает «AppleLanguages» из
    /// нашего же UserDefaults при старте и выбирает нужную локализацию бандла.
    private func applyLanguage() {
        if let langs = appLanguage.appleLanguages {
            store.set(langs, forKey: "AppleLanguages")
        } else {
            store.removeObject(forKey: "AppleLanguages")
        }
    }

    init() {
        store.register(defaults: [
            Keys.sound: true,
            Keys.voice: true,
            Keys.radius: AppConfig.alertRadius,
            Keys.autoStart: true,
            Keys.volume: 1.0,
            Keys.alternatives: true,
            Keys.turnByTurn: true,
            Keys.speedLimits: true,
            Keys.overspeed: 5.0,
            Keys.adaptive: true,
            Keys.nextCamera: true,
            Keys.digest: true,
            Keys.haptics: true,
            Keys.keepScreenOn: true,
        ])
        soundEnabled = store.bool(forKey: Keys.sound)
        voiceEnabled = store.bool(forKey: Keys.voice)
        alertRadius = store.double(forKey: Keys.radius)
        filter = CameraFilter(rawValue: store.string(forKey: Keys.filter) ?? "") ?? .all
        // Миграция с тумблера «Автостарт»: включён → «Умный» (новый разумный
        // дефолт — сама стартует только в своей машине), выключен → «Ручной».
        if let raw = store.string(forKey: Keys.tripStartMode),
           let mode = TripStartMode(rawValue: raw) {
            tripStartMode = mode
        } else {
            tripStartMode = store.bool(forKey: Keys.autoStart) ? .smart : .manual
        }
        alertVolume = store.double(forKey: Keys.volume)
        homePlace = Self.load(store, Keys.home)
        workPlace = Self.load(store, Keys.work)
        routeAlternatives = store.bool(forKey: Keys.alternatives)
        turnByTurnVoice = store.bool(forKey: Keys.turnByTurn)
        speedLimitsEnabled = store.bool(forKey: Keys.speedLimits)
        overspeedTolerance = store.double(forKey: Keys.overspeed)
        adaptiveGPS = store.bool(forKey: Keys.adaptive)
        showNextCamera = store.bool(forKey: Keys.nextCamera)
        keepScreenOn = store.bool(forKey: Keys.keepScreenOn)
        alertMode = AlertMode(rawValue: store.string(forKey: Keys.alertMode) ?? "") ?? .auto
        voiceOnlyWhenOverspeeding = store.bool(forKey: Keys.voiceOnlyOverspeed)
        knownCarAudio = store.stringArray(forKey: Keys.knownCarAudio) ?? []
        weeklyDigest = store.bool(forKey: Keys.digest)
        appLanguage = AppLanguage(rawValue: store.string(forKey: Keys.language) ?? "") ?? .system
        backgroundAlerts = BackgroundAlertMode(rawValue: store.string(forKey: Keys.backgroundAlerts) ?? "") ?? .all
        hapticsEnabled = store.bool(forKey: Keys.haptics)
        mapAppearance = MapAppearance(rawValue: store.string(forKey: Keys.mapAppearance) ?? "") ?? .dark
        do {
            let data = store.data(forKey: Keys.recents)
            recentPlaces = try data.map { try JSONDecoder().decode([SavedPlace].self, from: $0) } ?? []
        } catch {
            Log.app.error("recentPlaces не декодировались: \(error.localizedDescription, privacy: .public)")
            recentPlaces = []
        }
    }

    // MARK: - Недавние места

    /// Запоминаем цель маршрута: дубликаты (то же название или точка ближе 150 м) поднимаются наверх.
    func addRecent(title: String, lat: Double, lon: Double) {
        let target = CLLocation(latitude: lat, longitude: lon)
        var list = recentPlaces.filter {
            $0.title != title
                && CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: target) > 150
        }
        list.insert(SavedPlace(title: title, lat: lat, lon: lon), at: 0)
        recentPlaces = Array(list.prefix(8))
    }

    private func saveRecents() {
        do {
            store.set(try JSONEncoder().encode(recentPlaces), forKey: Keys.recents)
        } catch {
            Log.app.error("recentPlaces не сохранились: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Дом / Работа

    func place(for slot: PlaceSlot) -> SavedPlace? {
        slot == .home ? homePlace : workPlace
    }

    func setPlace(_ place: SavedPlace?, for slot: PlaceSlot) {
        switch slot {
        case .home: homePlace = place
        case .work: workPlace = place
        }
    }

    private func save(_ place: SavedPlace?, forKey key: String) {
        if let place, let data = try? JSONEncoder().encode(place) {
            // Кодирование двух строк и координат не падает; nil ниже — осознанное удаление.
            store.set(data, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    private static func load(_ store: UserDefaults, _ key: String) -> SavedPlace? {
        guard let data = store.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(SavedPlace.self, from: data)
        } catch {
            Log.app.error("SavedPlace(\(key, privacy: .public)) не декодировался: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
