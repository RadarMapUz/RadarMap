//
//  CarLinkService.swift
//  RadarMap
//
//  Подключены ли мы к своей машине: CarPlay или выбранная магнитола по
//  Bluetooth (26.2). Решение — в чистом CarLink, здесь только факты.
//
//  Ограничения фона — честно, потому что от них зависит, когда начнётся поездка:
//  - CarPlay будит приложение сам: сцена машины подключается и в фоне, и
//    при выгруженном процессе — старт мгновенный.
//  - Bluetooth НЕ будит. `routeChangeNotification` приходит только живому
//    процессу; приостановленный в тихом фоне его пропускает. Поэтому маршрут
//    перечитывается на каждом пробуждении: значимое перемещение (≈ 500 м
//    пути), вход/выход геозоны камеры, открытие приложения, — не чаще
//    `carLinkWakeRefreshSeconds`. Сел в машину дома — поездка начнётся на
//    первом таком пробуждении, обычно в первые 0,5–1 км; первая камера
//    у дома в этом окне может прийти уведомлением тихого фона, а не голосом.
//  - Во время поездки процесс живёт (непрерывный GPS), и отключение
//    магнитолы приходит уведомлением сразу.
//

import AVFAudio
import Foundation
import Observation
import os

@MainActor
@Observable
final class CarLinkService {

    /// Снос без прыжка на актор — тот же обход бага рантайма, что у MotionService.
    nonisolated deinit {}

    private let settings: AppSettings

    /// Своя машина подключена (CarPlay или выбранная магнитола).
    private(set) var isLinked = false
    /// Выходы аудио-маршрута сейчас — для выбора устройства в настройках.
    private(set) var ports: [CarLink.Port] = []
    @ObservationIgnored private var isCarPlayConnected = false
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// Подключение изменилось: (сейчас, было). Вешает AppEnvironment.
    @ObservationIgnored var onChange: ((_ linked: Bool, _ wasLinked: Bool) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onChange,
                                               "CarLinkService.onChange") }
    }

    init(settings: AppSettings) {
        self.settings = settings
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            // Уведомление приходит на произвольном потоке.
            Task { @MainActor [weak self] in self?.refresh(reason: "аудио-маршрут сменился") }
        }
    }

    /// Сцена CarPlay подключилась/отключилась.
    func setCarPlay(_ connected: Bool) {
        isCarPlayConnected = connected
        let reason = connected ? "CarPlay подключён" : "CarPlay отключён"
        // Сразу, не дожидаясь чтения маршрута: CarPlay — уже доказательство.
        apply(ports: ports, reason: reason)
        refresh(reason: reason)
    }

    /// Пробуждение в тихом фоне — перечитать маршрут, если давно не читали.
    func refreshIfStale(reason: String, now: Date = Date()) {
        if let last = lastRefresh,
           now.timeIntervalSince(last) < AppConfig.carLinkWakeRefreshSeconds { return }
        refresh(reason: reason)
    }

    /// Перечитать маршрут (вне main: поход к mediaserverd, правило 21) и
    /// пересчитать подключение.
    func refresh(reason: String) {
        lastRefresh = Date()
        Task { [weak self] in
            let ports = await Self.readPorts()
            self?.apply(ports: ports, reason: reason)
        }
    }

    /// Выбор устройств в настройках изменился — пересчитать по известным портам.
    func chosenChanged() {
        apply(ports: ports, reason: "выбор устройства машины")
    }

    private func apply(ports: [CarLink.Port], reason: String) {
        if ports != self.ports { self.ports = ports }
        let linked = isCarPlayConnected || CarLink.isLinked(ports: ports, chosen: settings.carDevices)
        guard linked != isLinked else { return }
        let was = isLinked
        isLinked = linked
        Log.trips.notice("машина: \(linked ? "подключена" : "отключена", privacy: .public) (\(reason, privacy: .public))")
        onChange?(linked, was)
    }

    /// Выходы маршрута сейчас.
    @concurrent
    static func readPorts() async -> [CarLink.Port] {
        #if DEBUG
        // Снимок настроек без машины: магнитола и наушники «подключены».
        if ProcessInfo.processInfo.arguments.contains("-carLinkDemo") {
            return [CarLink.Port(uid: "demo-car", name: "BYD Song Plus", kind: .bluetooth),
                    CarLink.Port(uid: "demo-buds", name: "AirPods Pro", kind: .bluetooth)]
        }
        #endif
        return ports(of: AVAudioSession.sharedInstance().currentRoute)
    }

    nonisolated static func ports(of route: AVAudioSessionRouteDescription) -> [CarLink.Port] {
        route.outputs.map { output in
            let kind: CarLink.PortKind
            switch output.portType {
            case .carAudio: kind = .carPlay
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: kind = .bluetooth
            default: kind = .other
            }
            return CarLink.Port(uid: output.uid, name: output.portName, kind: kind)
        }
    }
}
