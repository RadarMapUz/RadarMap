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

enum CameraFilter: String, CaseIterable, Identifiable {
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
    var autoStartTrip: Bool { didSet { store.set(autoStartTrip, forKey: Keys.autoStart) } }
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
        static let autoStart = "autoStartTrip"
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
        ])
        soundEnabled = store.bool(forKey: Keys.sound)
        voiceEnabled = store.bool(forKey: Keys.voice)
        alertRadius = store.double(forKey: Keys.radius)
        filter = CameraFilter(rawValue: store.string(forKey: Keys.filter) ?? "") ?? .all
        autoStartTrip = store.bool(forKey: Keys.autoStart)
        alertVolume = store.double(forKey: Keys.volume)
        homePlace = Self.load(store, Keys.home)
        workPlace = Self.load(store, Keys.work)
        routeAlternatives = store.bool(forKey: Keys.alternatives)
        turnByTurnVoice = store.bool(forKey: Keys.turnByTurn)
        speedLimitsEnabled = store.bool(forKey: Keys.speedLimits)
        overspeedTolerance = store.double(forKey: Keys.overspeed)
        adaptiveGPS = store.bool(forKey: Keys.adaptive)
        showNextCamera = store.bool(forKey: Keys.nextCamera)
        weeklyDigest = store.bool(forKey: Keys.digest)
        appLanguage = AppLanguage(rawValue: store.string(forKey: Keys.language) ?? "") ?? .system
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
