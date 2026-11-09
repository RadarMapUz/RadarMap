//
//  TrafficService.swift
//  RadarMap
//
//  Пробки в обе стороны: телефон помогает их считать и показывает их.
//
//  Отправка. Во время поездки принятые фиксы режет TrafficProbes (концы
//  поездки и места у дома/работы не уходят никогда), готовые куски уходят
//  пачкой на POST /api/traffic — тем же тактом, что и приём (SyncPlan):
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
    /// Живой набор и «обычно в это время» (33G, профиль), сшитые в линии
    /// улиц для карты (TrafficLines, 33H): вне главного потока, раз на новый
    /// now.json или новый набор «обычно» — не на тике.
    private(set) var lines: [TrafficLines.Line] = []
    /// Растёт на каждом новом наборе линий — по нему карта пишет источник.
    /// Отдельно от `revision`: «обычно» меняется раз в 5 мин и не должно
    /// заставлять маршрут пересчитывать пробки на своей линии.
    private(set) var linesRevision = 0
    /// Балл пробок города 0–10 (TrafficCityScore) — с каждым набором линий.
    private(set) var cityScore: TrafficCityScore.Score?
    /// Рёбра «обычно в это время» от TrafficProfileService (`setUsual`).
    @ObservationIgnored private var usual: [TrafficProfile.UsualEdge] = []
    @ObservationIgnored private var linesGeneration = 0

    @ObservationIgnored private var probes = TrafficProbes()
    /// Куски, ждущие отправки, с временем их конца (на сервер оно не идёт:
    /// только чтобы не отправить старое). Офлайн-поездка оставляла до 30
    /// кусков, и они уходили часы спустя как «сейчас» — ложные пробки в
    /// now.json и в чужих ETA (S21, 20.10).
    @ObservationIgnored private var queue: [(piece: TrafficProbes.Piece, releasedAt: Date, endedAt: Date, slow: Bool)] = []
    /// Новый живой набор (или его снятие) — маршрут, чьи варианты ещё
    /// выбирают, пересчитывает их время и, до касания, ярлыки (решение 28.10).
    /// Ставит AppEnvironment.
    @ObservationIgnored var onSnapshotChanged: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onSnapshotChanged,
                                               "TrafficService.onSnapshotChanged") }
    }
    /// Отправки идут по одной: такт, «радио проснулось» и финиш поездки могли
    /// взять одну и ту же голову очереди — кусок ушёл бы дважды и сервер
    /// принял бы его за второго независимого водителя (ревью 19.10).
    @ObservationIgnored private var uploadChain: Task<Void, Never>?
    @ObservationIgnored private var etag: String?

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
    /// Такт пробок нужен: их показывают или водитель помогает их считать.
    /// Иначе планировщик в сеть за ними не ходит (SyncPlan.disabled).
    var isSyncWanted: Bool { isShown || contributes }

    /// Пробки выключены (настройка или пульт) — снять показанное, без сети.
    func clearIfHidden() {
        #if DEBUG
        if demoPinned { return }
        #endif
        guard !isShown, snapshot != nil || !lines.isEmpty else { return }
        apply(nil)
    }

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

    /// Такт планировщика сети (NetScheduler, 36B): досылка кусков и свежие
    /// пробки — одним пробуждением радио, вместе с отметками водителей.
    /// Когда — решает SyncPlan (150 с при экране или маршруте, иначе 300).
    /// true — получилось (или делать нечего), false — сбой: пауза службы.
    func syncTick() async -> Bool {
        await upload()
        return await refresh()
    }

    @discardableResult
    func refresh() async -> Bool {
        #if DEBUG
        // Показ -trafficDemo: набор из фикстуры не заменяется сервером и не
        // «протухает» — снимки не зависят ни от сети, ни от часов.
        if demoPinned { return true }
        #endif
        guard isShown else {
            if snapshot != nil || !lines.isEmpty { apply(nil) }
            return true
        }
        if let current = snapshot, !current.isFresh(now: Date()) {
            apply(nil)
        }
        guard isOnline() else { return false }
        do {
            guard let fresh = try await Self.fetch(api: feed, etag: etag) else { return true }   // 304
            etag = fresh.etag
            guard let decoded = fresh.snapshot, decoded.isFresh(now: Date()) else {
                if snapshot != nil { apply(nil) }
                return true
            }
            apply(decoded)
            return true
        } catch {
            Log.network.notice("пробки не загрузились: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Набор протух, а такта пробок нет (без связи окно не открывается):
    /// снять без сети. Иначе цвета десятиминутной давности лежали бы на карте
    /// часами, а время и «впереди пробка» уже считали бы их отсутствующими.
    func dropStale(now: Date = Date()) {
        #if DEBUG
        if demoPinned { return }
        #endif
        guard let current = snapshot, !current.isFresh(now: now) else { return }
        apply(nil)
    }

    private func apply(_ snapshot: TrafficSnapshot?) {
        self.snapshot = snapshot
        revision &+= 1
        rebuildLines()
        onSnapshotChanged?()
    }

    /// Новый набор «обычно в это время» (TrafficProfileService, раз в 5 мин).
    func setUsual(_ edges: [TrafficProfile.UsualEdge]) {
        #if DEBUG
        if demoPinned { return }
        #endif
        guard edges != usual else { return }
        usual = edges
        rebuildLines()
    }

    /// Линии карты из живых рёбер и «обычно» — вне главного потока. Живое
    /// идёт первым: то же ребро в «обычно» сшивка отбрасывает как повтор.
    /// Устаревший результат (пришёл набор новее) не пишется.
    private func rebuildLines() {
        linesGeneration &+= 1
        let generation = linesGeneration
        let live = isShown ? snapshot?.edges ?? [] : []
        let usual = isShown ? self.usual : []
        guard !live.isEmpty || !usual.isEmpty else {
            if !lines.isEmpty { lines = []; linesRevision &+= 1 }
            cityScore = nil
            return
        }
        Task {
            let built = await Self.build(live: live, usual: usual)
            guard generation == linesGeneration else { return }
            lines = built.lines
            cityScore = built.score
            linesRevision &+= 1
        }
    }

    @concurrent
    private static func build(live: [TrafficEdge], usual: [TrafficProfile.UsualEdge]) async
        -> (lines: [TrafficLines.Line], score: TrafficCityScore.Score?) {
        let lines = TrafficLines.lines(from: live + TrafficLines.edges(usual: usual))
        return (lines, TrafficCityScore.score(lines))
    }

    /// Загрузка и разбор вне главного потока: файл по городу — тысячи рёбер.
    @concurrent
    private static func fetch(api: APIClient, etag: String?) async throws
        -> (snapshot: TrafficSnapshot?, etag: String?)? {
        let answer: (data: Data, etag: String?)?
        do {
            answer = try await api.getRawIfChanged("traffic/now2.json", etag: etag)
        } catch APIClient.Failure.badStatus(404) {
            // На сервере ещё (или снова) нет now2.json — старый файл.
            answer = try await api.getRawIfChanged("traffic/now.json", etag: etag)
        }
        guard let answer else { return nil }
        return (TrafficSnapshot.decode(answer.data), answer.etag)
    }

    #if DEBUG
    @ObservationIgnored private var demoPinned = false

    /// Показ `-trafficDemo` (33H): синтетический вечерний Ташкент из фикстуры
    /// (TrafficDemo) — живые рёбра со свежей отметкой времени и «обычно».
    /// Сервер и профиль показ не перебивают.
    func seedFixture(live: [TrafficEdge], usual: [TrafficProfile.UsualEdge]) {
        self.usual = usual
        demoPinned = true
        apply(TrafficSnapshot(generated: Date(), edges: live))
        Log.network.info("пробки: показ из фикстуры, живых \(live.count, privacy: .public), обычно \(usual.count, privacy: .public)")
    }

    /// Скриншот-хук `-driveDemoStops -stopScene jam` (29.D): своя пробка по
    /// линии демо-маршрута — демо Амира Темура лежит в сотне метров от неё.
    func seedDemo(edges: [TrafficEdge]) {
        apply(TrafficSnapshot(generated: Date(), edges: edges))
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
        apply(TrafficSnapshot(generated: Date(), edges: edges))
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
