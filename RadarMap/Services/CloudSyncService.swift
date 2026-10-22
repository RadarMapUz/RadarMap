//
//  CloudSyncService.swift
//  RadarMap
//
//  «Хранить поездки: только на iPhone / в iCloud» (27.F) — выключатель,
//  строка состояния и КОГДА синхронизировать. Сам проход — CloudSyncEngine,
//  данные — CloudSources, сеть — CloudKitTransport.
//
//  Батарея и поездка.
//  * В поездке — ни одного запроса: радио занято тем, что предупреждает о
//    камерах, а история подождёт. Началась поездка посреди прохода — он
//    останавливается между порциями.
//  * После поездки — через `cloudAfterTripDelay`: остановка у магазина часто
//    продолжается той же поездкой.
//  * Первая выгрузка истории — месяцами, с паузой, в обычных проходах; в
//    режиме энергосбережения и на горячем телефоне — не идёт.
//  * Ничего на тике GPS и на пути предупреждения: служба знает только
//    «поездка началась/кончилась», «экран открыт/закрыт», «что-то правили».
//
//  Без iCloud (не вошли, выключен для приложения, сборка без контейнера) —
//  честная строка состояния, а на телефоне всё как раньше.
//

import CloudKit
import Foundation
import Observation
import UIKit
import os

/// Где хранить свои поездки.
enum CloudSyncMode: String {
    case local
    case iCloud = "icloud"
}

/// Состояние для строки в настройках.
enum CloudStatus: Equatable {
    case off
    case checking
    case noAccount
    case restricted
    case temporarilyUnavailable
    /// Сборка без контейнера iCloud (профиль владельца ещё без capability).
    case notProvisioned
    case waitingForTrip
    case syncing(sent: Int)
    case synced(trips: Int, at: Date?)
    case offline(pending: Int)
    case quota
    case remoteWiped
    case failed
}

@MainActor
@Observable
final class CloudSyncService {
    nonisolated deinit {}

    private(set) var mode: CloudSyncMode? = CloudSyncMode(rawValue: Storage.string(.cloudSyncMode) ?? "")
    private(set) var status: CloudStatus = .off
    /// Поездок в iCloud (по журналу).
    private(set) var tripsInCloud = 0
    /// Копия могла остаться в iCloud (включали раньше): «Удалить всю историю»
    /// обязано стереть и её.
    private(set) var mayHaveCloudCopy = false
    /// Копию стёрли на другом устройстве — строка в настройках до следующего включения.
    private(set) var remoteWiped = Storage.bool(.cloudRemoteWiped)

    var isEnabled: Bool { mode == .iCloud }

    @ObservationIgnored private var engine: CloudSyncEngine?
    @ObservationIgnored private var ledger: CloudLedger?
    @ObservationIgnored private var sources: [CloudSource] = []
    @ObservationIgnored private var bridge: CloudSettingsBridge?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var tripActive = false
    @ObservationIgnored private var transportUnavailable = false
    @ObservationIgnored private var accountObserver: NSObjectProtocol?
    @ObservationIgnored private var lastPassAt: Date?
    /// Транспорт для тестов и снимков; по умолчанию — CloudKit по правам сборки.
    @ObservationIgnored var makeTransport: () -> CloudTransport? = { CloudKitTransport.make() }
    /// Энергосбережение или горячий телефон: первая выгрузка ждёт.
    @ObservationIgnored var mayScan: () -> Bool = { !ProcessInfo.processInfo.isLowPowerModeEnabled }
    /// В правах сборки есть контейнер iCloud (читается один раз вне main).
    private(set) var buildSupportsCloud = true

    init() {
        Task { await loadLedger() }
        Task { [weak self] in
            let supported = await Self.probeBuild()
            self?.buildSupportsCloud = supported
            if !supported { self?.transportUnavailable = true }
        }
    }

    @concurrent nonisolated private static func probeBuild() async -> Bool {
        EntitlementProbe.cloudKitContainers()?.contains(AppConfig.cloudContainerID) == true
    }

    /// Источники данных и настройки — из композиционного корня.
    func configure(sources: [CloudSource], settings: AppSettings) {
        self.sources = sources
        bridge = CloudSettingsBridge(settings: settings)
        if isEnabled { startObserving() }
    }

    // MARK: - Журнал на диске

    nonisolated private static var ledgerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cloud_sync.json")
    }

    private func loadLedger() async {
        let loaded = await Self.readLedger()
        ledger = loaded ?? CloudLedger()
        refreshCounts()
        // Удаление, не дошедшее до iCloud (не было сети), — довести; уже
        // назначенный проход (включили, пока читался журнал) не переносим.
        if scheduled == nil, isEnabled || ledger?.pendingWipe != nil {
            schedule(after: AppConfig.cloudLaunchDelay)
        }
    }

    @concurrent nonisolated private static func readLedger() async -> CloudLedger? {
        switch JSONFile.loadChecked(CloudLedger.self, from: ledgerURL, log: Log.cloud) {
        case .missing: return CloudLedger()
        case .loaded(let ledger): return ledger
        case .corrupt:
            // Журнал — производное: битый начинается заново (решения
            // идемпотентны, повторная сверка ничего не задвоит).
            JSONFile.setAside(ledgerURL, log: Log.cloud)
            return CloudLedger()
        case .unreadable:
            return nil
        }
    }

    private func persist(_ ledger: CloudLedger) {
        self.ledger = ledger
        let url = Self.ledgerURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            Log.cloud.error("папка журнала iCloud: \(error.localizedDescription, privacy: .public)")
        }
        JSONFile.saveOrdered(ledger, to: url, log: Log.cloud, wait: false)
        refreshCounts()
    }

    private func refreshCounts() {
        tripsInCloud = ledger?.tripsInCloud ?? 0
        mayHaveCloudCopy = ledger.map { $0.syncedOnce || !$0.entries.isEmpty } ?? false
    }

    // MARK: - Выключатель

    /// Предложить один раз: решения нет, ответа не было, есть что терять,
    /// сборка умеет iCloud.
    func shouldOffer(storedTrips: Int) -> Bool {
        mode == nil && !Storage.bool(.cloudOfferAnswered)
            && storedTrips >= AppConfig.cloudOfferMinTrips && buildSupportsCloud
    }

    func answerOffer(accept: Bool) {
        Storage.set(true, for: .cloudOfferAnswered)
        setMode(accept ? .iCloud : .local)
    }

    func setMode(_ next: CloudSyncMode) {
        Storage.set(true, for: .cloudOfferAnswered)
        guard next != mode else { return }
        mode = next
        Storage.set(next.rawValue, for: .cloudSyncMode)
        switch next {
        case .iCloud:
            // Копию стёрли на другом устройстве: журнал уже чистый — своё
            // уедет заново, чужое (что успели положить) придёт.
            remoteWiped = false
            Storage.remove(.cloudRemoteWiped)
            startObserving()
            status = .checking
            schedule(after: 1)
        case .local:
            stopObserving()
            cancelWork()
            status = .off
        }
    }

    /// Выключить и стереть копию в iCloud (вторая кнопка выключения).
    func turnOffAndDeleteCloudCopy() {
        setMode(.local)
        bridge?.removeCloudCopy()
        requestWipe([.trips, .data])
    }

    /// «Удалить всю историю»: на телефоне уже стёрто; в iCloud — история
    /// (поездки и сводка) сразу или при первой сети. Хранение выключено, а
    /// копия могла остаться — стирается копия целиком (она устарела).
    func historyErased() {
        guard isEnabled || mayHaveCloudCopy else { return }
        requestWipe(isEnabled ? [.trips] : [.trips, .data])
    }

    private func requestWipe(_ zones: Set<CloudZone>) {
        if let engine {
            engine.requestWipe(zones)
        } else if var ledger {
            ledger.pendingWipe = Date()
            ledger.pendingWipeZones.formUnion(zones.map(\.rawValue))
            persist(ledger)
        }
        schedule(after: 1)
    }

    // MARK: - Когда

    /// Поездка началась/кончилась (LocationService.onTripStateChanged).
    func tripStateChanged(active: Bool) {
        tripActive = active
        if active {
            cancelWork()
            if isEnabled { status = .waitingForTrip }
        } else if isEnabled {
            schedule(after: AppConfig.cloudAfterTripDelay)
        }
    }

    /// Экран открыт.
    func sceneBecameActive() {
        guard isEnabled || ledger?.pendingWipe != nil else { return }
        schedule(after: AppConfig.cloudLaunchDelay)
    }

    /// Приложение уходит в фон: ждущее — успеть отправить (короткое фоновое
    /// окно системы), но не в поездке.
    func sceneEnteredBackground() {
        // Правки за этот заход на экран (штраф, журнал, место) видны только
        // сверкой — проход, если последний был не только что.
        let stale = lastPassAt.map { Date().timeIntervalSince($0) > 120 } ?? true
        guard !tripActive, isEnabled || ledger?.pendingWipe != nil,
              stale || (ledger?.pendingCount ?? 0) > 0 || ledger?.pendingWipe != nil else { return }
        let window = BackgroundWindow()
        window.begin { [weak self] in self?.cancelWork() }
        scheduled?.cancel()
        scheduled = nil
        startPass(scan: false) { window.end() }
    }

    /// Что-то правили (штраф, журнал, место, машина): отправить пачкой.
    func noteLocalChange() {
        guard isEnabled, !tripActive else { return }
        schedule(after: AppConfig.cloudChangeDebounce)
    }

    /// «Синхронизировать сейчас» в настройках.
    func syncNow() {
        guard isEnabled else { return }
        schedule(after: 0, scan: true)
    }

    private func schedule(after delay: TimeInterval, scan: Bool = false) {
        guard !tripActive, isEnabled || ledger?.pendingWipe != nil else { return }
        #if DEBUG
        if demo { return }
        #endif
        scheduled?.cancel()
        scheduled = Task { @MainActor [weak self] in
            if delay > 0 { await Task.pause(seconds: delay) }
            guard let self, !Task.isCancelled else { return }
            self.scheduled = nil
            self.startPass(scan: scan)
        }
    }

    private func cancelWork() {
        scheduled?.cancel()
        scheduled = nil
        running?.cancel()
    }

    // MARK: - Проход

    private func makeEngineIfNeeded() -> CloudSyncEngine? {
        if let engine { return engine }
        guard let ledger else { return nil }
        guard let transport = makeTransport() else {
            transportUnavailable = true
            return nil
        }
        let engine = CloudSyncEngine(transport: transport, sources: sources, ledger: ledger) { [weak self] next in
            self?.persist(next)
        }
        engine.mayContinue = { [weak self] in
            guard let self else { return false }
            return !self.tripActive && !Task.isCancelled
        }
        engine.mayScan = { [weak self] in self?.mayScan() ?? false }
        engine.onProgress = { [weak self] sent in
            if sent > 0 { self?.status = .syncing(sent: sent) }
        }
        self.engine = engine
        return engine
    }

    private func startPass(scan: Bool, completion: (() -> Void)? = nil) {
        guard running == nil, !tripActive else { completion?(); return }
        guard ledger != nil else {
            // Журнал не прочитан (до первой разблокировки) — прочитать и позже.
            Task { await loadLedger() }
            completion?()
            return
        }
        guard let engine = makeEngineIfNeeded() else {
            if transportUnavailable { status = isEnabled ? .notProvisioned : .off }
            completion?()
            return
        }
        let wipeOnly = !isEnabled
        if isEnabled { status = .syncing(sent: 0) }
        running = Task { @MainActor [weak self] in
            let outcome = wipeOnly ? await engine.runPendingWipe() : await engine.run(scan: scan)
            guard let self else { return }
            self.running = nil
            self.finish(outcome)
            completion?()
        }
    }

    private func finish(_ outcome: CloudSyncEngine.Outcome) {
        refreshCounts()
        lastPassAt = Date()
        guard isEnabled else {
            status = .off
            return
        }
        switch outcome {
        case .synced:
            status = .synced(trips: tripsInCloud, at: ledger?.lastSyncAt)
            // Первая выгрузка ещё не вся — следующая порция в следующем проходе.
            if let ledger, ledger.fullScanAt == nil, mayScan() { schedule(after: 30) }
        case .notReady:
            schedule(after: 20)
        case .offline:
            status = .offline(pending: ledger?.pendingCount ?? 0)
            schedule(after: AppConfig.cloudRetryDelay)
        case .account(let account):
            status = Self.status(for: account)
        case .remoteWiped:
            Log.cloud.notice("копия в iCloud стёрта на другом устройстве — хранение в iCloud выключено")
            remoteWiped = true
            Storage.set(true, for: .cloudRemoteWiped)
            // Журнал — про стёртую копию: начать заново, чтобы «Удалить всю
            // историю» не стёрло уже чужие новые данные.
            engine?.resetLedger()
            mode = .local
            Storage.set(CloudSyncMode.local.rawValue, for: .cloudSyncMode)
            stopObserving()
            status = .remoteWiped
        case .quota:
            status = .quota
        case .cancelled:
            status = tripActive ? .waitingForTrip : .synced(trips: tripsInCloud, at: ledger?.lastSyncAt)
        case .failed:
            status = .failed
            schedule(after: AppConfig.cloudRetryDelay)
        }
    }

    private static func status(for account: CloudAccount) -> CloudStatus {
        switch account {
        case .available: return .checking
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable, .unknown: return .temporarilyUnavailable
        case .notProvisioned: return .notProvisioned
        }
    }

    #if DEBUG
    /// Снимки экрана: `-cloudOffer` — предложение в «Итогах»,
    /// `-cloudDemo synced|offline|wiped|noAccount|build` — строка состояния.
    func applyDemoArguments(_ arguments: [String]) {
        if arguments.contains("-cloudOffer") {
            mode = nil
            Storage.remove(.cloudSyncMode)
            Storage.remove(.cloudOfferAnswered)
            buildSupportsCloud = true
        }
        guard let index = arguments.firstIndex(of: "-cloudDemo"), index + 1 < arguments.count else { return }
        makeTransport = { nil }
        mode = .iCloud
        switch arguments[index + 1] {
        case "synced": status = .synced(trips: 128, at: Date().addingTimeInterval(-600))
        case "offline": status = .offline(pending: 3)
        case "wiped": mode = .local; remoteWiped = true; status = .off
        case "noAccount": status = .noAccount
        case "build": status = .notProvisioned
        case "trip": status = .waitingForTrip
        default: status = .syncing(sent: 40)
        }
        demo = true
    }
    @ObservationIgnored private var demo = false
    #endif

    // MARK: - Наблюдение

    private func startObserving() {
        bridge?.start()
        guard accountObserver == nil, buildSupportsCloud else { return }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil,
                                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: 2) }
        }
    }

    private func stopObserving() {
        bridge?.stop()
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
        accountObserver = nil
    }
}

/// Короткое фоновое окно системы на дописывание ждущего.
@MainActor
private final class BackgroundWindow {
    nonisolated deinit {}
    private var id = UIBackgroundTaskIdentifier.invalid

    func begin(onExpire: @escaping @MainActor () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: "cloud-sync") { [weak self] in
            MainActor.assumeIsolated {
                onExpire()
                self?.end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
