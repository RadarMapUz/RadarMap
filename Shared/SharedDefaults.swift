//
//  SharedDefaults.swift
//  RadarMap
//
//  Обмен данными между приложением и виджетом через App Group.
//

import Foundation

enum SharedDefaults {
    static let appGroup = "group.uz.radarmap.ios"

    static var store: UserDefaults? { UserDefaults(suiteName: appGroup) }

    enum Keys {
        static let dbCount = "widget.dbCount"
        static let dbVersion = "widget.dbVersion"
        static let mobileCount = "widget.mobileCount"
        static let tripCameras = "widget.tripCameras"
        static let tripMaxSpeed = "widget.tripMaxSpeed"
        static let tripDistance = "widget.tripDistance"
        static let weekDistance = "widget.weekDistance"
        static let weekTrips = "widget.weekTrips"
        static let weekRating = "widget.weekRating"
        static let weekFineRisk = "widget.weekFineRisk"
        static let updatedAt = "widget.updatedAt"
    }

    struct Snapshot {
        var dbCount = 0
        var dbVersion = 1
        var mobileCount = 0
        var tripCameras = 0
        var tripMaxSpeed = 0.0
        var tripDistance = 0.0
        /// Текущая календарная неделя — главное лицо виджета: статистика,
        /// видимая вообще без открытия приложения.
        var weekDistance = 0.0
        var weekTrips = 0
        /// −1 — рейтинга нет (на неделе не ездили): UserDefaults не отличает
        /// «нет значения» от нуля, а ноль здесь был бы враньём про худшую езду.
        var weekRating = -1
        var weekFineRisk = 0.0
        var updatedAt: Date?
    }

    static func write(_ snapshot: Snapshot) {
        guard let store else { return }
        store.set(snapshot.dbCount, forKey: Keys.dbCount)
        store.set(snapshot.dbVersion, forKey: Keys.dbVersion)
        store.set(snapshot.mobileCount, forKey: Keys.mobileCount)
        store.set(snapshot.tripCameras, forKey: Keys.tripCameras)
        store.set(snapshot.tripMaxSpeed, forKey: Keys.tripMaxSpeed)
        store.set(snapshot.tripDistance, forKey: Keys.tripDistance)
        store.set(snapshot.weekDistance, forKey: Keys.weekDistance)
        store.set(snapshot.weekTrips, forKey: Keys.weekTrips)
        store.set(snapshot.weekRating, forKey: Keys.weekRating)
        store.set(snapshot.weekFineRisk, forKey: Keys.weekFineRisk)
        store.set(Date(), forKey: Keys.updatedAt)
    }

    static func read() -> Snapshot {
        guard let store else { return Snapshot() }
        return Snapshot(
            dbCount: store.integer(forKey: Keys.dbCount),
            dbVersion: max(1, store.integer(forKey: Keys.dbVersion)),
            mobileCount: store.integer(forKey: Keys.mobileCount),
            tripCameras: store.integer(forKey: Keys.tripCameras),
            tripMaxSpeed: store.double(forKey: Keys.tripMaxSpeed),
            tripDistance: store.double(forKey: Keys.tripDistance),
            weekDistance: store.double(forKey: Keys.weekDistance),
            weekTrips: store.integer(forKey: Keys.weekTrips),
            // Ключа ещё нет (первый запуск после обновления) — integer даёт 0,
            // а это «настоящий ноль» рейтинга; отличаем отсутствием ключа.
            weekRating: store.object(forKey: Keys.weekRating) == nil
                ? -1 : store.integer(forKey: Keys.weekRating),
            weekFineRisk: store.double(forKey: Keys.weekFineRisk),
            updatedAt: store.object(forKey: Keys.updatedAt) as? Date
        )
    }
}
