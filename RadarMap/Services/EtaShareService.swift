//
//  EtaShareService.swift
//  RadarMap
//
//  «Поделиться прибытием»: подготовить ссылку, отправлять время прибытия,
//  пока идёт маршрут, закрыть ссылку в конце (EtaShare — что и как).
//
//  Порядок такой: ссылка готовится до системного «Поделиться», а отправка
//  начинается, только если водитель действительно отправил её (completion
//  листа «Поделиться»). Передумал — на сервер не ушло ничего.
//

import CoreLocation
import Foundation
import Observation
import os

@MainActor
@Observable
final class EtaShareService {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    /// Ссылка живая — обновления идут.
    private(set) var isSharing = false

    @ObservationIgnored weak var route: RouteService?
    /// Пульт: рубильник на случай поломки страницы.
    @ObservationIgnored var allowedByConfig: () -> Bool = { true }
    /// Ключ записи этой ссылки: живёт только в памяти, в ссылке — его хэш.
    @ObservationIgnored private var write: EtaShare.WriteKey?
    @ObservationIgnored private var loop: Task<Void, Never>?
    private let api = APIClient()

    var isAvailable: Bool { allowedByConfig() && (route?.isActive ?? false) }

    /// Сервер показывает страницы ссылок: nil — ещё не спрашивали.
    @ObservationIgnored private(set) var serverSupport: Bool?
    @ObservationIgnored private var lastProbe: Date?

    /// Спросить сервер, если пора, — перед тем как отдать ссылку. Ссылку,
    /// которая откроется ошибкой, водитель не должен отправлять никому.
    func ensureServerSupport(now: Date = Date()) async -> Bool {
        guard EtaShare.probeDue(support: serverSupport, lastProbe: lastProbe, now: now) else {
            return serverSupport == true
        }
        lastProbe = now
        guard let answer = await api.probe("api/eta/" + EtaShare.probeToken),
              let support = EtaShare.linkSupport(status: answer.status, contentType: answer.contentType) else {
            // Не знаем — следующее нажатие спросит снова, без паузы.
            lastProbe = nil
            return serverSupport == true
        }
        if support != serverSupport, !support {
            Log.network.error("прибытие: сервер не показывает ссылки (HTTP \(answer.status, privacy: .public)) — отправляем время без ссылки")
        }
        serverSupport = support
        return support
    }

    /// Текст без ссылки — когда сервер ссылки не показывает: время прибытия
    /// всё равно полезно, а мёртвая ссылка — нет.
    func messageWithoutLink() -> String? {
        guard isAvailable, let route else { return nil }
        let clock = route.arrivalDate.formatted(date: .omitted, time: .shortened)
        return String(format: String(localized: "Буду примерно в %1$@ (через %2$@)."),
                      clock, Formatting.duration(route.remainingTime))
    }

    /// Ссылка и текст для листа «Поделиться». Отправки ещё нет.
    func prepare() -> (url: URL, message: String)? {
        guard isAvailable, let route else { return nil }
        let write = self.write ?? .secret(EtaShare.makeToken())
        self.write = write
        let url = EtaShare.link(base: AppConfig.syncBaseURL, token: write.address)
        let clock = route.arrivalDate.formatted(date: .omitted, time: .shortened)
        let message = String(format: String(localized: "Буду примерно в %1$@ (через %2$@). Следить: %3$@"),
                             clock, Formatting.duration(route.remainingTime), url.absoluteString)
        return (url, message)
    }

    /// Водитель отправил ссылку — начинаем обновлять.
    func confirmShared() {
        guard write != nil, !isSharing else { return }
        isSharing = true
        sentArrival = nil
        sentRemaining = nil
        sentAt = nil
        Log.network.notice("прибытие: делимся")
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let route = self.route else { return }
                if route.isActive {
                    let arrival = route.arrivalDate, remaining = route.remainingDistance
                    if EtaShare.shouldSend(lastArrival: self.sentArrival, lastRemaining: self.sentRemaining,
                                           lastSentAt: self.sentAt, arrival: arrival,
                                           remaining: remaining, now: Date()) {
                        // Запоминаем только доставленное — иначе после сбоя
                        // ссылка молчала бы до 10 минут; и не после «Перестать»
                        // (finish уже обнулил, отмена не прерывает отправку).
                        let delivered = await self.send(.driving, arrival: arrival, remaining: remaining)
                        if delivered, !Task.isCancelled {
                            self.sentArrival = arrival
                            self.sentRemaining = remaining
                            self.sentAt = Date()
                        }
                    }
                } else {
                    let arrived = route.lastArrival.map {
                        Date().timeIntervalSince($0.at) < AppConfig.etaShareArrivalFreshSeconds
                    } ?? false
                    await self.finish(arrived ? .arrived : .ended)
                    return
                }
                await Task.pause(seconds: AppConfig.etaShareIntervalSeconds)
            }
        }
    }

    /// Передумал в листе «Поделиться» — ссылки не было.
    func cancelPrepared() {
        guard !isSharing else { return }
        write = nil
    }

    /// «Перестать делиться» — знакомый увидит «больше не отслеживается».
    func stop() {
        guard isSharing else { return }
        Task { await finish(.ended) }
    }

    /// Что ушло в последний раз — повтор тех же цифр не шлём (shouldSend).
    @ObservationIgnored private var sentArrival: Date?
    @ObservationIgnored private var sentRemaining: Double?
    @ObservationIgnored private var sentAt: Date?

    private func finish(_ status: EtaShare.Status) async {
        loop?.cancel()
        loop = nil
        sentArrival = nil
        sentRemaining = nil
        sentAt = nil
        await send(status, arrival: Date(), remaining: 0)
        isSharing = false
        write = nil
        Log.network.notice("прибытие: ссылка закрыта (\(status.rawValue, privacy: .public))")
    }

    @discardableResult
    private func send(_ status: EtaShare.Status, arrival: Date, remaining: CLLocationDistance) async -> Bool {
        guard let write, allowedByConfig() else { return false }
        return await api.postAccepted("api/eta", json: EtaShare.payload(write: write, arrival: arrival,
                                                                       remainingMeters: remaining, status: status))
    }
}
