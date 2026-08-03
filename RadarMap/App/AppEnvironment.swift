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
    /// Единый экземпляр: телефонная сцена и CarPlay работают с одним окружением —
    /// CarPlay может подключиться раньше, чем поднимется SwiftUI-сцена телефона.
    static let shared = AppEnvironment()

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
    /// Мост на Apple Watch: HUD поездки + тук на запястье.
    let watchBridge = WatchBridgeService()
    let metrics = MetricsService()
    let feedback = FeedbackService()

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
        self.location.watchBridge = watchBridge

        // Автостарт/стоп поездки по движению (режим старта — в настройках).
        let location = self.location
        motion.onDrivingStart = { [weak location] in
            guard settings.tripStartMode.usesMotion, let location,
                  !location.isTripActive else { return }
            location.startTrip(auto: true)   // незнакомая машина → вопрос «вы за рулём?»
        }
        motion.onDrivingStop = { [weak location] in
            guard let location else { return }
            location.endPassengerSession()   // «я в такси» действует до конца езды
            guard location.isTripActive else { return }
            // auto: поездку закрыла автоматика, а не человек — значит её ещё можно
            // продолжить как заезд по пути (TripMerge).
            location.endTrip(auto: true)
        }
        // Ответ на «Вы за рулём?»: пассажир — гасим поездку без следа,
        // водитель — запоминаем магнитолу машины, чтобы не переспрашивать.
        notifications.onPassengerConfirmed = { [weak location] in location?.markPassenger() }
        notifications.onDriverConfirmed = { [weak location] in location?.confirmDriver() }

        // Недельный дайджест: после каждой поездки перепланируем пуш со свежими цифрами.
        trip.onTripFinished = { [weak trip, weak notifications] in
            guard let trip, let notifications,
                  let week = trip.weekSummary else { return }
            notifications.scheduleWeeklyDigest(
                distance: week.distance,
                cameras: week.cameras,
                rating: trip.rating,
                cleanMonth: trip.month30.over == 0
            )
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
