//
//  LocationService+QuietAlert.swift
//  RadarMap
//
//  Тихий фон (поездки нет, экран закрыт): вход в геозону камеры → решение
//  QuietAlertGate → уведомление или тишина (этап 26.1). В поездке и при
//  открытом экране сюда не попадаем — там говорит движок оповещений.
//

import CoreLocation
import Foundation
import os
import UIKit

extension LocationService {

    /// Сырой фикс тихого фона — в буфер доказательств (до фильтра: Wi-Fi-фикс
    /// фильтр отбросит, а для ворот он — свидетельство «стоим на месте»).
    func noteQuietFix(_ fix: LocationFilter.Fix) {
        guard !isTripActive, !isForeground else {
            if !quietFixes.isEmpty { quietFixes.removeAll() }
            return
        }
        quietFixes.append(fix)
        if quietFixes.count > AppConfig.quietAlertFixBuffer {
            quietFixes.removeFirst(quietFixes.count - AppConfig.quietAlertFixBuffer)
        }
        onQuietWake?()
    }

    /// Дом и Работа: заданные вручную и выученные.
    var quietZones: [CLLocationCoordinate2D] {
        settings.savedPlaceCoordinates + learnedQuietZones
    }

    /// Вход в геозону камеры в тихом фоне. Пробуждение живёт секунды —
    /// за них просим один точный фикс и читаем историю CoreMotion, а
    /// решение пересматриваем, пока не появится доказательство или не
    /// выйдет окно (`quietAlertEvidenceSeconds`).
    func evaluateQuietEntry(_ camera: Camera) {
        guard quietPending.insert(camera.id).inserted else { return }
        // Фоновое время на окно доказательств: без него система вправе
        // усыпить процесс сразу после колбэка геозоны.
        let task = BackgroundTime.begin("тихий фон: камера")
        // Точный фикс со скоростью: SLC и вход в геозону дают Wi-Fi/вышки без
        // доплера. Режим тихого фона точность не держит — ставим здесь,
        // applyLocationMode при смене режима выставит свою.
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestLocation()
        Task { [weak self] in
            defer { BackgroundTime.end(task) }
            guard let self else { return }
            let motion = await self.motion?.recentMotion() ?? .unknown
            let deadline = Date().addingTimeInterval(AppConfig.quietAlertEvidenceSeconds)
            var decision = QuietAlertGate.Decision.silence(.noProof)
            while true {
                // Поездка началась или открыли экран — говорит движок.
                guard !self.isTripActive, !self.isForeground else {
                    self.quietPending.remove(camera.id)
                    return
                }
                decision = QuietAlertGate.decide(self.quietSituation(for: camera, motion: motion))
                if case .notify = decision { break }
                if case .silence(let reason) = decision, reason.isFinal { break }
                if Date() >= deadline { break }
                await Task.pause(seconds: AppConfig.quietAlertEvidenceStepSeconds)
            }
            self.quietPending.remove(camera.id)
            self.finishQuietEntry(camera, decision: decision)
        }
    }

    func quietSituation(for camera: Camera, motion: QuietAlertGate.Motion) -> QuietAlertGate.Situation {
        let now = Date()
        return QuietAlertGate.Situation(
            now: now, cameraLat: camera.lat, cameraLon: camera.lon,
            radius: settings.alertRadius,
            fixes: quietFixes, motion: motion, quietZones: quietZones,
            lastNotifiedAt: Self.quietAlertLog(now: now)[camera.id],
            requiresCarLink: settings.tripStartMode == .carOnly,
            carLinked: carLinked?() ?? false)
    }

    private func finishQuietEntry(_ camera: Camera, decision: QuietAlertGate.Decision) {
        switch decision {
        case .notify:
            // Камеру могли проехать (выход) или отметку погасить, пока ждали.
            guard !alertedCameraIDs.contains(camera.id) else { return }
            Log.alerts.notice("тихий фон: камера \(camera.id, privacy: .public) — уведомление (езда доказана)")
            alertedCameraIDs.insert(camera.id)
            var log = Self.quietAlertLog(now: Date())
            log[camera.id] = Date()
            Storage.encode(log, for: .quietAlertLog)
            notifier.notifyApproaching(camera)
        case .silence(let reason):
            Log.alerts.notice("тихий фон: камера \(camera.id, privacy: .public) — молчим (\(reason.rawValue, privacy: .public))")
        }
    }

    /// Журнал уведомлений тихого фона без устаревших записей.
    static func quietAlertLog(now: Date) -> [Int: Date] {
        QuietAlertGate.pruned(Storage.decoded([Int: Date].self, for: .quietAlertLog) ?? [:], now: now)
    }
}

/// Фоновое время приложения (`beginBackgroundTask`) — короткая обёртка, чтобы
/// окончание не забывалось и срок не убивал процесс.
@MainActor
enum BackgroundTime {
    static func begin(_ name: String) -> UIBackgroundTaskIdentifier {
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: name) {
            // Срок вышел — отдаём время, иначе система убьёт процесс.
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
        return id
    }

    static func end(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}
