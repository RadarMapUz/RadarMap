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
//  Та же ступень включается и при малом заряде без зарядки — автоэконом
//  (12.3, AutoEconomy): `mode` — итог для карты, `heatMode` — нагрев как есть
//  (на него смотрит опрос отметок водителей: батарея не повод узнавать о
//  треноге позже).
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

    /// Во сколько раз реже пересчитывать слой карты при движении.
    var recomputeFactor: Double {
        switch self {
        case .full:    return 1
        case .reduced: return 2
        case .minimal: return 4
        }
    }
}

@MainActor
@Observable
final class ThermalService {
    /// Ступень для карты: нагрев и автоэконом вместе (AutoEconomy.mode).
    private(set) var mode: PerformanceMode = .init(thermalState: ProcessInfo.processInfo.thermalState)
    /// Нагрев как есть — без батареи.
    private(set) var heatMode: PerformanceMode = .init(thermalState: ProcessInfo.processInfo.thermalState)
    /// Телефон тёплый (`.fair` и выше): карта ещё полная, но плитка главного
    /// экрана машины уже упрощается (Drive3D.TileLevel, 48).
    private(set) var isWarm = ProcessInfo.processInfo.thermalState != .nominal
    /// Мало заряда без зарядки — карта урезана ради батареи.
    private(set) var savingBattery = false
    /// Почему урезаны (nil — не урезаны): плашка карты и чип CarPlay.
    /// Молчаливая деградация читается как поломка: человек, который понимает
    /// причину, открывает окно или ищет провод, а не пишет «тормозит».
    var reason: AutoEconomy.Reason? { AutoEconomy.reason(thermal: heatMode, savingBattery: savingBattery) }

    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var batteryCheckedAt: Date?
    #if DEBUG
    /// Снимки состояния без настоящего заряда: заряд держится, пока жив процесс.
    @ObservationIgnored private var batteryPinned = false
    @ObservationIgnored private var warmPinned = false
    #endif

    init() {
        #if DEBUG
        // Перегрев на симуляторе не воспроизвести, а посмотреть глазами на всё,
        // что от него зависит (чип приборки, урезанный бюджет схемы), — надо.
        // Тот же аргумент, что у плашки карты (MapStatusBanner).
        if ProcessInfo.processInfo.arguments.contains("-forceOverheated") {
            mode = .reduced
            heatMode = .reduced
            isWarm = true
            return
        }
        // Тёплый телефон (плитка машины на ступени `lite`): `-forceWarm`.
        if ProcessInfo.processInfo.arguments.contains("-forceWarm") {
            warmPinned = true
            isWarm = true
        }
        // Мало заряда на симуляторе (там его нет вовсе): `-forceLowBattery`.
        if ProcessInfo.processInfo.arguments.contains("-forceLowBattery") {
            batteryPinned = true
            savingBattery = true
            mode = AutoEconomy.mode(thermal: heatMode, savingBattery: true)
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

    /// Снос без прыжка на актор: SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
    /// синтезирует isolated deinit КАЖДОМУ классу, а он в рантайме iOS 26
    /// ведёт в free() по указателю, который никто не выделял (подробный
    /// разбор — в MotionService). Этот класс был одним из двух, кому
    /// пометку забыли поставить, — и единственным, кто в deinit ещё и
    /// делает работу, то есть попадает в баг охотнее пустого.
    nonisolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func update() {
        let state = ProcessInfo.processInfo.thermalState
        var warm = state != .nominal
        #if DEBUG
        if warmPinned { warm = true }
        #endif
        if warm != isWarm { isWarm = warm }
        let fresh = PerformanceMode(thermalState: state)
        guard fresh != heatMode else { return }
        Log.app.notice("нагрев: \(String(describing: fresh), privacy: .public)")
        heatMode = fresh
        apply()
    }

    /// Перечитать заряд — не чаще `autoEconomyCheckSeconds`, поэтому звать
    /// можно с каждого фикса: это сравнение двух дат, а само чтение — раз в
    /// минуту и без постоянного мониторинга батареи (BatteryProbe).
    func refreshBattery(now: Date = Date()) {
        #if DEBUG
        if batteryPinned { return }
        #endif
        if let at = batteryCheckedAt, now.timeIntervalSince(at) < AppConfig.autoEconomyCheckSeconds { return }
        batteryCheckedAt = now
        let battery = BatteryProbe.snapshot()
        let saving = AutoEconomy.savesBattery(percent: battery.percent, isCharging: battery.isCharging,
                                              wasSaving: savingBattery)
        guard saving != savingBattery else { return }
        Log.app.notice("автоэконом: \(saving ? "вкл" : "выкл", privacy: .public), заряд \(battery.percent ?? -1, privacy: .public) %")
        savingBattery = saving
        apply()
    }

    /// Итоговая ступень пишется только на смене: её читают карта и CarPlay.
    private func apply() {
        let fresh = AutoEconomy.mode(thermal: heatMode, savingBattery: savingBattery)
        guard fresh != mode else { return }
        Log.app.notice("режим производительности: \(String(describing: fresh), privacy: .public)")
        mode = fresh
    }
}
