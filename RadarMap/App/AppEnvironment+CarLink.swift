//
//  AppEnvironment+CarLink.swift
//  RadarMap
//
//  Подключение к своей машине → старт и стоп поездки (этап 26.2) и
//  одноразовое предложение «Только в машине» тем, у кого был CarPlay.
//

import CoreLocation
import Foundation
import os

extension AppEnvironment {

    func wireCarLink() {
        location.carLinked = { [weak carLink] in carLink?.isLinked ?? false }
        location.onQuietWake = { [weak carLink] in
            carLink?.refreshIfStale(reason: "пробуждение тихого фона")
        }
        carLink.onChange = { [weak self] linked, was in
            self?.carLinkChanged(linked: linked, was: was)
        }
        #if DEBUG
        // Снимок настроек режима: «Только в машине» с выбранной магнитолой.
        if ProcessInfo.processInfo.arguments.contains("-carOnlyDemo") {
            settings.tripStartMode = .carOnly
            settings.carDevices = [CarAudioDevice(uid: "demo-car", name: "BYD Song Plus")]
        }
        #endif
        carLink.refresh(reason: "запуск")
    }

    private func carLinkChanged(linked: Bool, was: Bool) {
        if linked {
            carLinkStopTask?.cancel()
            carLinkStopTask = nil
        } else if settings.tripStartMode == .carOnly {
            // Вышли из машины — «я пассажир» этой езды кончился (в «Авто» и
            // «Умном» его снимает CoreMotion, здесь CoreMotion не следит).
            location.endPassengerSession()
        }
        let action = CarLink.onChange(.init(
            mode: settings.tripStartMode, linked: linked, wasLinked: was,
            tripActive: location.isTripActive, tripFromLink: location.tripFromCarLink,
            passenger: location.isPassengerSession, motionDriving: motion.isDriving))
        switch action {
        case .none:
            break
        case .adopt:
            location.tripFromCarLink = true
        case .start:
            // История ещё читается — подождать, как автостарт CoreMotion
            // (склейка с поездкой до заправки должна её видеть).
            if !trip.isLoaded, !trip.isLoadBlocked {
                pendingAutoStart = true
                return
            }
            Log.trips.notice("старт поездки: машина подключена")
            location.startTrip(byCarLink: true)
        case .scheduleStop:
            carLinkStopTask?.cancel()
            carLinkStopTask = Task { [weak self] in
                await Task.pause(seconds: AppConfig.carLinkStopGraceSeconds)
                guard !Task.isCancelled, let self else { return }
                self.carLinkStopTask = nil
                guard !self.carLink.isLinked, self.location.isTripActive,
                      self.location.tripFromCarLink else { return }
                Log.trips.notice("конец поездки: машина отключена \(Int(AppConfig.carLinkStopGraceSeconds), privacy: .public) с")
                // auto: закрыла автоматика — заправку по пути склеит TripMerge.
                self.location.endTrip(auto: true)
            }
        }
    }

    /// Выученные Дом/Работа — в тишину тихого фона (на диск только на смене).
    func noteLearnedQuietZones() {
        let zones = learnedPlaces.map(\.coordinate)
        let same = zones.count == location.learnedQuietZones.count
            && zip(zones, location.learnedQuietZones).allSatisfy {
                $0.latitude == $1.latitude && $0.longitude == $1.longitude
            }
        if !same { location.learnedQuietZones = zones }
    }

    // MARK: - Предложение «Только в машине»

    /// Показать ли одноразовое предложение (CarPlay уже подключался).
    var offersCarOnlyMode: Bool {
        #if DEBUG
        // Снимок предложения без CarPlay в истории.
        if ProcessInfo.processInfo.arguments.contains("-carOnlyOffer"),
           !Storage.bool(.carOnlyOfferAnswered) { return settings.tripStartMode != .carOnly }
        #endif
        return CarLink.shouldOffer(carPlaySeen: Storage.bool(.carPlaySeen),
                            mode: settings.tripStartMode,
                            answered: Storage.bool(.carOnlyOfferAnswered))
    }

    /// Ответ на предложение: любой ответ закрывает его навсегда.
    func answerCarOnlyOffer(accept: Bool) {
        Storage.set(true, for: .carOnlyOfferAnswered)
        if accept { setTripStartMode(.carOnly) }
        carOnlyOfferRevision &+= 1
    }

    /// Сменить режим старта: CoreMotion — только где он нужен, подключение
    /// — пересчитать сразу (вдруг уже сидим в машине).
    func setTripStartMode(_ mode: TripStartMode) {
        if settings.tripStartMode != mode { settings.tripStartMode = mode }
        motion.syncEnabled()
        carLink.refresh(reason: "режим старта: \(mode.rawValue)")
        // Уже в машине, поездки нет — «Только в машине» начинает сразу.
        if mode == .carOnly, carLink.isLinked, !location.isTripActive {
            location.startTrip(byCarLink: true)
        }
    }
}
