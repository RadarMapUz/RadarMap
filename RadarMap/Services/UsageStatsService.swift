//
//  UsageStatsService.swift
//  RadarMap
//
//  Копит суточный агрегат использования (`UsageStats`) и раз в сутки шлёт его
//  на наш сервер. Ни координат, ни маршрутов, ни времени событий — только
//  счётчики; подробности и мотивация в UsageStats.swift.
//
//  Выключается двумя независимыми способами: тумблером в настройках (решение
//  пользователя) и пультом (наше решение, если на сервере беда). Ни один из
//  них не должен зависеть от другого.
//

import CoreLocation
import Foundation
import Observation
import os
import UIKit

@MainActor
@Observable
final class UsageStatsService {
    private let settings: AppSettings
    @ObservationIgnored weak var config: RemoteConfigService?
    /// Уровень разрешения геолокации — главная цифра всей воронки: без «Всегда»
    /// не работают ни фоновые оповещения, ни автостарт поездки.
    @ObservationIgnored weak var location: LocationService?

    @ObservationIgnored private let api = APIClient(timeout: 15)
    @ObservationIgnored private let deviceID = Storage.anonymousID(.metricsDeviceID)
    @ObservationIgnored private var file: UsageStatsFile
    @ObservationIgnored private var isSending = false

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("usage_stats.json")
    }

    init(settings: AppSettings) {
        self.settings = settings
        file = JSONFile.load(UsageStatsFile.self, from: Self.url, log: Log.network)
            ?? UsageStatsFile(current: UsageStats(day: UsageStats.today()))
    }

    private var isEnabled: Bool {
        settings.usageStatsEnabled && (config?.areMetricsEnabled ?? true)
    }

    // MARK: - Накопление

    /// Все счётчики идут через одну точку: так «случайно записать координату»
    /// становится невозможно — записывать тут просто нечего, кроме чисел.
    func note(_ change: (inout UsageStats) -> Void) {
        guard isEnabled else { return }
        rollOverIfNeeded()
        change(&file.current)
        save()
    }

    func noteTrip(distanceMeters: Double) {
        note { stats in
            stats.trips += 1
            stats.kilometres = ((stats.kilometres + distanceMeters / 1000) * 10).rounded() / 10
        }
    }

    func noteAlert() { note { $0.alerts += 1 } }
    func notePass() { note { $0.passes += 1 } }
    func noteReport() { note { $0.reports += 1 } }
    func noteScreen(_ name: String) { note { $0.screens[name, default: 0] += 1 } }

    /// Сутки сменились — вчерашний день уезжает в очередь на отправку.
    private func rollOverIfNeeded() {
        let today = UsageStats.today()
        guard file.current.day != today else { return }
        if !file.current.isEmpty {
            file.pending.append(file.current)
            if file.pending.count > UsageStatsFile.pendingCap {
                file.pending.removeFirst(file.pending.count - UsageStatsFile.pendingCap)
            }
        }
        file.current = UsageStats(day: today)
    }

    private func save() {
        JSONFile.save(file, to: Self.url, log: Log.network)
    }

    // MARK: - Отправка

    /// Вызывается при старте: досылает накопленные дни. Текущий день не шлём —
    /// он ещё не закончился, и его цифры соврали бы про «сколько ездят за сутки».
    func flush() async {
        guard isEnabled, !isSending else { return }
        rollOverIfNeeded()
        save()
        guard !file.pending.isEmpty else { return }
        isSending = true
        defer { isSending = false }

        let context = snapshotContext()
        while let stats = file.pending.first {
            guard await send(stats, context: context) else { return }  // сервер молчит — не долбим
            file.pending.removeFirst()
            save()
        }
    }

    /// Состояние разрешений и версий на момент отправки. Считается один раз:
    /// это свойства устройства, а не события.
    private struct Context {
        let app: String
        let ios: String
        let model: String
        let locationAuth: String
        let onboarded: Bool
    }

    private func snapshotContext() -> Context {
        Context(
            app: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            ios: UIDevice.current.systemVersion,
            model: Self.hardwareModel,
            locationAuth: Self.name(for: location?.authorizationStatus),
            onboarded: Storage.bool(.hasCompletedOnboarding)
        )
    }

    private static func name(for status: CLAuthorizationStatus?) -> String {
        switch status {
        case .authorizedAlways:    return "always"
        case .authorizedWhenInUse: return "whenInUse"
        case .denied:              return "denied"
        case .restricted:          return "restricted"
        case .notDetermined, nil:  return "notDetermined"
        @unknown default:          return "unknown"
        }
    }

    private func send(_ stats: UsageStats, context: Context) async -> Bool {
        let payload: [String: Any] = [
            "device": deviceID,
            "day": stats.day,
            "app": context.app,
            "ios": context.ios,
            "model": context.model,
            "location_auth": context.locationAuth,
            "onboarded": context.onboarded,
            "trips": stats.trips,
            "km": stats.kilometres,
            "alerts": stats.alerts,
            "passes": stats.passes,
            "reports": stats.reports,
            "screens": stats.screens,
        ]
        return await api.postAccepted("api/stat", json: payload)
    }

    /// Модель железа («iPhone14,2»): нужна, чтобы понимать, на чём тормозит.
    /// UIDevice.model отдаёт просто «iPhone», это бесполезно.
    private static let hardwareModel: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()
}
