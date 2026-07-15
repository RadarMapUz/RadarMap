//
//  AppEnvironment.swift
//  RadarMap
//
//  Композиционный корень зависимостей. Создаётся один раз и раздаётся через SwiftUI Environment.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    let settings: AppSettings
    let cameras: CameraStore
    let notifications: NotificationService
    let alerts: AlertPlayer
    let trip: TripStats
    let location: LocationService
    let sync: RemoteSyncService
    let mobile: MobileCameraService
    let motion: MotionService
    let route = RouteService()
    let speedLimits: SpeedLimitService
    let liveActivity = LiveActivityService()
    let metrics = MetricsService()

    init() {
        let settings = AppSettings()
        let cameras = CameraStore()
        self.sync = RemoteSyncService(store: cameras)
        self.mobile = MobileCameraService(store: cameras)
        self.motion = MotionService(settings: settings)
        let notifications = NotificationService(settings: settings)
        let alerts = AlertPlayer(settings: settings)
        let trip = TripStats()

        self.settings = settings
        self.cameras = cameras
        self.notifications = notifications
        self.alerts = alerts
        self.trip = trip
        self.speedLimits = SpeedLimitService(settings: settings)
        self.location = LocationService(
            repository: cameras,
            notifier: notifications,
            settings: settings,
            alerts: alerts,
            trip: trip
        )
        self.location.liveActivity = liveActivity
        self.location.route = route
        self.location.speedLimits = speedLimits

        // Автостарт/стоп поездки по движению (если включено в настройках).
        let location = self.location
        motion.onDrivingStart = { [weak location] in
            guard settings.autoStartTrip, let location, !location.isTripActive else { return }
            location.startTrip()
        }
        motion.onDrivingStop = { [weak location] in
            guard let location, location.isTripActive else { return }
            location.endTrip()
        }

        // Голосовое сопровождение маршрута: перестроение, прибытие, манёвры.
        route.onRerouted = { [weak alerts] in
            guard settings.voiceEnabled else { return }
            alerts?.speak(String(localized: "Маршрут перестроен"))
        }
        route.onArrived = { [weak alerts] in
            guard settings.voiceEnabled else { return }
            alerts?.speak(String(localized: "Вы прибыли"))
        }
        route.onManeuver = { [weak alerts] text in
            guard settings.turnByTurnVoice else { return }
            alerts?.speak(text)
        }
        speedLimits.onOverspeed = { [weak alerts] in
            alerts?.speak(String(localized: "Превышение скорости"))
        }
    }

    var loadError: String? { cameras.loadError }
}
