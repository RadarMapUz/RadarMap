//
//  FamilyShareService.swift
//  RadarMap
//
//  «Близкие видят прибытие» (12б.6): постоянная семейная ссылка. Правила — в
//  FamilyShare; здесь хранение ссылки, отправка и пауза на поездку. Шлёт тем
//  же путём и теми же полями, что «Поделиться прибытием» (EtaShare): ключ
//  записи, адрес и четыре поля — ни точки, ни цели, ни устройства.
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
    /// Отправка «в пути», которая ещё не вернулась: следующую не начинаем.
    @ObservationIgnored private var inFlight: Task<Bool, Never>?
    /// Последняя отправка в очереди: все запросы уходят по одному и по
    /// порядку — «дома»/«не в пути» не обгонит «в пути», ушедшее раньше, и
    /// сервер не покажет поездку после приезда.
    @ObservationIgnored private var chain: Task<Bool, Never>?
    /// Растёт на каждом закрытии: ответ «в пути», вернувшийся после него, не
    /// поднимает ссылку снова (ARCHITECTURE, правило 12).
    @ObservationIgnored private var generation = 0

    // MARK: - Настройки

    func create(name: String, now: Date = Date()) {
        link = FamilyLink.make(name: name.trimmingCharacters(in: .whitespaces), now: now)
    }

    func rename(_ name: String) { link?.name = name }

    func setEnabled(_ enabled: Bool) {
        link?.enabled = enabled
        if !enabled { closeSoon(nearHome: false) }
    }

    /// Ссылку удалили: у близкого — «сейчас не в пути» навсегда. Ключ для
    /// закрытия снят до удаления (closeSoon): задача закрытия стартует позже,
    /// и раньше находила ссылку уже пустой — «не в пути» не уходило, и у
    /// близкого до двух часов висело «будет дома в 18:40» (ревью 14.1).
    func remove() {
        closeSoon(nearHome: false)
        link = nil
    }

    /// Отправили (лист «Поделиться» сообщил, что ушло).
    func markSent() { link?.needsResend = false }

    /// Раз в 30 дней — новый ключ и адрес (старую ссылку близкий больше не
    /// видит); ссылка до 14.12 здесь же получает ключ записи.
    func rotateIfNeeded(now: Date = Date()) {
        guard let link, link.needsRotation(now: now), !isLive else { return }
        self.link = link.rotated(now: now)
        Log.network.notice("семейная ссылка: сменена (30 дней), пишется ключом")
    }

    // MARK: - Поездка

    func tripStarted() {
        pausedThisTrip = false
        rotateIfNeeded()
    }

    /// Пауза в один тап — на эту поездку.
    func pause() {
        pausedThisTrip = true
        closeSoon(nearHome: false)
    }

    /// Фикс в поездке: направление и прибытие по призраку дороги.
    func update(isTripActive: Bool, ghost: (toHome: Bool, arrival: Date)?, now: Date = Date()) {
        guard allowedByConfig() else { return }
        switch FamilyShare.phase(link: link, pausedThisTrip: pausedThisTrip,
                                 isTripActive: isTripActive, ghost: ghost) {
        case .idle:
            if isLive || inFlight != nil { closeSoon(nearHome: false) }
        case .driving(let arrival):
            guard inFlight == nil, let write = link?.write,
                  EtaShare.shouldSend(lastArrival: sentArrival, lastRemaining: sentArrival == nil ? nil : 0,
                                      lastSentAt: sentAt, arrival: arrival, remaining: 0, now: now)
            else { return }
            let started = generation
            let request = enqueue(.driving, arrival: arrival, write: write)
            inFlight = request
            Task {
                let delivered = await request.value
                if inFlight == request { inFlight = nil }
                // Пока ответ шёл, поездку закрыли (приехали, пауза, удалили
                // ссылку): «в пути» уже не правда, и isLive не воскресает —
                // иначе капсула «Сейчас видят» и запрет смены токена висели бы
                // до следующей поездки (ревью 14.1).
                guard delivered, started == generation else { return }
                sentArrival = arrival
                sentAt = Date()
                if !isLive { isLive = true }
            }
        }
    }

    /// Конец поездки: дома — «дома в 18:42», иначе — «сейчас не в пути».
    func tripEnded(nearHome: Bool) {
        closeSoon(nearHome: nearHome)
    }

    /// Закрыть живую ссылку — и ту, чья первая отправка ещё в пути. Ключ
    /// снимается сейчас, синхронно: к старту задачи ссылку могли удалить.
    /// Закрывает один раз: отправка, оставшаяся в пути, ссылку уже не держит.
    private func closeSoon(nearHome: Bool) {
        guard isLive || inFlight != nil, let write = link?.write else { return }
        generation &+= 1
        isLive = false
        inFlight = nil
        sentArrival = nil
        sentAt = nil
        enqueue(FamilyShare.endStatus(nearHome: nearHome), arrival: Date(), write: write)
    }

    /// В очередь: после всего, что ушло раньше.
    @discardableResult
    private func enqueue(_ status: EtaShare.Status, arrival: Date, write: EtaShare.WriteKey) -> Task<Bool, Never> {
        let previous = chain
        let task = Task {
            _ = await previous?.value
            return await send(status, arrival: arrival, write: write)
        }
        chain = task
        return task
    }

    private func send(_ status: EtaShare.Status, arrival: Date, write: EtaShare.WriteKey) async -> Bool {
        guard allowedByConfig() else { return false }
        return await api.postAccepted("api/eta", json: EtaShare.payload(write: write, arrival: arrival,
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
