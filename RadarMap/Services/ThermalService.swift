//
//  ThermalService.swift
//  RadarMap
//
//  Реакция на перегрев телефона.
//
//  Сценарий типовой ровно для нашего пользователя: Ташкент, лето, телефон в
//  держателе на лобовом под солнцем, экран на максимуме, GPS в непрерывном
//  режиме, карта перерисовывается каждую секунду. Через 15–20 минут iOS уходит
//  в `.serious` и САМА режет частоту процессора. Приложение об этом не знало и
//  продолжало просить прежнее — получалось именно то, что человек опишет
//  словом «лагает», причём на симуляторе такого не увидеть никогда.
//
//  Что урезаем и в каком порядке — вопрос приоритетов, а не экономии: за рулём
//  голос важнее картинки. Поэтому под нагрузкой первыми уходят украшения карты,
//  а оповещения о камерах не трогаются ни на одной ступени.
//

import Foundation
import Observation
import os

/// Насколько мы себя урезали. Порядок значим: `.full` < `.reduced` < `.minimal`.
nonisolated enum PerformanceMode: Int, Comparable, Sendable {
    /// Всё как обычно.
    case full
    /// Телефон греется: маркеров меньше, тепловые линии выключены, ретайл реже.
    case reduced
    /// Телефон горячий: карта почти не перерисовывается. Остаётся HUD и голос.
    case minimal

    static func < (lhs: PerformanceMode, rhs: PerformanceMode) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(thermalState: ProcessInfo.ThermalState) {
        switch thermalState {
        case .nominal, .fair: self = .full
        case .serious:        self = .reduced
        case .critical:       self = .minimal
        @unknown default:     self = .full   // незнакомая ступень — не паникуем
        }
    }

    /// Сколько камер рисуем на экране. Дальше `CameraMapContent` сам решит, что
    /// не поместившееся отдать кластерами, — камера не пропадает, она
    /// становится частью посчитанной группы.
    var annotationBudget: Int {
        switch self {
        case .full:    return AppConfig.maxVisibleAnnotations
        case .reduced: return AppConfig.maxVisibleAnnotations / 3
        case .minimal: return AppConfig.maxVisibleAnnotations / 8
        }
    }

    /// Рисовать ли тепловые линии превышений на карте Итогов: украшение,
    /// которое считается по всему треку и в перегрев не нужно.
    var drawsHeatLines: Bool { self == .full }

    /// Сколько маркеров рисует карта CarPlay — та же лестница ÷1/÷3/÷8, что у
    /// телефонной карты: раньше CarPlay держал все 40 при любом перегреве, и
    /// чип «Жарко — экономлю экран» рядом с ней просто врал.
    var carPlayAnnotationBudget: Int {
        switch self {
        case .full:    return AppConfig.carPlayMaxCameraMarkers
        case .reduced: return AppConfig.carPlayMaxCameraMarkers / 3
        case .minimal: return AppConfig.carPlayMaxCameraMarkers / 8
        }
    }

    /// Сколько линий окрестной сети чертит схема на приборке. Сеть — контекст,
    /// а не предупреждение: при бюджете первыми выживают ближние к машине
    /// линии, а дорога камеры, маршрут и трек не режутся ни на одной ступени.
    var sketchNetworkBudget: Int {
        switch self {
        case .full:    return 80
        case .reduced: return 32
        case .minimal: return 0
        }
    }

    /// Сколько полигонов местности чертит схема. Ноль в перегреве: вода и
    /// зелень — ориентиры, а не предупреждения, и гаснут раньше всего
    /// остального, что несёт смысл.
    var sketchAreaBudget: Int {
        switch self {
        case .full:    return 400
        case .reduced: return 120
        case .minimal: return 0
        }
    }

    /// Мелкая отделка схемы: осевая разметка, шевроны односторонних и светлая
    /// жила ленты маршрута.
    ///
    /// Гаснет первой, и выбор не случайный: это единственные слои схемы, чьё
    /// отсутствие не меняет НИ ОДНОГО её ответа. Дорога остаётся дорогой,
    /// маршрут — маршрутом, камера — камерой; уходит только отделка. Чип
    /// «Жарко — экономлю экран» обязан быть правдой, а правда должна стоить
    /// водителю как можно меньше.
    var sketchTrim: Bool { self == .full }

    /// Во сколько раз реже пересчитывать слой карты при движении.
    var recomputeFactor: Double {
        switch self {
        case .full:    return 1
        case .reduced: return 2
        case .minimal: return 4
        }
    }

    /// Показывать ли пользователю, что мы себя урезали. Молчаливая деградация
    /// читается как поломка: человек, который понимает причину, открывает окно,
    /// а не пишет «приложение тормозит».
    var explains: Bool { self != .full }
}

@MainActor
@Observable
final class ThermalService {
    private(set) var mode: PerformanceMode = .init(thermalState: ProcessInfo.processInfo.thermalState)

    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        #if DEBUG
        // Перегрев на симуляторе не воспроизвести, а посмотреть глазами на всё,
        // что от него зависит (чип приборки, урезанный бюджет схемы), — надо.
        // Тот же аргумент, что у плашки карты (MapStatusBanner).
        if ProcessInfo.processInfo.arguments.contains("-forceOverheated") {
            mode = .reduced
            return
        }
        #endif
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            // Уведомление приходит на произвольном потоке.
            Task { @MainActor [weak self] in self?.update() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func update() {
        let fresh = PerformanceMode(thermalState: ProcessInfo.processInfo.thermalState)
        guard fresh != mode else { return }
        Log.app.notice("режим производительности: \(String(describing: fresh), privacy: .public)")
        mode = fresh
    }
}
