//
//  LaneOverlayService.swift
//  RadarMap
//
//  Слой полос (20.8): подписанный индекс `lanes/lanes_index.json` и файл
//  данных за ним. Устройство — как у графа трасс (OfflineRouteService) и
//  лимитов: подписан маленький индекс (SignedPayload, ключ владельца, на
//  сервере ключа нет), сам файл едет без подписи и сверяется по sha256 и
//  размеру. Подпись индекса и sha файла перепроверяются при КАЖДОЙ загрузке
//  с диска (LaneOverlayTrust.overlay); не сошлось — слоя нет (fail closed), и
//  маршрут живёт как без него: полосы OSRM и край по ПДД.
//
//  Индекс — раз в неделю; первый файл — любой связью, обновления — только не
//  по сотовой. Пока владелец не опубликовал слой, сервер отвечает 404: это
//  штатно, одна строка в журнал и повтор раз в сутки (чтобы опубликованный
//  слой доехал до телефонов за день, а не за неделю).
//
//  В память слой поднимается лениво — первым маршрутом, вне главного потока:
//  тому, кто маршрутов не строит, он не стоит ни памяти, ни разбора.
//  Рубильник — пульт `features.laneOverlay`.
//

import Foundation
import os

@MainActor
final class LaneOverlayService {
    /// Снос без прыжка на актор — см. RouteService.deinit.
    nonisolated deinit {}

    private let api = APIClient(timeout: 10, resourceTimeout: 60)
    weak var network: NetworkMonitor?

    /// Пульт: `features.laneOverlay`. Ставит AppEnvironment.
    var allowedByConfig: (() -> Bool)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: allowedByConfig,
                                               "LaneOverlayService.allowedByConfig") }
    }
    /// Слой появился в памяти, сменился или снят — маршрут прикладывает заново.
    var onChange: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onChange,
                                               "LaneOverlayService.onChange") }
    }

    /// Проверенный слой в памяти; nil — не поднят, не прошёл проверку или его нет.
    private(set) var overlay: LaneOverlay?
    private var loading: Task<Void, Never>?
    /// Растёт с каждой новой версией на диске: чтение, начатое до неё,
    /// результат в память не кладёт (правило 12).
    private var generation = 0
    /// Файлы на диске не прошли проверку — до новой версии не перечитываем
    /// их на каждом маршруте: ответ будет тот же.
    private var diskRejected = false
    /// Слой уже просили (строили маршрут): новая версия тогда сразу в память.
    private var wasRequested = false
    private var isRefreshing = false
    /// Последняя попытка до сервера, удачная или нет (повтор после сбоя сети).
    private var lastAttempt = Date.distantPast
    private var missingLogged = false

    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppConfig.laneOverlayDirectory, isDirectory: true)
    }
    private var envelopeURL: URL { directory.appendingPathComponent("lanes_index.json") }

    var isAllowed: Bool { allowedByConfig?() ?? true }
    /// Слой лежит на телефоне (его индекс). Подпись здесь не проверяется: это
    /// вопрос «качать ли по сотовой», а не «верить ли» — верит чтение.
    private var hasFiles: Bool { FileManager.default.fileExists(atPath: envelopeURL.path) }

    // MARK: - Слой для маршрута

    /// Действующий слой: проверенный и разрешённый пультом. Первый вызов
    /// поднимает его с диска вне главного потока — ответ придёт через
    /// `onChange`, а этот вызов вернёт nil.
    func current() -> LaneOverlay? {
        guard isAllowed else { return nil }
        wasRequested = true
        if overlay == nil { loadFromDisk() }
        return overlay
    }

    private func loadFromDisk() {
        guard loading == nil, !diskRejected, hasFiles else { return }
        let envelope = envelopeURL, directory = directory, generation = generation
        loading = Task {
            let result = await Self.read(envelope: envelope, directory: directory)
            // Пока читали, скачалась новая версия — прочитанное уже старое.
            guard generation == self.generation else { return }
            loading = nil
            guard let result else {
                diskRejected = true
                return
            }
            guard isAllowed else { return }
            overlay = result
            onChange?()
        }
    }

    /// С диска: подпись индекса — заново, размер и sha файла — заново.
    @concurrent
    private static func read(envelope: URL, directory: URL) async -> LaneOverlay? {
        let index: Data
        do {
            index = try Data(contentsOf: envelope)
        } catch {
            Log.route.error("слой полос: индекс на диске не читается — \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // Файла по имени из индекса нет — `missingFile` ниже, с причиной в журнале.
        let result = LaneOverlayTrust.overlay(index: index) { name in
            try? Data(contentsOf: directory.appendingPathComponent(name))
        }
        switch result {
        case .success(let value):
            Log.route.notice("слой полос: версия \(value.version, privacy: .public), подходов \(value.overlay.count, privacy: .public), отброшено \(value.overlay.dropped, privacy: .public)")
            return value.overlay
        case .failure(let why):
            Log.route.error("слой полос: на диске не сошлось — \(why.logDescription, privacy: .public) — без слоя")
            return nil
        }
    }

    @concurrent
    private static func decode(_ data: Data) async -> Result<LaneOverlay, LaneOverlay.Failure> {
        LaneOverlay.decode(data)
    }

    // MARK: - Скачивание

    /// Раз в неделю (без слоя на сервере — раз в сутки): подписанный индекс;
    /// новый файл — скачать, сверить, разобрать, положить рядом и только
    /// потом индекс. Пульт выключил слой — снять его и не ходить в сеть.
    func refreshIfDue(now: Date = Date()) async {
        guard isAllowed else {
            dropForConfig()
            return
        }
        guard !isRefreshing, network?.isOnline ?? true,
              now.timeIntervalSince(lastAttempt) >= AppConfig.laneOverlayRetrySeconds else { return }
        if let last = Storage.date(.laneOverlayLastCheck), last <= now,
           now.timeIntervalSince(last) < (hasFiles ? AppConfig.laneOverlayIndexInterval
                                                   : AppConfig.laneOverlayMissingRecheckSeconds) { return }
        let haveFiles = hasFiles
        // Обновление — не по сотовой; первый файл — любой связью.
        if haveFiles, network?.isExpensive ?? true { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastAttempt = now

        let raw: Data
        do {
            raw = try await api.getData(AppConfig.laneOverlayIndexPath, cachePolicy: .reloadIgnoringLocalCacheData)
        } catch APIClient.Failure.badStatus(404) {
            // Владелец ещё не опубликовал слой — штатно и тихо: одна строка.
            Storage.set(now, for: .laneOverlayLastCheck)
            if !missingLogged {
                missingLogged = true
                Log.route.notice("слой полос: на сервере его нет (404) — работаем без слоя")
            }
            return
        } catch {
            // Сеть — дату проверки не двигаем, повтор через laneOverlayRetrySeconds.
            Log.route.notice("слой полос: индекс не получен — \(error.localizedDescription, privacy: .public)")
            return
        }
        Storage.set(now, for: .laneOverlayLastCheck)
        await apply(index: raw, haveFiles: haveFiles)
    }

    private func apply(index raw: Data, haveFiles: Bool) async {
        let verified: (manifest: LanesManifest, file: LanesManifest.File)
        switch LaneOverlayTrust.verifyIndex(raw) {
        case .failure(let why):
            Log.route.error("слой полос: индекс сервера отвергнут — \(why.logDescription, privacy: .public) — не применяем")
            return
        case .success(let value):
            verified = value
        }
        // Тот же индекс уже на диске — нечего делать. Чужие байты на диске
        // (нечитаемы) — то же, что их нет.
        if haveFiles, (try? Data(contentsOf: envelopeURL)) == raw { return }
        // Подписанный, но СТАРШЕ применённого — откат выкладки: держим своё.
        if let applied = Storage.intIfPresent(.laneOverlayVersion), verified.manifest.version < applied {
            Log.route.error("слой полос: версия \(verified.manifest.version, privacy: .public) старше применённой \(applied, privacy: .public) — не применяем")
            return
        }
        let file = verified.file
        let target = directory.appendingPathComponent(file.name)
        let bytes: Data
        // Файл той же версии уже лежит (прервалась запись индекса) — не качаем снова.
        if let existing = try? Data(contentsOf: target), LaneOverlayTrust.verifyData(existing, against: file) == nil {
            bytes = existing
        } else {
            do {
                bytes = try await api.getData(AppConfig.laneOverlayDirectory + "/" + file.name)
            } catch {
                Log.route.notice("слой полос: файл не получен — \(error.localizedDescription, privacy: .public)")
                return
            }
            if let why = LaneOverlayTrust.verifyData(bytes, against: file) {
                Log.route.error("слой полос: файл не сошёлся с индексом — \(why.logDescription, privacy: .public) — не применяем")
                return
            }
        }
        // Разобрать ДО записи индекса: подписанный, но нечитаемый файл не
        // должен вытеснить рабочий слой.
        let decoded: LaneOverlay
        switch await Self.decode(bytes) {
        case .failure(let why):
            Log.route.error("слой полос: файл не разобран — \(why.logDescription, privacy: .public) — не применяем")
            return
        case .success(let value):
            decoded = value
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bytes.write(to: target, options: .atomic)
            try raw.write(to: envelopeURL, options: .atomic)
        } catch {
            Log.route.error("слой полос: не записан — \(error.localizedDescription, privacy: .public)")
            return
        }
        Storage.set(verified.manifest.version, for: .laneOverlayVersion)
        removeStale(keeping: file.name)
        generation += 1
        loading = nil
        diskRejected = false
        Log.route.notice("слой полос: версия \(verified.manifest.version, privacy: .public), подходов \(decoded.count, privacy: .public), отброшено \(decoded.dropped, privacy: .public)")
        // После await — заново (правило 12): пульт мог выключить слой.
        guard isAllowed else { return }
        // Маршрут уже просил слой — новая версия сразу в работу; иначе
        // поднимется с диска первым маршрутом.
        if wasRequested || overlay != nil {
            overlay = decoded
            onChange?()
        }
    }

    /// Пульт выключил слой: из памяти — сразу, маршрут снимает приложенные ряды.
    /// Файлы остаются: включат обратно — слой вернётся без загрузки.
    private func dropForConfig() {
        loading?.cancel()
        loading = nil
        generation += 1
        guard overlay != nil else { return }
        overlay = nil
        Log.route.notice("слой полос: выключен пультом")
        onChange?()
    }

    private func removeStale(keeping name: String) {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            Log.route.error("слой полос: каталог не прочитан — \(error.localizedDescription, privacy: .public)")
            return
        }
        for stale in names where stale.hasPrefix(LanesManifest.filePrefix) && stale != name {
            do {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(stale))
            } catch {
                Log.route.error("слой полос: старый файл не удалён — \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
