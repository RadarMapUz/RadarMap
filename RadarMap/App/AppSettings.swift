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
    /// Подпись пустого слота — с родом слова: «Дом · не задан», «Работа · не задана».
    var notSetTitle: String {
        switch self {
        case .home: return String(localized: "не задан")
        case .work: return String(localized: "не задана")
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

    /// Шкала «молча → умно → обо всех» — громкостью динамика, как в списке
    /// звука CarPlay (CarPlaySoundChoice): одна шкала — одни значки на
    /// телефоне и в машине. До 20.10 «Умно» было волшебной палочкой (она
    /// значит «авто» в других настройках и ничего не говорит о голосе), а
    /// «Обо всех» — тем же динамиком, что тумблер «Звук» в той же карточке.
    var symbol: String {
        switch self {
        case .off:    return "speaker.slash.fill"
        case .smart:  return "speaker.wave.1.fill"
        case .always: return "speaker.wave.3.fill"
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
    /// цветом скорости на HUD.
    case nearCameras
    /// Никогда: только цвет (у камеры — ещё и красная кромка экрана).
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
    /// Только при подключении к своей машине — CarPlay или выбранная в
    /// настройках магнитола по Bluetooth (26.2); отключились — поездка
    /// закончилась. Ни CoreMotion, ни вопросов: такси и автобус не пишутся,
    /// фоновые уведомления о камерах — тоже только в машине.
    case carOnly
    /// Только кнопкой. CoreMotion не работает вовсе — ещё и экономия заряда.
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:    return String(localized: "Авто")
        case .smart:   return String(localized: "Умный")
        case .carOnly: return String(localized: "Только в машине")
        case .manual:  return String(localized: "Ручной")
        }
    }

    var symbol: String {
        switch self {
        case .auto:    return "bolt.fill"
        case .smart:   return "wand.and.stars"
        case .carOnly: return "car.fill"
        case .manual:  return "hand.tap.fill"
        }
    }

    /// Слежение CoreMotion нужно только если поездку стартует движение.
    /// «Только в машине» стартует подключение — CoreMotion ему не нужен.
    var usesMotion: Bool { self == .auto || self == .smart }
}

/// Чем машина заправляется: какие плитки «в дороге» показывать в «Куда»
/// (сетка CarPlay — восемь мест, и «Зарядка» бензиновой машине — шум) и как
/// считать расходы (EnergySplit).
///
/// «Гибрид» до 21.10 был один и считался «бензин + электричество». Это два
/// разных мира: гибрид без розетки (Prius, Camry Hybrid) ездит только на
/// бензине, гибрид с розеткой (BYD DM-i, Li Auto) — на электричестве, пока
/// есть заряд. Сырое значение `hybrid` осталось за гибридом С розеткой —
/// так прежние настройки работают как раньше, пока водитель не ответит на
/// вопрос «заряжается ли от розетки» (`FuelProfile.hybridPlugConfirmed`).
enum VehicleEnergy: String, CaseIterable, Identifiable {
    case fuel, cng, lpg, hev, hybrid, electric

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fuel:     return String(localized: "Бензин")
        case .cng:      return String(localized: "Метан")
        case .lpg:      return String(localized: "Пропан")
        case .hev:      return String(localized: "Гибрид без розетки")
        case .hybrid:   return String(localized: "Гибрид с розеткой")
        case .electric: return String(localized: "Электромобиль")
        }
    }

    /// Плитки заведений в «Куда», по порядку. Машина на газу ищет сначала
    /// свой газ, а бензин — запасом: АГНКС меньше, и очередь на ней — быль.
    /// Гибриду без розетки зарядка не нужна вовсе.
    var stops: [Venue.Kind] {
        switch self {
        case .fuel, .hev: return [.fuel]
        case .cng:      return [.cng, .fuel]
        case .lpg:      return [.lpg, .fuel]
        case .electric: return [.charging]
        case .hybrid:   return [.charging, .fuel]
        }
    }
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

    /// Значения, которые профиль проставляет. `nil` — не трогать (свой профиль);
    /// `mode == nil` — режим контекста не трогать: «Тихий» — это только голос,
    /// и выбор «Город» обязан пережить «Тихий» туда-обратно (до 19.10 он
    /// сбрасывался в «Авто», а глушилка — нет: одно намерение, два исхода).
    var applied: (voice: VoiceMode, mode: AlertMode?)? {
        switch self {
        case .auto:    return (.smart, .auto)
        case .city:    return (.smart, .city)
        case .highway: return (.smart, .highway)
        case .quiet:   return (.off, nil)
        case .custom:  return nil
        }
    }

    /// Профиль после того, как голос или режим поменяли НЕ через профиль:
    /// глушилка, чипы голоса на карте, кнопка звука в машине. До 19.10
    /// профиль оставался прежним, и корень настроек писал «Авто», пока
    /// приложение молчало (аудит, plan_app_ui §0.5). «Свой» не трогаем: в
    /// нём человек сам крутит обе настройки, и прыжок на готовый профиль
    /// посреди правки спрятал бы сами переключатели.
    static func following(_ current: AlertProfile, voice: VoiceMode, mode: AlertMode) -> AlertProfile {
        if current == .custom { return .custom }
        // «Тихий» — это голос выключен; режим контекста ему безразличен.
        if let applied = current.applied, applied.voice == voice, applied.mode ?? mode == mode { return current }
        return matching(voice: voice, mode: mode)
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
    var voiceMode: VoiceMode {
        didSet {
            store.set(voiceMode.rawValue, forKey: Keys.voiceMode)
            followProfile()
        }
    }
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
    @ObservationIgnored var onMutedChanged: (() -> Void)?

    func setMuted(_ muted: Bool) {
        defer { onMutedChanged?() }
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
    /// Чем заправляется машина — плитки «АЗС» / «Зарядка» в «Куда» и расчёт
    /// расходов (EnergySplit). Выбор — через `chooseVehicle` (AppSettings+Energy).
    var vehicleEnergy: VehicleEnergy {
        didSet { store.set(vehicleEnergy.rawValue, forKey: Keys.vehicleEnergy) }
    }
    /// Машина, расход и цены (FuelCost, 12б.3; 21.10): только на телефоне.
    var fuelProfile: FuelProfile { didSet { saveFuelProfile() } }
    var homePlace: SavedPlace? { didSet { save(homePlace, forKey: Keys.home) } }
    var workPlace: SavedPlace? { didSet { save(workPlace, forKey: Keys.work) } }
    /// «Быть на работе к 9:00» (план 19.10, 8.6). nil — срока нет, и призрак
    /// говорит только «как обычно / дольше обычного», никогда «позже срока».
    var workArrivalTarget: ArrivalTarget? { didSet { saveArrivalTarget() } }
    /// Вопрос «вам нужно быть к 9:00?» уже был (ответ любой) — второй раз не задаём.
    var workTargetAsked: Bool { didSet { store.set(workTargetAsked, forKey: Keys.workTargetAsked) } }

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
    /// «Учитывать мою манеру езды» (33E): время прибытия с поправкой на свой
    /// темп относительно потока. Считается на телефоне; выключение стирает
    /// расчёт (RouteSettingsPage → PersonalPaceStore.erase).
    var personalPace: Bool { didSet { store.set(personalPace, forKey: Keys.personalPace) } }
    /// Подробный трек поездки со временем (TimedTrack) — для привязки видео
    /// регистратора. По умолчанию выключено: точка каждую секунду — это уже
    /// не «упрощённая линия для итогов», а точная история передвижений.
    var recordTimedTrack: Bool { didSet { store.set(recordTimedTrack, forKey: Keys.timedTrack) } }
    var turnByTurnVoice: Bool { didSet { store.set(turnByTurnVoice, forKey: Keys.turnByTurn) } }
    /// «Манёвры на приборке и HUD» (26.4): метаданные ведения CarPlay —
    /// машина с приборкой или проекцией сама рисует там стрелку и расстояние.
    /// По умолчанию — `AppConfig.carPlayNavigationMetadata` (выключено): с
    /// метаданными ряд полос на экране CarPlay не отправляется (25.H2).
    /// Система спрашивает об этом при начале навигационной сессии
    /// (`CPMapTemplate.startNavigationSession`), поэтому CarPlayGuidance при
    /// смене настройки начинает сессию заново.
    var carPlayNavigationMetadata: Bool {
        didSet { store.set(carPlayNavigationMetadata, forKey: Keys.navigationMetadata) }
    }
    /// Чей голос читает фразы (этап 16). nil — человек не выбирал: тогда
    /// записанный, если пакет для языка есть (`VoiceSource.effective`).
    var voiceSourceChoice: VoiceSource? {
        didSet {
            if let voiceSourceChoice {
                store.set(voiceSourceChoice.rawValue, forKey: Keys.voiceSource)
            } else {
                store.removeObject(forKey: Keys.voiceSource)
            }
        }
    }
    /// Чей записанный голос: женский или мужской набор (28.M). По умолчанию —
    /// женский; выбранного набора нет или он битый — звучит второй
    /// (`VoicePack.discover`).
    var voiceGender: VoiceGender {
        didSet { store.set(voiceGender.rawValue, forKey: Keys.voiceGender) }
    }
    #if DEBUG
    /// Отладка: пакет-заглушка (синтезатор macOS) вместо записи диктора —
    /// чтобы склейка, задержка и подмена проверялись до студии.
    var placeholderVoice: Bool { didSet { store.set(placeholderVoice, forKey: Keys.placeholderVoice) } }
    #endif
    /// Можно ли звучать заглушкой. В выпуске — никогда.
    var placeholderVoiceAllowed: Bool {
        #if DEBUG
        placeholderVoice || ProcessInfo.processInfo.arguments.contains("-voicePlaceholder")
        #else
        false
        #endif
    }
    var speedLimitsEnabled: Bool { didSet { store.set(speedLimitsEnabled, forKey: Keys.speedLimits) } }
    var overspeedTolerance: Double { didSet { store.set(overspeedTolerance, forKey: Keys.overspeed) } }
    var adaptiveGPS: Bool { didSet { store.set(adaptiveGPS, forKey: Keys.adaptive) } }
    var showNextCamera: Bool { didSet { store.set(showNextCamera, forKey: Keys.nextCamera) } }
    var weeklyDigest: Bool { didSet { store.set(weeklyDigest, forKey: Keys.digest) } }
    /// «Выезжайте раньше» (8.8.7): напоминание по будням, когда выезд в другое
    /// время выгоднее или нужен к сроку. Выключено, пока человек не попросит:
    /// уведомление о распорядке дня без спроса — навязчиво.
    var departureReminders: Bool { didSet { store.set(departureReminders, forKey: Keys.departureReminders) } }
    /// Предложение «Напоминать по будням» в «Итогах» уже было — второй раз не показываем.
    var departureRemindersAsked: Bool {
        didSet { store.set(departureRemindersAsked, forKey: Keys.departureRemindersAsked) }
    }
    var recentPlaces: [SavedPlace] { didSet { saveRecents() } }
    /// «Избранное» в «Моих местах» (7.2): свои места с именем — дача, школа,
    /// мама. Звезда на кнопке «Мои места» это обещала, а внутри были только
    /// Дом и Работа. Не уходят никуда, кроме этого телефона.
    var favoritePlaces: [SavedPlace] { didSet { saveFavorites() } }

    /// Фоновые баннеры о камерах (Центр уведомлений). Звука в поездке не касается.
    var backgroundAlerts: BackgroundAlertMode {
        didSet { store.set(backgroundAlerts.rawValue, forKey: Keys.backgroundAlerts) }
    }

    /// Тактильные сигналы при приближении к камере.
    var hapticsEnabled: Bool { didSet { store.set(hapticsEnabled, forKey: Keys.haptics) } }
    /// Не гасить экран в активной поездке (телефон в держателе — как у навигаторов).
    var keepScreenOn: Bool { didSet { store.set(keepScreenOn, forKey: Keys.keepScreenOn) } }
    /// Подсказка «Домой / На работу» на главном экране по выученному
    /// распорядку. Выключается целиком — обучение молчит вместе с ней.
    var destinationSuggestions: Bool { didSet { store.set(destinationSuggestions, forKey: Keys.destinationHints) } }
    /// Экран блокировки без дома и работы: «Дорога» вместо «На работу» и
    /// плашка поездки без названия цели.
    var lockScreenPrivate: Bool { didSet { store.set(lockScreenPrivate, forKey: Keys.lockScreenPrivate) } }
    /// Время дороги дом↔работа по участкам (CommuteProfile) — для прогноза
    /// «приеду в 9:12». Хранится инвертированно: включено по умолчанию.
    var commuteLearning: Bool { didSet { store.set(!commuteLearning, forKey: Keys.commuteLearningOff) } }
    /// Умная тишина: камеры, которые вы проезжаете регулярно и спокойно,
    /// перестают называться вслух (см. CameraFamiliarity). Выключенная —
    /// приложение говорит обо всех камерах, как в первый день.
    var smartSilence: Bool { didSet { store.set(smartSilence, forKey: Keys.smartSilence) } }
    /// Подсказки по памяти: «здесь часто ставят треногу» в местах, где водители
    /// отмечали радар снова и снова. Отдельно от отметок в реальном времени —
    /// это разные вещи по природе: там факт от живого человека, здесь догадка
    /// о прошлом, и выключать их хочется по отдельности.
    var tripodHints: Bool { didSet { store.set(tripodHints, forKey: Keys.tripodHints) } }
    /// Ночной голос (12.6): после заката фраза о камере короче — «Камера,
    /// 300 метров» вместо полной на трассе. Громкость НЕ меняется: короче,
    /// но не тише (VoiceDirector.decide). Включено по умолчанию.
    var nightVoice: Bool { didSet { store.set(nightVoice, forKey: Keys.nightVoice) } }
    /// «Работаю водителем» (такси, курьер — 12б.9): поездки собираются в
    /// смены, без дороги на работу и подсказок «Домой», голос короткий.
    var workDriverMode: Bool { didSet { store.set(workDriverMode, forKey: Keys.workDriverMode) } }
    /// Госномер для «Проверить штрафы» (FineCheck): только на телефоне,
    /// пустая строка — не задан. На сервер не уходит никогда.
    var licensePlate: String { didSet { store.set(licensePlate, forKey: Keys.licensePlate) } }
    /// «Где машина»: метка машины и строка «Машина · 350 м» после парковки
    /// (ParkedCar). Выключенная — точка стирается.
    var parkedCarHint: Bool { didSet { store.set(parkedCarHint, forKey: Keys.parkedCarHint) } }

    /// Отправлять обезличенную статистику использования (см. `UsageStats`).
    /// Хранится инвертированно («выключено»), чтобы значение по умолчанию у
    /// `UserDefaults.bool` — false — означало включено: иначе после обновления
    /// приложения у всех оказалось бы выключено без их участия.
    var usageStatsEnabled: Bool {
        didSet { store.set(!usageStatsEnabled, forKey: Keys.usageStats) }
    }

    /// Пробки на карте и в времени маршрута. Хранится инвертированно — по той
    /// же причине, что статистика: включено по умолчанию и после обновления.
    var trafficShown: Bool {
        didSet { store.set(!trafficShown, forKey: Keys.trafficHidden) }
    }

    /// Помогать с пробками: обезличенные куски следа поездки (TrafficProbes).
    /// Без устройства, без концов поездки, без мест у дома и работы.
    var trafficContribution: Bool {
        didSet { store.set(!trafficContribution, forKey: Keys.trafficContributionOff) }
    }
    /// Напоминания об обслуживании машины (18.3). Включены: напоминать есть о
    /// чём, только когда водитель сам ввёл пробег или даты. Хранится
    /// выключение — без регистрации умолчания.
    var maintenanceReminders: Bool {
        didSet { store.set(!maintenanceReminders, forKey: Keys.maintenanceRemindersOff) }
    }

    /// Погода на перевалах (19.2): голос и баннер «На перевале Камчик туман».
    /// Хранится инвертированно, как пробки: включено по умолчанию и после
    /// обновления.
    var roadWeatherAlerts: Bool {
        didSet { store.set(!roadWeatherAlerts, forKey: Keys.roadWeatherOff) }
    }

    /// Профиль оповещений. Записывает нижележащие `voiceMode`/`alertMode`,
    /// поэтому остальной код о нём знать не обязан (см. AlertProfile).
    var alertProfile: AlertProfile {
        didSet {
            store.set(alertProfile.rawValue, forKey: Keys.alertProfile)
            // Профиль выведен из настроек (followProfile) — применять нечего.
            guard !profileFollowing, let applied = alertProfile.applied else { return }
            applyingProfile = true
            defer { applyingProfile = false }
            if voiceMode != applied.voice { voiceMode = applied.voice }
            if let mode = applied.mode, alertMode != mode { alertMode = mode }
        }
    }
    /// Профиль сейчас сам проставляет голос и режим: промежуточное сочетание
    /// (голос уже новый, режим ещё старый) не должно перевыбрать профиль.
    @ObservationIgnored private var applyingProfile = false
    /// Профиль выводится из настроек — его didSet не применяет их обратно.
    @ObservationIgnored private var profileFollowing = false

    private func followProfile() {
        guard !applyingProfile, !profileFollowing else { return }
        let next = AlertProfile.following(alertProfile, voice: voiceMode, mode: alertMode)
        guard next != alertProfile else { return }
        profileFollowing = true
        defer { profileFollowing = false }
        alertProfile = next
    }
    /// Слои подложки — тумблеры в легенде карты. Пробки уважают выбор всегда:
    /// затор впереди нужен именно в дороге. Места (заправки, парковки,
    /// больницы, посты) в поездке гасятся сами — на скорости их подписи только
    /// засоряют карту, а стоя они и есть то, ради чего карту открывают.
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
    ///
    /// С 21.10 (25.D) — ВКЛЮЧЕНЫ, если водитель сам их не выключал. Расчёт
    /// выше — про дома своей схемы (отдельный набор файлов), а схема убрана
    /// 11.10: на новой карте дома лежат в том же тайле OpenMapTiles, что и
    /// дороги, и тумблер трафика не экономит. Зато под наклоном в пути они и
    /// есть «богатый» кадр («у Яндекса дома объёмом», владелец, 21.10).
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
    /// Ключ этого телефона (с 43): наклон, включённый «Объёмным видом» на
    /// новом телефоне, не приезжает на старый.
    var map3D: Bool {
        didSet {
            store.set(map3D, forKey: Keys.map3D)
            // Ручной выбор кнопки «3D», пока включён объёмный вид, — главнее
            // возврата наклона при его выключении.
            if drive3D, !applyingDrive3DPitch, map3D != oldValue {
                store.set(true, forKey: Keys.drive3DPitchTouched)
            }
        }
    }
    /// Наклон меняет сам «Объёмный вид», а не кнопка.
    @ObservationIgnored private var applyingDrive3DPitch = false
    /// «Объёмный вид в поездке» (43, Drive3D): светлый тихий мир, лента
    /// маршрута во всю сторону и сужение к полосам у манёвра — на телефоне и
    /// в машине. Ключ этого телефона (не iCloud: «вкл» с нового телефона не
    /// перекрывает «выкл» на слабом), умолчание — по классу железа
    /// (Drive3D.defaultEnabled). Включение наклоняет карту поездки (map3D),
    /// выключение возвращает наклон, какой был до включения.
    var drive3D: Bool {
        didSet {
            store.set(drive3D, forKey: Keys.drive3D)
            guard drive3D != oldValue else { return }
            applyingDrive3DPitch = true
            defer { applyingDrive3DPitch = false }
            if drive3D {
                store.set(map3D, forKey: Keys.drive3DPitchBefore)
                store.set(false, forKey: Keys.drive3DPitchTouched)
                map3D = true
            } else if !store.bool(forKey: Keys.drive3DPitchTouched),
                      let before = store.object(forKey: Keys.drive3DPitchBefore) as? Bool {
                map3D = before
            }
        }
    }
    /// Кнопки масштаба «+ / −» на карте. За рулём масштаб ведёт автозум по
    /// скорости, поэтому кнопки можно убрать в настройках.
    var mapZoomButtons: Bool { didSet { store.set(mapZoomButtons, forKey: Keys.mapZoomButtons) } }
    /// Имена знакомых автомобильных магнитол (BT): подключены к своей машине —
    /// автостарт не переспрашивает «вы за рулём?».
    var knownCarAudio: [String] { didSet { store.set(knownCarAudio, forKey: Keys.knownCarAudio) } }
    /// Устройства своей машины, выбранные в настройках (CarLink, 26.2): по
    /// ним «Только в машине» начинает поездку, а «Авто» не пишет чужую молча.
    var carDevices: [CarAudioDevice] { didSet { saveCarDevices() } }
    /// Режим оповещений: «Авто» сам различает город/трассу, вручную можно зафиксировать.
    var alertMode: AlertMode {
        didSet {
            store.set(alertMode.rawValue, forKey: Keys.alertMode)
            followProfile()
        }
    }
    /// Подложка карты: тёмная / светлая / авто по времени суток.
    var mapAppearance: MapAppearance {
        didSet { store.set(mapAppearance.rawValue, forKey: Keys.mapAppearance) }
    }

    /// Значок «я» на карте: стрелка, машина, спорткар, звездолёт. Один на все
    /// подложки и на экран машины — менять «себя» вместе с подложкой значило
    /// бы терять себя взглядом при каждом переключении (см. CursorStyle).
    var cursorStyle: CursorStyle {
        didSet { store.set(cursorStyle.rawValue, forKey: Keys.cursorStyle) }
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
        static let vehicleEnergy = "vehicleEnergy"
        static let fuelProfile = "fuelProfile"
        static let volume = "alertVolume"
        static let home = "homePlace"
        static let work = "workPlace"
        static let workTarget = "workArrivalTarget"
        static let workTargetAsked = "workTargetAsked"
        static let departureReminders = "departureReminders"
        static let departureRemindersAsked = "departureRemindersAsked"
        static let alternatives = "routeAlternatives"
        static let personalRoutes = "personalRoutes"
        static let personalPace = "personalPace"
        static let timedTrack = "recordTimedTrack"
        static let turnByTurn = "turnByTurnVoice"
        static let navigationMetadata = "carPlayNavigationMetadata"
        static let voiceSource = "voiceSource"
        static let voiceGender = "voiceGender"
        static let placeholderVoice = "placeholderVoice"
        static let speedLimits = "speedLimitsEnabled"
        static let overspeed = "overspeedTolerance"
        static let adaptive = "adaptiveGPS"
        static let nextCamera = "showNextCamera"
        static let digest = "weeklyDigest"
        static let recents = "recentPlaces"
        static let favorites = "favoritePlaces"
        static let language = "appLanguage"
        static let backgroundAlerts = "backgroundAlerts"
        static let haptics = "hapticsEnabled"
        static let mapAppearance = "mapAppearance"
        static let keepScreenOn = "keepScreenOn"
        static let destinationHints = "destinationSuggestions"
        static let commuteLearningOff = "commuteLearningOff"
        static let smartSilence = "smartSilence"
        static let tripodHints = "tripodHints"
        static let nightVoice = "nightVoice"
        static let workDriverMode = "workDriverMode"
        static let licensePlate = "licensePlate"
        static let parkedCarHint = "parkedCarHint"
        static let mapPlaces = "mapPlaces"
        static let mapHouses = "mapHouses"
        static let mapSidewalks = "mapSidewalks"
        static let mapModernStyle = "mapModernStyle"
        static let map3D = "map3D"
        static let drive3D = "drive3D"
        static let drive3DPitchBefore = "drive3DPitchBefore"
        static let drive3DPitchTouched = "drive3DPitchTouched"
        static let voiceBeforeMute = "voiceBeforeMute"
        static let mapZoomButtons = "mapZoomButtons"
        static let cursorStyle = "cursorStyle"
        static let alertMode = "alertMode"
        static let knownCarAudio = "knownCarAudio"
        static let carDevices = "carDevices"
        static let usageStats = "usageStatsDisabled"
        static let trafficHidden = "trafficHidden"
        static let trafficContributionOff = "trafficContributionOff"
        static let roadWeatherOff = "roadWeatherOff"
        static let maintenanceRemindersOff = "maintenanceRemindersOff"
        static let alertProfile = "alertProfile"
        static let lockScreenPrivate = "lockScreenPrivate"
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
            Keys.personalPace: true,
            Keys.turnByTurn: true,
            Keys.navigationMetadata: AppConfig.carPlayNavigationMetadata,
            Keys.speedLimits: true,
            Keys.overspeed: 5.0,
            Keys.adaptive: true,
            Keys.nextCamera: true,
            Keys.digest: true,
            Keys.haptics: true,
            Keys.keepScreenOn: true,
            Keys.destinationHints: true,
            Keys.smartSilence: true,
            Keys.tripodHints: true,
            Keys.nightVoice: true,
            Keys.parkedCarHint: true,
            Keys.mapPlaces: true,
            Keys.mapModernStyle: true,
            Keys.map3D: true,
            // Масштаб — щипком; кнопки +/− по желанию (панель «Карта»). До
            // этапа 31 были включены и делали колонку из шести кругов.
            Keys.mapZoomButtons: false,
        ])
        soundEnabled = store.bool(forKey: Keys.sound)
        // Миграция с трёх переключателей на один. Голос был выключен — «Молча»;
        // стоял тумблер «только при превышении» — это ровно «Умно»; иначе
        // «Умно» же: город на каждой камере говорить перестаёт, и это новый
        // разумный дефолт (голос поверх музыки надоедает за две недели).
        let loadedVoice: VoiceMode
        if let raw = store.string(forKey: Keys.voiceMode),
           let mode = VoiceMode(rawValue: raw) {
            loadedVoice = mode
        } else if !store.bool(forKey: Keys.voice) {
            loadedVoice = .off
        } else {
            loadedVoice = .smart
        }
        voiceMode = loadedVoice
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
        vehicleEnergy = VehicleEnergy(rawValue: store.string(forKey: Keys.vehicleEnergy) ?? "") ?? .fuel
        fuelProfile = Self.loadFuelProfile(store)
        homePlace = Self.load(store, Keys.home)
        workArrivalTarget = Self.loadArrivalTarget(store)
        workTargetAsked = store.bool(forKey: Keys.workTargetAsked)
        departureReminders = store.bool(forKey: Keys.departureReminders)
        departureRemindersAsked = store.bool(forKey: Keys.departureRemindersAsked)
        workPlace = Self.load(store, Keys.work)
        routeAlternatives = store.bool(forKey: Keys.alternatives)
        personalRoutes = store.bool(forKey: Keys.personalRoutes)
        personalPace = store.bool(forKey: Keys.personalPace)
        recordTimedTrack = store.bool(forKey: Keys.timedTrack)
        turnByTurnVoice = store.bool(forKey: Keys.turnByTurn)
        carPlayNavigationMetadata = store.bool(forKey: Keys.navigationMetadata)
        voiceSourceChoice = VoiceSource(rawValue: store.string(forKey: Keys.voiceSource) ?? "")
        voiceGender = VoiceGender(rawValue: store.string(forKey: Keys.voiceGender) ?? "") ?? .female
        #if DEBUG
        placeholderVoice = store.bool(forKey: Keys.placeholderVoice)
        #endif
        speedLimitsEnabled = store.bool(forKey: Keys.speedLimits)
        overspeedTolerance = store.double(forKey: Keys.overspeed)
        adaptiveGPS = store.bool(forKey: Keys.adaptive)
        showNextCamera = store.bool(forKey: Keys.nextCamera)
        keepScreenOn = store.bool(forKey: Keys.keepScreenOn)
        destinationSuggestions = store.bool(forKey: Keys.destinationHints)
        commuteLearning = !store.bool(forKey: Keys.commuteLearningOff)
        lockScreenPrivate = store.bool(forKey: Keys.lockScreenPrivate)
        smartSilence = store.bool(forKey: Keys.smartSilence)
        tripodHints = store.bool(forKey: Keys.tripodHints)
        nightVoice = store.bool(forKey: Keys.nightVoice)
        workDriverMode = store.bool(forKey: Keys.workDriverMode)
        licensePlate = store.string(forKey: Keys.licensePlate) ?? ""
        parkedCarHint = store.bool(forKey: Keys.parkedCarHint)
        mapPlaces = store.bool(forKey: Keys.mapPlaces)
        // Тротуары — БЕЗ значения по умолчанию: `bool(forKey:)` даёт false там,
        // где ключа ещё нет. Дома с 21.10 — включены, пока водитель сам их не
        // выключил (явное «нет» сохранено и уважается).
        mapHouses = store.object(forKey: Keys.mapHouses) as? Bool ?? true
        mapSidewalks = store.bool(forKey: Keys.mapSidewalks)
        mapModernStyle = store.bool(forKey: Keys.mapModernStyle)
        map3D = store.bool(forKey: Keys.map3D)
        drive3D = store.object(forKey: Keys.drive3D) as? Bool
            ?? Drive3D.defaultEnabled(machine: Self.hardwareMachine)
        mapZoomButtons = store.bool(forKey: Keys.mapZoomButtons)
        // Подложка одна — движок (карта Apple и схема убраны 11.10): старые
        // ключи mapBase/engineMapEnabled/sketchWhileDriving больше не читаются.
        let loadedMode = AlertMode(rawValue: store.string(forKey: Keys.alertMode) ?? "") ?? .auto
        alertMode = loadedMode
        cursorStyle = CursorStyle(stored: store.string(forKey: Keys.cursorStyle))
        knownCarAudio = store.stringArray(forKey: Keys.knownCarAudio) ?? []
        carDevices = Self.loadCarDevices(store)
        weeklyDigest = store.bool(forKey: Keys.digest)
        usageStatsEnabled = !store.bool(forKey: Keys.usageStats)
        trafficShown = !store.bool(forKey: Keys.trafficHidden)
        trafficContribution = !store.bool(forKey: Keys.trafficContributionOff)
        roadWeatherAlerts = !store.bool(forKey: Keys.roadWeatherOff)
        maintenanceReminders = !store.bool(forKey: Keys.maintenanceRemindersOff)
        // Переезд со старой версии: профиля ещё нет — выводим его из того, что
        // человек уже выбрал, чтобы ни одна привычка не сменилась молча.
        let storedProfile = AlertProfile(rawValue: store.string(forKey: Keys.alertProfile) ?? "")
            ?? AlertProfile.matching(
                voice: VoiceMode(rawValue: store.string(forKey: Keys.voiceMode) ?? "") ?? .smart,
                mode: AlertMode(rawValue: store.string(forKey: Keys.alertMode) ?? "") ?? .auto)
        // Профиль, сохранённый до 19.10, мог разойтись с голосом (глушилка его
        // не трогала) — сверяем при запуске тем же правилом, что и на ходу.
        alertProfile = AlertProfile.following(storedProfile, voice: loadedVoice, mode: loadedMode)
        appLanguage = AppLanguage(rawValue: store.string(forKey: Keys.language) ?? "") ?? .system
        backgroundAlerts = BackgroundAlertMode(rawValue: store.string(forKey: Keys.backgroundAlerts) ?? "") ?? .all
        hapticsEnabled = store.bool(forKey: Keys.haptics)
        mapAppearance = MapAppearance(rawValue: store.string(forKey: Keys.mapAppearance) ?? "") ?? .auto
        do {
            let data = store.data(forKey: Keys.favorites)
            favoritePlaces = try data.map { try JSONDecoder().decode([SavedPlace].self, from: $0) } ?? []
        } catch {
            Log.app.error("favoritePlaces не декодировались: \(error.localizedDescription, privacy: .public)")
            favoritePlaces = []
        }
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

    /// Добавить в «Избранное»: то же место (ближе 150 м) не дублируется —
    /// имя обновляется, место поднимается наверх.
    func addFavorite(_ place: SavedPlace) {
        favoritePlaces = Self.favorites(adding: place, to: favoritePlaces)
    }

    nonisolated static func favorites(adding place: SavedPlace, to list: [SavedPlace]) -> [SavedPlace] {
        var next = list.filter {
            GeoMath.fastDistance($0.lat, $0.lon, place.lat, place.lon) > AppConfig.favoriteSameMeters
        }
        next.insert(place, at: 0)
        return Array(next.prefix(AppConfig.favoritePlacesMax))
    }

    private func saveFavorites() {
        do {
            store.set(try JSONEncoder().encode(favoritePlaces), forKey: Keys.favorites)
        } catch {
            Log.app.error("favoritePlaces не сохранились: \(error.localizedDescription, privacy: .public)")
        }
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
        // Кодирование двух строк и координат не падает; nil ниже — осознанное удаление.
        if let place, let data = try? JSONEncoder().encode(place) {
            store.set(data, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    private func saveArrivalTarget() {
        guard let workArrivalTarget else { return store.removeObject(forKey: Keys.workTarget) }
        do {
            store.set(try JSONEncoder().encode(workArrivalTarget), forKey: Keys.workTarget)
        } catch {
            Log.app.error("workArrivalTarget не сохранился: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadArrivalTarget(_ store: UserDefaults) -> ArrivalTarget? {
        guard let data = store.data(forKey: Keys.workTarget) else { return nil }
        do {
            return try JSONDecoder().decode(ArrivalTarget.self, from: data)
        } catch {
            Log.app.error("workArrivalTarget не декодировался: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func saveFuelProfile() {
        do {
            store.set(try JSONEncoder().encode(fuelProfile), forKey: Keys.fuelProfile)
        } catch {
            Log.app.error("fuelProfile не сохранился: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadFuelProfile(_ store: UserDefaults) -> FuelProfile {
        guard let data = store.data(forKey: Keys.fuelProfile) else { return FuelProfile() }
        do {
            return try JSONDecoder().decode(FuelProfile.self, from: data)
        } catch {
            Log.app.error("fuelProfile не декодировался: \(error.localizedDescription, privacy: .public)")
            return FuelProfile()
        }
    }

    private static func loadCarDevices(_ store: UserDefaults) -> [CarAudioDevice] {
        guard let data = store.data(forKey: Keys.carDevices) else { return [] }
        do {
            return try JSONDecoder().decode([CarAudioDevice].self, from: data)
        } catch {
            Log.app.error("carDevices не декодировались: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func saveCarDevices() {
        do {
            store.set(try JSONEncoder().encode(carDevices), forKey: Keys.carDevices)
        } catch {
            Log.app.error("carDevices не закодировались: \(error.localizedDescription, privacy: .public)")
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


// MARK: - Настройки через iCloud (27.F)
//
// Белый список, а не чёрный: новая настройка по умолчанию остаётся на этом
// телефоне, пока её не внесут сюда осознанно. Не едут: Bluetooth машины и
// узнанное аудио (своё у каждого телефона), регистратор, госномер, источник
// голоса (пакет скачан здесь), «Как начинать поездку» (держится за
// Bluetooth и CoreMotion этого телефона), временное «до машины» CarPlay,
// напоминания о выезде (разрешение на уведомления — у телефона). Места и
// машина — не здесь: они в CloudKit, зашифрованными.

extension AppSettings {
    static let cloudSettingKinds: [String: CloudSettingsSync.Kind] = [
        Keys.sound: .bool, Keys.voiceMode: .string, Keys.overspeedVoice: .string,
        Keys.radius: .double, Keys.filter: .string, Keys.volume: .double,
        Keys.alternatives: .bool, Keys.personalRoutes: .bool, Keys.turnByTurn: .bool,
        Keys.speedLimits: .bool, Keys.overspeed: .double, Keys.nextCamera: .bool,
        Keys.digest: .bool, Keys.language: .string, Keys.backgroundAlerts: .string,
        Keys.haptics: .bool, Keys.mapAppearance: .string, Keys.keepScreenOn: .bool,
        Keys.destinationHints: .bool, Keys.commuteLearningOff: .bool, Keys.smartSilence: .bool,
        Keys.tripodHints: .bool, Keys.nightVoice: .bool, Keys.workDriverMode: .bool, Keys.parkedCarHint: .bool,
        Keys.mapPlaces: .bool, Keys.mapHouses: .bool, Keys.mapSidewalks: .bool,
        Keys.mapModernStyle: .bool, Keys.mapZoomButtons: .bool,
        Keys.cursorStyle: .string, Keys.alertMode: .string, Keys.alertProfile: .string,
        Keys.usageStats: .bool, Keys.trafficHidden: .bool, Keys.trafficContributionOff: .bool,
        Keys.roadWeatherOff: .bool, Keys.maintenanceRemindersOff: .bool,
        Keys.lockScreenPrivate: .bool,
    ]

    /// Ключи, которые принадлежат этому телефону, — для теста: ни один не
    /// может попасть в белый список.
    static let deviceOnlySettingKeys: Set<String> = [
        Keys.carDevices, Keys.knownCarAudio, Keys.licensePlate, Keys.timedTrack,
        Keys.voiceSource, Keys.voiceGender, Keys.placeholderVoice, Keys.tripStartMode, Keys.voiceBeforeMute,
        Keys.home, Keys.work, Keys.recents, Keys.favorites, Keys.fuelProfile, Keys.vehicleEnergy,
        Keys.navigationMetadata, Keys.departureReminders, Keys.departureRemindersAsked,
        Keys.workTarget, Keys.workTargetAsked, Keys.adaptive, Keys.drive3D, Keys.drive3DPitchBefore,
        Keys.drive3DPitchTouched, Keys.map3D,
    ]

    /// Модель железа («iPhone14,2») — для умолчаний по классу телефона.
    static let hardwareMachine: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()

    /// Свои значения из белого списка (как они лежат в UserDefaults).
    func cloudSettingsSnapshot() -> [String: CloudSettingValue] {
        var result: [String: CloudSettingValue] = [:]
        for (key, kind) in Self.cloudSettingKinds {
            if let value = CloudSettingsSync.value(from: store.object(forKey: key), kind: kind) {
                result[key] = value
            }
        }
        return result
    }

    /// Пришедшие из iCloud: голос и режим — раньше профиля (профиль сверяется
    /// по ним, как на исходном телефоне).
    func applyCloudSettings(_ values: [String: CloudSettingValue]) {
        let late: Set<String> = [Keys.alertProfile]
        for key in values.keys.sorted(by: { (late.contains($0) ? 1 : 0, $0) < (late.contains($1) ? 1 : 0, $1) }) {
            guard let value = values[key] else { continue }
            applyCloudSetting(key, value)
        }
    }

    private func applyCloudSetting(_ key: String, _ value: CloudSettingValue) {
        switch (key, value) {
        case (Keys.sound, .bool(let v)): soundEnabled = v
        case (Keys.voiceMode, .string(let v)): if let mode = VoiceMode(rawValue: v) { voiceMode = mode }
        case (Keys.overspeedVoice, .string(let v)): if let mode = OverspeedVoice(rawValue: v) { overspeedVoice = mode }
        case (Keys.radius, .double(let v)): alertRadius = v
        case (Keys.filter, .string(let v)): if let mode = CameraFilter(rawValue: v) { filter = mode }
        case (Keys.volume, .double(let v)): alertVolume = v
        case (Keys.alternatives, .bool(let v)): routeAlternatives = v
        case (Keys.personalRoutes, .bool(let v)): personalRoutes = v
        case (Keys.turnByTurn, .bool(let v)): turnByTurnVoice = v
        case (Keys.speedLimits, .bool(let v)): speedLimitsEnabled = v
        case (Keys.overspeed, .double(let v)): overspeedTolerance = v
        case (Keys.nextCamera, .bool(let v)): showNextCamera = v
        case (Keys.digest, .bool(let v)): weeklyDigest = v
        case (Keys.language, .string(let v)): if let language = AppLanguage(rawValue: v) { appLanguage = language }
        case (Keys.backgroundAlerts, .string(let v)): if let mode = BackgroundAlertMode(rawValue: v) { backgroundAlerts = mode }
        case (Keys.haptics, .bool(let v)): hapticsEnabled = v
        case (Keys.mapAppearance, .string(let v)): if let mode = MapAppearance(rawValue: v) { mapAppearance = mode }
        case (Keys.keepScreenOn, .bool(let v)): keepScreenOn = v
        case (Keys.destinationHints, .bool(let v)): destinationSuggestions = v
        case (Keys.commuteLearningOff, .bool(let v)): commuteLearning = !v
        case (Keys.lockScreenPrivate, .bool(let v)): lockScreenPrivate = v
        case (Keys.smartSilence, .bool(let v)): smartSilence = v
        case (Keys.tripodHints, .bool(let v)): tripodHints = v
        case (Keys.nightVoice, .bool(let v)): nightVoice = v
        case (Keys.workDriverMode, .bool(let v)): workDriverMode = v
        case (Keys.parkedCarHint, .bool(let v)): parkedCarHint = v
        case (Keys.mapPlaces, .bool(let v)): mapPlaces = v
        case (Keys.mapHouses, .bool(let v)): mapHouses = v
        case (Keys.mapSidewalks, .bool(let v)): mapSidewalks = v
        case (Keys.mapModernStyle, .bool(let v)): mapModernStyle = v
        case (Keys.mapZoomButtons, .bool(let v)): mapZoomButtons = v
        case (Keys.cursorStyle, .string(let v)): cursorStyle = CursorStyle(stored: v)
        case (Keys.alertMode, .string(let v)): if let mode = AlertMode(rawValue: v) { alertMode = mode }
        case (Keys.alertProfile, .string(let v)): if let profile = AlertProfile(rawValue: v) { alertProfile = profile }
        case (Keys.usageStats, .bool(let v)): usageStatsEnabled = !v
        case (Keys.trafficHidden, .bool(let v)): trafficShown = !v
        case (Keys.trafficContributionOff, .bool(let v)): trafficContribution = !v
        case (Keys.roadWeatherOff, .bool(let v)): roadWeatherAlerts = !v
        case (Keys.maintenanceRemindersOff, .bool(let v)): maintenanceReminders = !v
        default:
            Log.app.notice("настройка \(key, privacy: .public) из iCloud не применена: ключ или вид неизвестен")
        }
    }
}
