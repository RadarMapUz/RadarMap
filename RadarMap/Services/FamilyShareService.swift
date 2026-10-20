//
//  FamilyShareService.swift
//  RadarMap
//
//  «Близкие видят прибытие» (12б.6): постоянная семейная ссылка. Правила — в
//  FamilyShare; здесь хранение ссылки, отправка и пауза на поездку. Шлёт тем
//  же путём и теми же четырьмя полями, что «Поделиться прибытием»
//  (EtaShare): ни точки, ни цели, ни устройства.
//

import Foundation
import os

@MainActor
@Observable
final class FamilyShareService {
    nonisolated deinit {}

    private(set) var link: FamilyLink? = FamilyShareService.load() {
        didSet { save() }
    }
    /// Близкий видит поездку прямо сейчас — для «Сейчас видят: Мама».
    private(set) var isLive = false
    /// Пауза на эту поездку (один тап); снимается стартом следующей.
    private(set) var pausedThisTrip = false

    /// Пульт гасит общие ссылки («Поделиться прибытием») — и семейную.
    @ObservationIgnored var allowedByConfig: () -> Bool = { true }
    @ObservationIgnored private let api = APIClient()
    @ObservationIgnored private var sentArrival: Date?
    @ObservationIgnored private var sentAt: Date?
    @ObservationIgnored private var sending = false

    // MARK: - Настройки

    func create(name: String, now: Date = Date()) {
        link = FamilyLink.make(name: name.trimmingCharacters(in: .whitespaces), now: now)
    }

    func rename(_ name: String) { link?.name = name }

    func setEnabled(_ enabled: Bool) {
        link?.enabled = enabled
        if !enabled { Task { await close(nearHome: false) } }
    }

    /// Ссылку удалили: у близкого — «сейчас не в пути» навсегда.
    func remove() {
        Task { await close(nearHome: false) }
        link = nil
    }

    /// Отправили (лист «Поделиться» сообщил, что ушло).
    func markSent() { link?.needsResend = false }

    /// Раз в 30 дней — новый токен (старую ссылку близкий больше не видит).
    func rotateIfNeeded(now: Date = Date()) {
        guard let link, link.needsRotation(now: now), !isLive else { return }
        self.link = link.rotated(now: now)
        Log.network.notice("семейная ссылка: токен сменён (30 дней)")
    }

    // MARK: - Поездка

    func tripStarted() {
        pausedThisTrip = false
        rotateIfNeeded()
    }

    /// Пауза в один тап — на эту поездку.
    func pause() {
        pausedThisTrip = true
        Task { await close(nearHome: false) }
    }

    /// Фикс в поездке: направление и прибытие по призраку дороги.
    func update(isTripActive: Bool, ghost: (toHome: Bool, arrival: Date)?, now: Date = Date()) {
        guard allowedByConfig() else { return }
        switch FamilyShare.phase(link: link, pausedThisTrip: pausedThisTrip,
                                 isTripActive: isTripActive, ghost: ghost) {
        case .idle:
            if isLive { Task { await close(nearHome: false) } }
        case .driving(let arrival):
            guard !sending, EtaShare.shouldSend(lastArrival: sentArrival, lastRemaining: sentArrival == nil ? nil : 0,
                                                lastSentAt: sentAt, arrival: arrival, remaining: 0, now: now)
            else { return }
            sending = true
            Task {
                let delivered = await send(.driving, arrival: arrival)
                sending = false
                if delivered {
                    sentArrival = arrival
                    sentAt = Date()
                    if !isLive { isLive = true }
                }
            }
        }
    }

    /// Конец поездки: дома — «дома в 18:42», иначе — «сейчас не в пути».
    func tripEnded(nearHome: Bool) {
        guard isLive else { return }
        Task { await close(nearHome: nearHome) }
    }

    private func close(nearHome: Bool) async {
        guard isLive else { return }
        isLive = false
        sentArrival = nil
        sentAt = nil
        await send(FamilyShare.endStatus(nearHome: nearHome), arrival: Date())
    }

    @discardableResult
    private func send(_ status: EtaShare.Status, arrival: Date) async -> Bool {
        guard let link, allowedByConfig() else { return false }
        return await api.postAccepted("api/eta", json: EtaShare.payload(token: link.token, arrival: arrival,
                                                                       remainingMeters: 0, status: status))
    }

    // MARK: - Хранение

    private func save() {
        guard let link else { Storage.remove(.familyLink); return }
        do {
            Storage.set(try JSONEncoder().encode(link), for: .familyLink)
        } catch {
            Log.app.error("семейная ссылка не записалась: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load() -> FamilyLink? {
        guard let data = Storage.data(.familyLink) else { return nil }
        do {
            return try JSONDecoder().decode(FamilyLink.self, from: data)
        } catch {
            Log.app.error("семейная ссылка не прочиталась: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
