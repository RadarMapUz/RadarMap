//
//  TrafficService.swift
//  RadarMap
//
//  Пробки в обе стороны: телефон помогает их считать и показывает их.
//
//  Отправка. Во время поездки принятые фиксы режет TrafficProbes (концы
//  поездки и места у дома/работы не уходят никогда), готовые куски уходят
//  пачкой на POST /api/traffic — тем же тактом, что и приём (NetworkRhythm):
//  одно пробуждение радио вместо двух. Без сети куски
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
    /// Куски, ждущие отправки, с временем их конца (на сервер оно не идёт:
    /// только чтобы не отправить старое). Офлайн-поездка оставляла до 30
    /// кусков, и они уходили часы спустя как «сейчас» — ложные пробки в
    /// now.json и в чужих ETA (S21, 20.10).
    @ObservationIgnored private var queue: [(piece: TrafficProbes.Piece, releasedAt: Date, endedAt: Date, slow: Bool)] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Последний такт сети (отправка + приём).
    @ObservationIgnored private var lastTickAt = Date.distantPast
    /// Интервал такта — ставит AppEnvironment (экран, маршрут).
    @ObservationIgnored var intervalProvider: (() -> TimeInterval)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: intervalProvider,
                                               "TrafficService.intervalProvider") }
    }
    private var interval: TimeInterval { intervalProvider?() ?? AppConfig.trafficRefreshInterval }
    /// Отправки идут по одной: такт, «радио проснулось» и финиш поездки могли
    /// взять одну и ту же голову очереди — кусок ушёл бы дважды и сервер
    /// принял бы его за второго независимого водителя (ревью 19.10).
    @ObservationIgnored private var uploadChain: Task<Void, Never>?
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var wanted = false

    private let api = APIClient()
    /// Чтение now.json — с корня ленты пробок (DEBUG `-trafficBase`, иначе тот же сервер).
    private let feed = APIClient(base: AppConfig.trafficFeedBaseURL)
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

    private var contributes: Bool {
        Self.contributes(setting: settings.trafficContribution, config: allowedByConfig(),
                         simulatedFix: false, simulatorBuild: Self.isSimulatorBuild)
    }

    /// Отдаём ли куски пробок. Подменённая координата — никогда: тестовая
    /// поездка из симулятора (60 км/ч по прямой сквозь кварталы) уходила на
    /// боевой сервер и могла стать «свободным» или «пробкой» на чужом
    /// маршруте (G1, 20.10). Сборка для симулятора не отдаёт вовсе — даже
    /// если система не пометила координату.
    nonisolated static func contributes(setting: Bool, config: Bool,
                                        simulatedFix: Bool, simulatorBuild: Bool) -> Bool {
        setting && config && !simulatedFix && !simulatorBuild
    }

    nonisolated static var isSimulatorBuild: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    var isShown: Bool { settings.trafficShown && allowedByConfig() }

    // MARK: - Поездка (отправка)

    func tripStarted() {
        guard contributes else { return }
        probes.begin(zones: privacyZones())
    }

    func tripEnded() {
        // Хвост (последние ≥ 400 м) выбрасывается внутри finish(): финиш не
        // уходит никогда. Готовое — последней пачкой.
        probes.finish()
        Task { await upload() }
    }

    /// Принятый фикс поездки (из LocationService.onAcceptedFix).
    func note(_ coordinate: CLLocationCoordinate2D, speedKmh: Double, simulated: Bool = false) {
        guard probes.isActive else { return }
        guard contributes, !simulated else {
            // Выключили на ходу или координата подменена — ничего
            // собранного не отправляем.
            probes.finish()
            _ = probes.takeReady()
            queue = []
            return
        }
        probes.add(lat: coordinate.latitude, lon: coordinate.longitude, kmh: speedKmh, at: Date())
    }

    private func upload() async {
        let previous = uploadChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.uploadNow()
        }
        uploadChain = task
        await task.value
    }

    private func uploadNow() async {
        let now = Date()
        queue += probes.takeReadyStamped()
        queue.removeAll { !Self.isFresh(releasedAt: $0.releasedAt, endedAt: $0.endedAt, slow: $0.slow, now: now) }
        if queue.count > AppConfig.trafficQueueCap { queue.removeFirst(queue.count - AppConfig.trafficQueueCap) }
        guard contributes, isOnline(), !queue.isEmpty else { return }
        let batch = Array(queue.prefix(AppConfig.trafficBatchPieces))
        let body: Data
        do {
            body = try JSONEncoder().encode(Envelope(pieces: batch.map(\.piece)))
        } catch {
            Log.network.error("пробки: куски не закодированы — \(error.localizedDescription, privacy: .public)")
            return
        }
        if await api.postAccepted("api/traffic", body: body) {
            queue.removeFirst(min(batch.count, queue.count))
            Log.network.info("пробки: отправлено кусков \(batch.count, privacy: .public)")
        }
    }

    /// Кусок ещё можно отправить. Офлайн-очередь — время после ОТПУСКА; от
    /// конца — 10 мин, а куску пробки 30: в плотной пробке машина отъезжает
    /// 400 м от конца куска минут десять, и счёт от конца выбрасывал бы ровно
    /// самые тяжёлые пробки (ревью S21). Обычный кусок, отпущенный после
    /// долгой стоянки (магазин без автостопа), — старая езда, не «сейчас».
    nonisolated static func isFresh(releasedAt: Date, endedAt: Date, slow: Bool, now: Date) -> Bool {
        let endLimit = slow ? AppConfig.trafficPieceMaxEndAgeSeconds : AppConfig.trafficPieceMaxAgeSeconds
        return now.timeIntervalSince(releasedAt) <= AppConfig.trafficPieceMaxAgeSeconds
            && now.timeIntervalSince(endedAt) <= endLimit
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
                guard let self else { return }
                if Date().timeIntervalSince(self.lastTickAt) >= self.interval { await self.tick() }
                // Короткими шагами: интервал зависит от экрана и маршрута, а
                // такт мог уже пройти вместе с опросом отметок (radioIsAwake).
                await Task.pause(seconds: AppConfig.trafficLoopStepSeconds)
            }
        }
    }

    /// Такт сети: досылка кусков и свежие пробки — одним пробуждением радио.
    private func tick() async {
        lastTickAt = Date()
        await upload()
        await refresh()
    }

    /// Радио только что проснулось ради другого запроса (опрос отметок):
    /// если срок пробок почти подошёл — сходить сейчас, вместе с ним.
    func radioIsAwake() {
        guard wanted, NetworkRhythm.joinsAwakeRadio(sinceLast: Date().timeIntervalSince(lastTickAt),
                                                     interval: interval) else { return }
        // Срок — сразу, до запуска задачи: иначе цикл в этот промежуток сам
        // прошёл бы проверку и такт случился бы дважды.
        lastTickAt = Date()
        Task {
            await upload()
            await refresh()
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
            guard let fresh = try await Self.fetch(api: feed, etag: etag) else { return }   // 304
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
    /// Скриншот-хук `-driveDemoStops -stopScene jam` (29.D): своя пробка по
    /// линии демо-маршрута — демо Амира Темура лежит в сотне метров от неё.
    func seedDemo(edges: [TrafficEdge]) {
        snapshot = TrafficSnapshot(generated: Date(), edges: edges)
        revision &+= 1
    }

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

    // MARK: - «Впереди пробка» без маршрута

    @ObservationIgnored private var jamAnnouncer = JamAhead.Announcer()
    @ObservationIgnored private var jamCheckedAt: Date?

    /// Пробка впереди по ходу, о которой ещё не говорили (JamAhead); nil —
    /// сказать нечего. Смотрит не чаще `jamCheckIntervalSeconds`.
    func jamToAnnounce(position: CLLocationCoordinate2D, course: CLLocationDirection,
                       now: Date = Date()) -> JamAhead.Jam? {
        guard isShown, let snapshot, snapshot.isFresh(now: now) else { return nil }
        if let at = jamCheckedAt, now.timeIntervalSince(at) < AppConfig.jamCheckIntervalSeconds { return nil }
        jamCheckedAt = now
        guard let jam = JamAhead.detect(edges: snapshot.edges, position: position, course: course),
              jamAnnouncer.shouldAnnounce(jam, at: now) else { return nil }
        Log.network.notice("пробка впереди: через \(Int(jam.startsIn), privacy: .public) м, \(Int(jam.length), privacy: .public) м, +\(Int(jam.delay), privacy: .public) с")
        return jam
    }

    // MARK: - Маршрут

    /// Сколько добавляют пробки к маршруту; nil — данных нет (не «ноль»: ноль
    /// значит «пробок нет», а это мы знаем только при свежем наборе).
    func delay(along route: [CLLocationCoordinate2D]) -> TimeInterval? {
        guard isShown, let snapshot, snapshot.isFresh(now: Date()) else { return nil }
        return snapshot.delay(along: route)
    }
}
