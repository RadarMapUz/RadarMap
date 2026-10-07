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

/// Когда приложение говорит о камерах голосом. Раньше на этот вопрос отвечали
/// три независимых переключателя (тумблер голоса, «только при превышении» и
/// режим город/трасса), и в городе всё равно звучала фраза на каждую камеру —
/// поверх музыки. Теперь один выбор из трёх понятных вариантов.
enum VoiceMode: String, CaseIterable, Identifiable {
    /// Ни слова: камеру показывает панель, предупреждает вибрация.
    case off
    /// По умолчанию. В городе молчит, пока едешь в лимите: камеры там идут
    /// одна за другой, и фраза на каждую превращается в белый шум. На трассе
    /// говорит полной фразой — следующая камера через километры, и увидеть её
    /// заранее нельзя. Плюс голос при превышении и о внезапных точках
    /// (передвижной радар, тренога, ДТП), которых водитель знать не может.
    case smart
    /// О каждой камере: в городе коротко, на трассе полной фразой.
    case always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:    return String(localized: "Молча")
        case .smart:  return String(localized: "Умно")
        case .always: return String(localized: "Обо всех")
        }
    }

    var detail: String {
        switch self {
        case .off:
            return String(localized: "Камеру показывает панель, предупреждает вибрация. Музыка не прерывается.")
        case .smart:
            return String(localized: "Молчит, пока едете в лимите. Голос — только когда превышаете и о внезапных точках: передвижной радар, тренога, ДТП.")
        case .always:
            return String(localized: "Говорит о каждой камере: в городе коротко, на трассе полной фразой.")
        }
    }

    var symbol: String {
        switch self {
        case .off:    return "speaker.slash.fill"
        case .smart:  return "wand.and.stars"
        case .always: return "speaker.wave.2.fill"
        }
    }
}

/// Голос о самом превышении («превышение скорости») — отдельно от голоса о
/// камерах. Появился из реальной поездки: фраза звучала честно по лимиту, но
/// без камеры впереди воспринималась как ворчание. Штраф-то возможен только
/// у камеры — и водитель вправе слышать голос только там.
enum OverspeedVoice: String, CaseIterable, Identifiable {
    /// Как раньше: любое устойчивое превышение — фраза (не чаще раза в 30 с).
    case always
    /// Только когда впереди ПО НАШЕЙ ДОРОГЕ камера в радиусе оповещения:
    /// штраф реален — фраза заслужена. Вне камер молчим, превышение видно
    /// цветом скорости и кромкой приборки.
    case nearCameras
    /// Никогда: только цвет и кромка.
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always:      return String(localized: "Всегда")
        case .nearCameras: return String(localized: "У камер")
        case .off:         return String(localized: "Никогда")
        }
    }

    var symbol: String {
        switch self {
        case .always:      return "speaker.wave.2.fill"
        case .nearCameras: return "camera.metering.spot"
        case .off:         return "speaker.slash.fill"
        }
    }

    /// Разрешён ли голос о превышении сейчас. `cameraAhead` — камера на нашей
    /// дороге в радиусе оповещения (тот же ближайший, что у HUD и алертов).
    func allows(cameraAhead: Bool) -> Bool {
        switch self {
        case .always:      return true
        case .nearCameras: return cameraAhead
        case .off:         return false
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

    /// День ли сейчас. Одна ручка на подложку карты И на схему приборки.
    ///
    /// Вторая настройка «а теперь для схемы» была бы вопросом, ответ на
    /// который человек уже дал: он выбирает не тему карты, а как ему видно.
    /// Ручной выбор старше автоматики — та же иерархия, что у тишины и у вида
    /// на CarPlay.
    func isDaylight(at coordinate: CLLocationCoordinate2D?,
                    now: Date = Date()) -> Bool {
        switch self {
        case .dark:  return false
        case .light: return true
        case .auto:  return Sun.isDaytime(at: coordinate, now: now)
        }
    }
}

/// Чем рисуется карта. Одно значение вместо двух тумблеров.
///
/// Тумблеров было два («Своя схема в движении» и «Карта на движке»), и они
/// умели противоречить друг другу. Хуже того: оба лежали в девятом разделе
/// настроек, а показывались только после старта поездки — то есть человек
/// включал карту и видел прежнюю. Здесь выбор один, живёт он на самой карте и
/// применяется немедленно.
nonisolated enum MapBase: String, CaseIterable, Identifiable, Sendable {
    /// Карта Apple: где ищут адрес, смотрят город и ставят камеру.
    case apple
    /// Наши данные, нарисованные настоящим картографическим движком.
    case engine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple:  return String(localized: "Apple")
        case .engine: return String(localized: "Карта RadarMap")
        }
    }

    /// Значок — он же показывает выбранное, когда список свёрнут.
    var symbol: String {
        switch self {
        case .apple:  return "map"
        case .engine: return "square.3.layers.3d"
        }
    }

    /// Что показать НА САМОМ ДЕЛЕ.
    ///
    /// Выбор человека сильнее режима — это и есть главное правило нового
    /// экрана. Прежнее `allowsSketchMap` перебивало выбор: на стоянке своей
    /// карты не бывало вовсе, и включивший её видел карту Apple.
    ///
    /// Apple возвращается ровно в двух случаях, и оба не вкусовые: операция,
    /// которой без неё нет (постановка камеры, точка по долгому тапу), и
    /// отсутствие того, что выбрано (движок без пакета). Второе — отказ, а не
    /// подмена: пустой экран вместо карты оставил бы водителя без карты вовсе.
    ///
    /// Подложек две. Самодельная схема была третьей и убрана: держать ДВА
    /// своих рендерера одних и тех же данных — это два разных ответа на один
    /// вопрос и вдвое больше мест, где карта может соврать.
    static func resolved(chosen: MapBase, isAddingCamera: Bool,
                         hasPressedPoint: Bool,
                         engineAvailable: Bool) -> MapBase {
        if isAddingCamera || hasPressedPoint { return .apple }
        switch chosen {
        case .apple:  return .apple
        case .engine: return engineAvailable ? .engine : .apple
        }
    }
}

/// Профиль оповещений — одна строка вместо четырёх перечислений.
///
/// Поведение задавали `VoiceMode`, `AlertMode`, `BackgroundAlertMode` и
/// `TripStartMode`, причём в трёх из них было своё «Авто»/«Умно» с разным
/// смыслом. Держать эту матрицу в голове пользователь не обязан, а результат
/// комбинаций предсказать нельзя было и нам.
///
/// Профиль — фасад: он ЗАПИСЫВАЕТ нижележащие настройки, а не подменяет их.
/// Поэтому весь остальной код продолжает читать `voiceMode` и `alertMode` как
/// раньше, а «Свой» просто перестаёт их трогать и открывает подробности.
enum AlertProfile: String, CaseIterable, Identifiable {
    case auto, city, highway, quiet, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:    return String(localized: "Авто")
        case .city:    return String(localized: "Город")
        case .highway: return String(localized: "Трасса")
        case .quiet:   return String(localized: "Тихий")
        case .custom:  return String(localized: "Свой")
        }
    }

    var detail: String {
        switch self {
        case .auto:
            return String(localized: "Сам понимает город или трассу. В городе — коротко, на трассе — полной фразой, о своих камерах — только вибрация, при превышении — громко.")
        case .city:
            return String(localized: "Всегда короткие фразы: камеры идут одна за другой.")
        case .highway:
            return String(localized: "Всегда полные фразы и заранее: камер мало, ехать до следующей далеко.")
        case .quiet:
            return String(localized: "Ни слова. Камеру показывает панель и отмечает вибрация.")
        case .custom:
            return String(localized: "Настраиваете сами.")
        }
    }

    /// Значения, которые профиль проставляет. `nil` — не трогать (свой профиль).
    var applied: (voice: VoiceMode, mode: AlertMode)? {
        switch self {
        case .auto:    return (.smart, .auto)
        case .city:    return (.smart, .city)
        case .highway: return (.smart, .highway)
        case .quiet:   return (.off, .auto)
        case .custom:  return nil
        }
    }

    /// Какой профиль соответствует уже сохранённым настройкам — для переезда
    /// со старой версии. Всё, что не ложится в готовый профиль, становится
    /// «Своим»: привычка пользователя важнее стройности списка.
    static func matching(voice: VoiceMode, mode: AlertMode) -> AlertProfile {
        if voice == .off { return .quiet }
        guard voice == .smart else { return .custom }
        switch mode {
        case .auto:    return .auto
        case .city:    return .city
        case .highway: return .highway
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

    /// Язык подписей карты и названий областей: выбранный, а у «Системного» —
    /// по первому языку телефона (всё, что не узбекский, — русский).
    var mapCode: String {
        switch self {
        case .ru: return "ru"
        case .uz: return "uz"
        case .system: return Locale.preferredLanguages.first?.hasPrefix("uz") == true ? "uz" : "ru"
        }
    }
}

@MainActor
@Observable
final class AppSettings {

    /// Снос — БЕЗ прыжка на актор, и это не стиль, а обход живого бага рантайма.
    ///
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor синтезирует isolated deinit
    /// каждому @MainActor-классу, даже когда своего deinit нет. Такой deinit
    /// уходит в swift_task_deinitOnExecutor, тот в синхронном кадре главного
    /// потока (текущей Task нет) заводит TaskLocal::StopLookupScope, а
    /// MarkerItem::create в рантайме iOS 26 берёт память у task-аллокатора
    /// БЕЗУСЛОВНО — при task == nullptr это статический слэб внутри
    /// libswift_Concurrency. Item::destroy потом зовёт free() по этому
    /// указателю: «pointer being freed was not allocated» → SIGABRT.
    ///
    /// Условия сходятся ровно там, где SwiftUI сносит вью с @State-моделью
    /// внутри GraphHost.runTransaction: там жива task-local привязка. В ветке
    /// main рантайма баг уже исправлен; до выхода такой iOS помогает одно —
    /// не синтезировать isolated deinit вовсе.
    nonisolated deinit {}
    var soundEnabled: Bool { didSet { store.set(soundEnabled, forKey: Keys.sound) } }
    /// Голос о камерах — единственная настройка на этот счёт.
    var voiceMode: VoiceMode { didSet { store.set(voiceMode.rawValue, forKey: Keys.voiceMode) } }
    /// Голос о превышении: всегда / только у камер / никогда (см. OverspeedVoice).
    var overspeedVoice: OverspeedVoice {
        didSet { store.set(overspeedVoice.rawValue, forKey: Keys.overspeedVoice) }
    }
    /// Фасад для «тишины» целиком: кнопка глушилки в CarPlay и голос маршрута.
    var voiceEnabled: Bool {
        get { voiceMode != .off }
        set { voiceMode = newValue ? .smart : .off }
    }

    /// Беззвучно (кнопка с динамиком на карте): ни голоса, ни сигналов.
    /// Вибрация и экран тревоги остаются — камера не исчезает, она молчит.
    var isMuted: Bool { !soundEnabled && voiceMode == .off }

    /// Выключить/вернуть звук одной кнопкой. Возвращается ПРЕЖНИЙ режим
    /// голоса, а не «по умолчанию»: выбранное человеком не теряется.
    func setMuted(_ muted: Bool) {
        if muted {
            if voiceMode != .off { store.set(voiceMode.rawValue, forKey: Keys.voiceBeforeMute) }
            soundEnabled = false
            voiceMode = .off
        } else {
            soundEnabled = true
            voiceMode = store.string(forKey: Keys.voiceBeforeMute).flatMap(VoiceMode.init(rawValue:)) ?? .smart
        }
    }
    var alertRadius: CLLocationDistance { didSet { store.set(alertRadius, forKey: Keys.radius) } }
    var filter: CameraFilter { didSet { store.set(filter.rawValue, forKey: Keys.filter) } }
    /// Режим старта поездки (заменил тумблер «Автостарт», см. миграцию в init).
    var tripStartMode: TripStartMode {
        didSet { store.set(tripStartMode.rawValue, forKey: Keys.tripStartMode) }
    }
    var alertVolume: Double { didSet { store.set(alertVolume, forKey: Keys.volume) } }
    var homePlace: SavedPlace? { didSet { save(homePlace, forKey: Keys.home) } }
    var workPlace: SavedPlace? { didSet { save(workPlace, forKey: Keys.work) } }

    /// Координаты сохранённых мест одним списком — для склейки поездок
    /// (TripMerge) и её карточки-предложения в Итогах.
    var savedPlaceCoordinates: [CLLocationCoordinate2D] {
        [homePlace?.coordinate, workPlace?.coordinate].compactMap(\.self)
    }

    // Маршрут и скорость — каждую функцию можно выключить.
    var routeAlternatives: Bool { didSet { store.set(routeAlternatives, forKey: Keys.alternatives) } }
    /// Варианты маршрута сравниваются с вашими поездками: «Знакомый», «Без
    /// ваших превышений» (RouteChoice). Считается на телефоне.
    var personalRoutes: Bool { didSet { store.set(personalRoutes, forKey: Keys.personalRoutes) } }
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
    /// Открывать спидометр при старте поездки. Спидометр — самый дешёвый экран
    /// приложения (чёрный OLED + растр вместо тайлов и двухсот маркеров), и он
    /// строился ради батареи — но был секретным: попасть на него можно было,
    /// только зная про тап по HUD. Ручное закрытие уважается до конца поездки.
    var dashboardAutoOpens: Bool { didSet { store.set(dashboardAutoOpens, forKey: Keys.dashboardAuto) } }
    /// Подсказка «Домой / На работу» на главном экране по выученному
    /// распорядку. Выключается целиком — обучение молчит вместе с ней.
    var destinationSuggestions: Bool { didSet { store.set(destinationSuggestions, forKey: Keys.destinationHints) } }
    /// Умная тишина: камеры, которые вы проезжаете регулярно и спокойно,
    /// перестают называться вслух (см. CameraFamiliarity). Выключенная —
    /// приложение говорит обо всех камерах, как в первый день.
    var smartSilence: Bool { didSet { store.set(smartSilence, forKey: Keys.smartSilence) } }
    /// Подсказки по памяти: «здесь часто ставят треногу» в местах, где водители
    /// отмечали радар снова и снова. Отдельно от отметок в реальном времени —
    /// это разные вещи по природе: там факт от живого человека, здесь догадка
    /// о прошлом, и выключать их хочется по отдельности.
    var tripodHints: Bool { didSet { store.set(tripodHints, forKey: Keys.tripodHints) } }

    /// Отправлять обезличенную статистику использования (см. `UsageStats`).
    /// Хранится инвертированно («выключено»), чтобы значение по умолчанию у
    /// `UserDefaults.bool` — false — означало включено: иначе после обновления
    /// приложения у всех оказалось бы выключено без их участия.
    var usageStatsEnabled: Bool {
        didSet { store.set(!usageStatsEnabled, forKey: Keys.usageStats) }
    }

    /// Профиль оповещений. Записывает нижележащие `voiceMode`/`alertMode`,
    /// поэтому остальной код о нём знать не обязан (см. AlertProfile).
    var alertProfile: AlertProfile {
        didSet {
            store.set(alertProfile.rawValue, forKey: Keys.alertProfile)
            guard let applied = alertProfile.applied else { return }
            if voiceMode != applied.voice { voiceMode = applied.voice }
            if alertMode != applied.mode { alertMode = applied.mode }
        }
    }
    /// Слои подложки — тумблеры в легенде карты. Пробки уважают выбор всегда:
    /// затор впереди нужен именно в дороге. Места (заправки, парковки,
    /// больницы, посты) в поездке гасятся сами — на скорости их подписи только
    /// засоряют карту, а стоя они и есть то, ради чего карту открывают.
    var mapTraffic: Bool { didSet { store.set(mapTraffic, forKey: Keys.mapTraffic) } }
    var mapPlaces: Bool { didSet { store.set(mapPlaces, forKey: Keys.mapPlaces) } }
    /// Дома на своей схеме. ВЫКЛЮЧЕНЫ по умолчанию, и это не экономия ради
    /// экономии.
    ///
    /// Замерено по подписанному индексу: набор домов весит 78 МБ из 347 МБ
    /// всей страны и 6,72 МБ из 13,86 МБ той окрестности, которую телефон
    /// тянет, стоя в центре Ташкента, — то есть половину всего трафика схемы
    /// ради слоя, который отвечает на вопрос последних двухсот метров. За
    /// рулём этот вопрос задают раз в поездку, а платят за него всю дорогу.
    /// Кто ищет подъезд — включит.
    var mapHouses: Bool { didSet { store.set(mapHouses, forKey: Keys.mapHouses) } }
    /// Тротуары. Тот же закон и та же причина, только дешевле: их 3 439 в
    /// одном центре против 8 455 дорог, и объясняют они, где кончается
    /// асфальт, — вопрос пешехода, а не водителя.
    var mapSidewalks: Bool { didSet { store.set(mapSidewalks, forKey: Keys.mapSidewalks) } }
    /// Новая карта (бета): основа OpenMapTiles и наши слои дороги по выпуску
    /// тайлов (docs/plan_map_offline.md). Включена по умолчанию в 2.0, чтобы
    /// её увидели тестировщики; выключатель — без релиза, если на живом
    /// телефоне что-то пойдёт не так.
    var mapModernStyle: Bool { didSet { store.set(mapModernStyle, forKey: Keys.mapModernStyle) } }
    /// 3D-вид: карта наклонена, видно дорогу вперёд (кнопка «3D» на карте).
    /// Запоминается: выбор человека сильнее режима.
    var map3D: Bool { didSet { store.set(map3D, forKey: Keys.map3D) } }
    /// Кнопки масштаба «+ / −» на карте. За рулём масштаб ведёт автозум по
    /// скорости, поэтому кнопки можно убрать в настройках.
    var mapZoomButtons: Bool { didSet { store.set(mapZoomButtons, forKey: Keys.mapZoomButtons) } }
    /// Имена знакомых автомобильных магнитол (BT): подключены к своей машине —
    /// автостарт не переспрашивает «вы за рулём?».
    var knownCarAudio: [String] { didSet { store.set(knownCarAudio, forKey: Keys.knownCarAudio) } }
    /// Режим оповещений: «Авто» сам различает город/трассу, вручную можно зафиксировать.
    var alertMode: AlertMode {
        didSet { store.set(alertMode.rawValue, forKey: Keys.alertMode) }
    }
    /// Подложка карты: тёмная / светлая / авто по времени суток.
    var mapAppearance: MapAppearance {
        didSet { store.set(mapAppearance.rawValue, forKey: Keys.mapAppearance) }
    }

    /// Чем рисуется карта. Меняется кнопкой слоёв НА КАРТЕ и действует сразу.
    var mapBase: MapBase {
        didSet { store.set(mapBase.rawValue, forKey: Keys.mapBase) }
    }

    /// Карту рисует ДВИЖОК (MapLibre) вместо самописной схемы.
    ///
    /// Третья подложка рядом с двумя существующими, а не замена им, и это не
    /// нерешительность: ровно так в проекте уже сделан переход панели —
    /// страница на движке встала рядом с рабочей, и обе сравнивались на одних
    /// и тех же местах. Пока новый рендер не выиграл по замерам на живом
    /// телефоне (нагрев, батарея, CarPlay), выключатель обязан быть у
    /// водителя, а не в голове у разработчика.
    ///
    /// По умолчанию ВЫКЛЮЧЕНО.
    var engineMap: Bool {
        didSet { store.set(engineMap, forKey: Keys.engineMap) }
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
        static let voiceMode = "voiceMode"
        static let overspeedVoice = "overspeedVoice"
        static let radius = "alertRadius"
        static let filter = "cameraFilter"
        static let autoStart = "autoStartTrip"        // legacy, только для миграции
        static let tripStartMode = "tripStartMode"
        static let volume = "alertVolume"
        static let home = "homePlace"
        static let work = "workPlace"
        static let alternatives = "routeAlternatives"
        static let personalRoutes = "personalRoutes"
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
        static let dashboardAuto = "dashboardAutoOpens"
        static let destinationHints = "destinationSuggestions"
        static let smartSilence = "smartSilence"
        static let tripodHints = "tripodHints"
        static let mapTraffic = "mapTraffic"
        static let mapPlaces = "mapPlaces"
        static let mapHouses = "mapHouses"
        static let mapSidewalks = "mapSidewalks"
        static let mapModernStyle = "mapModernStyle"
        static let map3D = "map3D"
        static let voiceBeforeMute = "voiceBeforeMute"
        static let mapZoomButtons = "mapZoomButtons"
        static let sketchWhileDriving = "sketchWhileDriving"
        static let engineMap = "engineMapEnabled"
        static let mapBase = "mapBase"
        static let alertMode = "alertMode"
        static let knownCarAudio = "knownCarAudio"
        static let usageStats = "usageStatsDisabled"
        static let alertProfile = "alertProfile"
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
            Keys.personalRoutes: true,
            Keys.turnByTurn: true,
            Keys.speedLimits: true,
            Keys.overspeed: 5.0,
            Keys.adaptive: true,
            Keys.nextCamera: true,
            Keys.digest: true,
            Keys.haptics: true,
            Keys.keepScreenOn: true,
            Keys.dashboardAuto: true,
            Keys.destinationHints: true,
            Keys.smartSilence: true,
            Keys.tripodHints: true,
            Keys.mapPlaces: true,
            Keys.mapModernStyle: true,
            Keys.map3D: true,
            Keys.mapZoomButtons: true,
        ])
        soundEnabled = store.bool(forKey: Keys.sound)
        // Миграция с трёх переключателей на один. Голос был выключен — «Молча»;
        // стоял тумблер «только при превышении» — это ровно «Умно»; иначе
        // «Умно» же: город на каждой камере говорить перестаёт, и это новый
        // разумный дефолт (голос поверх музыки надоедает за две недели).
        if let raw = store.string(forKey: Keys.voiceMode),
           let mode = VoiceMode(rawValue: raw) {
            voiceMode = mode
        } else if !store.bool(forKey: Keys.voice) {
            voiceMode = .off
        } else {
            voiceMode = .smart
        }
        overspeedVoice = OverspeedVoice(
            rawValue: store.string(forKey: Keys.overspeedVoice) ?? "") ?? .always
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
        personalRoutes = store.bool(forKey: Keys.personalRoutes)
        turnByTurnVoice = store.bool(forKey: Keys.turnByTurn)
        speedLimitsEnabled = store.bool(forKey: Keys.speedLimits)
        overspeedTolerance = store.double(forKey: Keys.overspeed)
        adaptiveGPS = store.bool(forKey: Keys.adaptive)
        showNextCamera = store.bool(forKey: Keys.nextCamera)
        keepScreenOn = store.bool(forKey: Keys.keepScreenOn)
        dashboardAutoOpens = store.bool(forKey: Keys.dashboardAuto)
        destinationSuggestions = store.bool(forKey: Keys.destinationHints)
        smartSilence = store.bool(forKey: Keys.smartSilence)
        tripodHints = store.bool(forKey: Keys.tripodHints)
        mapTraffic = store.bool(forKey: Keys.mapTraffic)
        mapPlaces = store.bool(forKey: Keys.mapPlaces)
        // Дома и тротуары — единственные слои схемы БЕЗ значения по умолчанию
        // в register: `bool(forKey:)` даёт false там, где ключа ещё нет, и это
        // ровно тот ответ, который нужен. Кто их включит — включит осознанно.
        mapHouses = store.bool(forKey: Keys.mapHouses)
        mapSidewalks = store.bool(forKey: Keys.mapSidewalks)
        mapModernStyle = store.bool(forKey: Keys.mapModernStyle)
        map3D = store.bool(forKey: Keys.map3D)
        mapZoomButtons = store.bool(forKey: Keys.mapZoomButtons)
        engineMap = store.bool(forKey: Keys.engineMap)
        // Перенос со старых тумблеров: выбор человека не теряется при
        // обновлении — кто включил схему, с ней и останется.
        if let saved = store.string(forKey: Keys.mapBase),
           let base = MapBase(rawValue: saved) {
            mapBase = base
        } else if store.bool(forKey: Keys.engineMap) {
            mapBase = .engine
        } else if store.bool(forKey: Keys.sketchWhileDriving) {
            // Схемы больше нет; выбравший СВОЮ карту получает ту, что осталась
            // своей, а не карту Apple. Ключ читается только ради этой миграции.
            mapBase = .engine
        } else {
            // С 2.0 по умолчанию — своя карта (новая, OpenMapTiles + наши слои).
            // Прежде по умолчанию стояла Apple, и свежая установка новой карты
            // не видела вовсе: она пряталась за кнопкой слоёв. Сознательный
            // выбор Apple сохранён ключом mapBase выше и здесь не трогается;
            // без пакета движка MapBase.resolved сам вернёт Apple.
            mapBase = .engine
        }
        alertMode = AlertMode(rawValue: store.string(forKey: Keys.alertMode) ?? "") ?? .auto
        knownCarAudio = store.stringArray(forKey: Keys.knownCarAudio) ?? []
        weeklyDigest = store.bool(forKey: Keys.digest)
        usageStatsEnabled = !store.bool(forKey: Keys.usageStats)
        // Переезд со старой версии: профиля ещё нет — выводим его из того, что
        // человек уже выбрал, чтобы ни одна привычка не сменилась молча.
        alertProfile = AlertProfile(rawValue: store.string(forKey: Keys.alertProfile) ?? "")
            ?? AlertProfile.matching(
                voice: VoiceMode(rawValue: store.string(forKey: Keys.voiceMode) ?? "") ?? .smart,
                mode: AlertMode(rawValue: store.string(forKey: Keys.alertMode) ?? "") ?? .auto)
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
