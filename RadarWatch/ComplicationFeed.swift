//
//  ComplicationFeed.swift
//  RadarWatch
//
//  Кормит компликацию «следующая камера» (9.3б): на каждом контексте с
//  телефона считает состояние циферблата, кладёт снимок в App Group и
//  тратит перезагрузку WidgetKit только когда решил WatchComplication —
//  начало/конец поездки, другая камера или ступень дистанции, не чаще
//  раза в две минуты. GPS-тик телефона сюда не доходит: часам шлют уже
//  квантованное (WatchBridgeService). Толчок с телефона (14.5) идёт сюда же
//  тем же путём: и контекст, и толчок с одним снимком — одна перезагрузка.
//

import Foundation
import WidgetKit
import os

@MainActor
final class ComplicationFeed {
    private let log = Logger(subsystem: "uz.radarmap.ios.watch", category: "complication")
    private let store = SharedDefaults.store
    private var ledger: WatchComplicationLedger
    /// Последний записанный снимок — пишем только на смене состояния.
    private var written: WatchComplicationState?

    init() {
        ledger = WatchComplicationLedger()
        written = nil
        guard SharedDefaults.hasAppGroup else {
            // Без группы расширение не увидит снимка — компликация так и
            // останется «нет поездки». Это вопрос подписи, не кода.
            log.error("App Group не выдан — компликация без данных")
            return
        }
        if let data = store?.data(forKey: WatchComplication.ledgerKey) {
            do {
                ledger = try JSONDecoder().decode(WatchComplicationLedger.self, from: data)
            } catch {
                log.error("учёт перезагрузок не прочитан: \(error.localizedDescription, privacy: .public)")
            }
        }
        written = ledger.lastState
    }

    /// - Parameters:
    ///   - cameraID: id камеры с телефона (14.5); nil от старой сборки —
    ///     камера узнаётся по адресу и значку.
    ///   - sentAt: когда телефон отправил состояние; снимок датируется им,
    ///     а не приёмом (`WatchComplication.snapshotDate`).
    func update(isTripActive: Bool, symbol: String?, title: String?, distanceMeters: Int?,
                cameraID: Int? = nil, sentAt: Date? = nil, now: Date = Date()) {
        let state = WatchComplication.state(isTripActive: isTripActive, symbol: symbol,
                                            title: title, distanceMeters: distanceMeters,
                                            cameraID: cameraID)
        let reason = WatchComplication.reloadReason(for: state, ledger: ledger, now: now)
        // Снимок — на каждой смене, даже без перезагрузки: система сама
        // перечитывает таймлайн (смена циферблата, пробуждение), и пусть
        // тогда увидит свежее. Освежение — со временем перезагрузки.
        if state != written || reason != nil {
            write(WatchComplicationSnapshot(state: state,
                                            updatedAt: WatchComplication.snapshotDate(sentAt: sentAt,
                                                                                      receivedAt: now)))
            written = state
        }
        guard let reason else { return }
        ledger = WatchComplication.recording(reason, state: state, ledger: ledger, now: now)
        save(ledger)
        WidgetCenter.shared.reloadTimelines(ofKind: WatchComplication.kind)
    }

    private func write(_ snapshot: WatchComplicationSnapshot) {
        do {
            store?.set(try JSONEncoder().encode(snapshot), forKey: WatchComplication.snapshotKey)
        } catch {
            log.error("снимок компликации не записан: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save(_ ledger: WatchComplicationLedger) {
        do {
            store?.set(try JSONEncoder().encode(ledger), forKey: WatchComplication.ledgerKey)
        } catch {
            log.error("учёт перезагрузок не записан: \(error.localizedDescription, privacy: .public)")
        }
    }
}
