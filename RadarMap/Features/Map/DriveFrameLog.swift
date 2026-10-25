//
//  DriveFrameLog.swift
//  RadarMap
//
//  DEBUG `-logDriveFrame`: раз в 2 с строка «КАДР» с целью и итогом камеры
//  поездки (DriveCamera) — стоим ли, до развилки, удерживаемые точки, масштаб
//  цели и сглаженный. Масштаб карты на снимке на глаз не измерить, а «вид
//  остановки отдаляет ниже z15» (29.F, 26.10) проверяется только числом.
//

#if DEBUG
import Foundation
import os

@MainActor
enum DriveFrameLog {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-logDriveFrame")
    private static var lastAt: [String: Date] = [:]
    private static let log = Logger(subsystem: "uz.radarmap.ios", category: "location")

    static func note(_ tag: String, stop: StopView.State, maneuver: Double?, keep: DriveCamera.Keep?,
                     also: Int, target: DriveCamera.Frame, frame: DriveCamera.Frame, bias: Double) {
        guard enabled else { return }
        let now = Date()
        if let last = lastAt[tag], now.timeIntervalSince(last) < 2 { return }
        lastAt[tag] = now
        let keepText = keep.map { String(format: "%.0f/%.0f%@", $0.forward, $0.right, $0.anyDirection ? " любая" : "") } ?? "-"
        log.notice("КАДР \(tag, privacy: .public) стоим=\(stop.standing, privacy: .public) развилка=\(maneuver.map { String(Int($0)) } ?? "-", privacy: .public) камера=\(keepText, privacy: .public) цель+\(also, privacy: .public) z_цель=\(String(format: "%.2f", target.zoom), privacy: .public) z=\(String(format: "%.2f", frame.zoom), privacy: .public) сдвиг=\(String(format: "%.1f", bias), privacy: .public)")
    }
}
#endif
