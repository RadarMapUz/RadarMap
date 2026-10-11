//
//  TrafficService.swift
//  RadarMap
//
//  Пробки в обе стороны: телефон помогает их считать и показывает их.
//
//  Отправка. Во время поездки принятые фиксы режет TrafficProbes (концы
//  поездки и места у дома/работы не уходят никогда), готовые куски уходят
//  пачкой раз в `trafficUploadInterval` на POST /api/traffic. Без сети куски
//  копятся (не больше `trafficQueueCap`, старые выбрасываются — пробка
//  часовой давности серверу не нужна). Выключатель — «Помогать с пробками»
//  в настройках; рубильник — пульт (`features.traffic`).
//
//  Приём. Пока на пробки кто-то смотрит (экран телефона, машина или идёт
//  поездка), traffic/now.json перечитывается раз в `trafficRefreshInterval`
//  с ETag — неизменившийся файл стоит пустой 304. Разбор — вне главного
//  потока. Файл старше `trafficStaleSeconds` — данных нет: карта пробок не
//  рисует, маршрут поправки не получает.
//
//  Пробки — данные для показа и для времени в пути. На оповещения о камерах
//  они не влияют никак (ARCHITECTURE.md, правило 20).
//

import CoreLocation
import Foundation
import Observation
import os

@MainActor
@Observable
final class TrafficService {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    /// Свежие пробки или nil (нет данных, выключено, протухло).
    private(set) var snapshot: TrafficSnapshot?
    /// Растёт на каждом новом наборе — по нему карта перерисовывает слой.
    private(set) var revision = 0

    @ObservationIgnored private var probes = TrafficProbes()
    @ObservationIgnored private var queue: [TrafficProbes.Piece] = []
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var wanted = false

    private let api = APIClient()
    private let settings: AppSettings

    /// Дом, работа и сохранённые места — рядом с ними след не собирается.
    /// Ставит AppEnvironment (места живут там).
    @ObservationIgnored var privacyZones: () -> [CLLocationCoordinate2D] = { [] }
    /// Пульт (`features.traffic`) и сеть — замыканиями: и то и другое живёт
    /// в AppEnvironment и готово только после его инициализации.
    @ObservationIgnored var allowedByConfig: () -> Bool = { true }
    @ObservationIgnored var isOnline: () -> Bool = { true }

    init(settings: AppSettings) {
        self.settings = settings
    }

    private var contributes: Bool { settings.trafficContribution && allowedByConfig() }
    var isShown: Bool { settings.trafficShown && allowedByConfig() }

    // MARK: - Поездка (отправка)

    func tripStarted() {
        guard contributes else { return }
        probes.begin(zones: privacyZones())
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppConfig.trafficUploadInterval))
                guard !Task.isCancelled else { return }
                await self?.upload()
            }
        }
    }

    func tripEnded() {
        // Хвост (последние ≥ 400 м) выбрасывается внутри finish(): финиш не
        // уходит никогда. Готовое — последней пачкой.
        probes.finish()
        uploadTask?.cancel()
        uploadTask = nil
        Task { await upload() }
    }

    /// Принятый фикс поездки (из LocationService.onAcceptedFix).
    func note(_ coordinate: CLLocationCoordinate2D, speedKmh: Double) {
        guard probes.isActive else { return }
        guard contributes else {
            // Выключили на ходу — ничего собранного не отправляем.
            probes.finish()
            _ = probes.takeReady()
            queue = []
            return
        }
        probes.add(lat: coordinate.latitude, lon: coordinate.longitude, kmh: speedKmh, at: Date())
    }

    private func upload() async {
        queue += probes.takeReady()
        if queue.count > AppConfig.trafficQueueCap { queue.removeFirst(queue.count - AppConfig.trafficQueueCap) }
        guard contributes, isOnline(), !queue.isEmpty else { return }
        let batch = Array(queue.prefix(12))
        guard let body = try? JSONEncoder().encode(Envelope(pieces: batch)) else { return }
        if await api.postAccepted("api/traffic", body: body) {
            queue.removeFirst(min(batch.count, queue.count))
            Log.network.info("пробки: отправлено кусков \(batch.count, privacy: .public)")
        }
    }

    private struct Envelope: Encodable {
        let v = 1
        let pieces: [TrafficProbes.Piece]
    }

    // MARK: - Показ (приём)

    /// Кто-то смотрит на карту или едет — пробки нужны. Ставит AppEnvironment
    /// по экрану телефона, машине и поездке.
    func setWanted(_ wanted: Bool) {
        guard wanted != self.wanted else { return }
        self.wanted = wanted
        refreshTask?.cancel()
        refreshTask = nil
        guard wanted else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(AppConfig.trafficRefreshInterval))
            }
        }
    }

    func refresh() async {
        guard isShown else {
            if snapshot != nil { snapshot = nil; revision &+= 1 }
            return
        }
        if let current = snapshot, !current.isFresh(now: Date()) {
            snapshot = nil
            revision &+= 1
        }
        guard isOnline() else { return }
        do {
            guard let fresh = try await Self.fetch(api: api, etag: etag) else { return }   // 304
            etag = fresh.etag
            guard let decoded = fresh.snapshot, decoded.isFresh(now: Date()) else {
                if snapshot != nil { snapshot = nil; revision &+= 1 }
                return
            }
            snapshot = decoded
            revision &+= 1
        } catch {
            Log.network.notice("пробки не загрузились: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Загрузка и разбор вне главного потока: файл по городу — тысячи рёбер.
    @concurrent
    private static func fetch(api: APIClient, etag: String?) async throws
        -> (snapshot: TrafficSnapshot?, etag: String?)? {
        guard let answer = try await api.getRawIfChanged("traffic/now.json", etag: etag) else { return nil }
        return (TrafficSnapshot.decode(answer.data), answer.etag)
    }

    #if DEBUG
    /// Скриншот-хук `-demoTraffic`: пробки вдоль Амира Темура (север — юг),
    /// оба направления, все три уровня — посмотреть цвета и ширину без
    /// выложенного сервера.
    func seedDemo() {
        let line: [(Double, Double)] = [(41.3850, 69.2905), (41.3810, 69.2896), (41.3765, 69.2883),
                                        (41.3715, 69.2865), (41.3671, 69.2851), (41.3560, 69.2844),
                                        (41.3450, 69.2840), (41.3340, 69.2833), (41.3237, 69.2825),
                                        (41.3150, 69.2810)]
        var edges: [TrafficEdge] = []
        for (index, (a, b)) in zip(line, line.dropFirst()).enumerated() {
            let level = [3, 3, 2, 1, 1, 2, 3, 2, 1][index % 9]
            let p = CLLocationCoordinate2D(latitude: a.0, longitude: a.1)
            let q = CLLocationCoordinate2D(latitude: b.0, longitude: b.1)
            let kmh = [0, 50, 28, 9][level]
            edges.append(TrafficEdge(a: p, b: q, level: level, kmh: Double(kmh), modelKmh: 60))
            edges.append(TrafficEdge(a: q, b: p, level: max(1, level - 1), kmh: Double(kmh) + 10, modelKmh: 60))
        }
        snapshot = TrafficSnapshot(generated: Date(), edges: edges)
        revision &+= 1
        Log.network.info("пробки: демо, рёбер \(edges.count, privacy: .public), ревизия \(self.revision, privacy: .public)")
    }
    #endif

    // MARK: - Маршрут

    /// Сколько добавляют пробки к маршруту; nil — данных нет (не «ноль»: ноль
    /// значит «пробок нет», а это мы знаем только при свежем наборе).
    func delay(along route: [CLLocationCoordinate2D]) -> TimeInterval? {
        guard isShown, let snapshot, snapshot.isFresh(now: Date()) else { return nil }
        return snapshot.delay(along: route)
    }
}
