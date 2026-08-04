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
        static let updatedAt = "widget.updatedAt"
    }

    struct Snapshot {
        var dbCount = 0
        var dbVersion = 1
        var mobileCount = 0
        var tripCameras = 0
        var tripMaxSpeed = 0.0
        var tripDistance = 0.0
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
            updatedAt: store.object(forKey: Keys.updatedAt) as? Date
        )
    }
}
