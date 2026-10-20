//
//  OfflineRouteService.swift
//  RadarMap
//
//  Граф трасс для маршрута без сети (12б.10). Устройство — как у лимитов
//  скорости: подписан маленький индекс (SignedPayload, ключ владельца, на
//  сервере ключа нет), сам файл в несколько мегабайт едет без подписи и
//  сверяется по sha256 и размеру. Индекс перепроверяется при КАЖДОЙ
//  загрузке с диска; не сошлось — графа нет (fail closed), а значит нет и
//  маршрута без сети — честнее, чем маршрут по подменённому файлу.
//
//  Скачивается раз в неделю проверкой индекса; первый раз — любой связью
//  (без него на трассе нет ничего), обновления — только не по сотовой.
//  Граф собирается в памяти лениво, при первом маршруте без сети, и не
//  на главном потоке.
//

import Foundation
import CoreLocation
import os

/// Подписанный индекс графа: тот же контракт, что у лимитов (format,
/// version, files[name, sha256, bytes]) — server/build_route_graph.py.
nonisolated struct RouteGraphManifest: Decodable, Sendable, Equatable {
    let format: Int
    let version: Int
    let files: [File]

    struct File: Decodable, Sendable, Equatable {
        let format: Int
        let name: String
        let sha256: String
        let bytes: Int
    }

    static let indexFormat = 1
    static let dataFormat = 1

    /// Файл, который умеем читать, если индекс в порядке; nil — не верить.
    var usableFile: File? {
        guard format == Self.indexFormat, version > 0,
              let file = files.first(where: { $0.format == Self.dataFormat }),
              LimitsManifest.isSafeName(file.name), !file.name.contains("/"),
              file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              (1...AppConfig.offlineGraphMaxBytes).contains(file.bytes) else { return nil }
        return file
    }
}

@MainActor
final class OfflineRouteService {
    nonisolated deinit {}

    private let api = APIClient()
    private var graph: OfflineRouteGraph?
    private var loading: Task<OfflineRouteGraph?, Never>?
    private var lastIndexCheck = Date.distantPast
    weak var network: NetworkMonitor?

    private static let indexPath = "routes/route_graph_index.json"
    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("routes", isDirectory: true)
    }
    private var envelopeURL: URL { directory.appendingPathComponent("route_graph_index.json") }

    // MARK: - Маршрут

    /// Маршрут по своему графу. nil — графа нет или точки далеко от трасс.
    func path(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> OfflineRouteGraph.Path? {
        guard let graph = await loadedGraph() else { return nil }
        return await Self.solve(graph, from: from, to: to)
    }

    @concurrent
    private static func solve(_ graph: OfflineRouteGraph, from: CLLocationCoordinate2D,
                              to: CLLocationCoordinate2D) async -> OfflineRouteGraph.Path? {
        graph.route(from: from, to: to)
    }

    private func loadedGraph() async -> OfflineRouteGraph? {
        if let graph { return graph }
        if let loading { return await loading.value }
        let envelope = envelopeURL, directory = directory
        let task = Task { await Self.readGraph(envelope: envelope, directory: directory) }
        loading = task
        let result = await task.value
        loading = nil
        graph = result
        return result
    }

    /// С диска: подпись индекса — заново, sha файла — заново.
    @concurrent
    private static func readGraph(envelope: URL, directory: URL) async -> OfflineRouteGraph? {
        // Файла нет — граф ещё не скачан, это штатно.
        guard let data = try? Data(contentsOf: envelope) else { return nil }
        let manifest: RouteGraphManifest
        do {
            let signed = try JSONDecoder().decode(SignedPayload<RouteGraphManifest>.self, from: data)
            guard case .success(let value) = signed.verify() else {
                Log.route.error("граф трасс: подпись индекса на диске не сошлась — без маршрута без сети")
                return nil
            }
            manifest = value
        } catch {
            Log.route.error("граф трасс: индекс на диске не читается — \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let file = manifest.usableFile,
              // Итог — одна строка журнала ниже: «файл не сошёлся с индексом».
              let bytes = try? Data(contentsOf: directory.appendingPathComponent(file.name)),
              bytes.count == file.bytes, RoadTiles.sha256Hex(of: bytes) == file.sha256,
              let lines = RoadTiles.decodeTile(bytes) else {
            Log.route.error("граф трасс: файл не сошёлся с индексом — без маршрута без сети")
            return nil
        }
        let graph = OfflineRouteGraph.build(lines)
        Log.route.notice("граф трасс: \(graph.nodeCount, privacy: .public) узлов")
        return graph
    }

    // MARK: - Скачивание

    /// Раз в неделю: подписанный индекс; новый файл — скачать, сверить,
    /// положить рядом и только потом индекс.
    func refreshIfDue(now: Date = Date()) async {
        guard now.timeIntervalSince(lastIndexCheck) >= AppConfig.offlineGraphIndexInterval,
              network?.isOnline ?? true else { return }
        let haveGraph = FileManager.default.fileExists(atPath: envelopeURL.path)
        // Обновление — не по сотовой; первый файл — любой связью.
        if haveGraph, network?.isExpensive ?? true { return }
        lastIndexCheck = now
        do {
            let raw = try await api.getData(Self.indexPath, cachePolicy: .reloadIgnoringLocalCacheData)
            let signed = try JSONDecoder().decode(SignedPayload<RouteGraphManifest>.self, from: raw)
            guard case .success(let manifest) = signed.verify(), let file = manifest.usableFile else {
                Log.route.error("граф трасс: индекс сервера не прошёл проверку — не применяем")
                return
            }
            let target = directory.appendingPathComponent(file.name)
            if !FileManager.default.fileExists(atPath: target.path) {
                let data = try await api.getData("routes/" + file.name)
                guard data.count == file.bytes, RoadTiles.sha256Hex(of: data) == file.sha256 else {
                    Log.route.error("граф трасс: файл не сошёлся с индексом — не применяем")
                    return
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
            try raw.write(to: envelopeURL, options: .atomic)
            removeStale(keeping: file.name)
            graph = nil   // следующий маршрут без сети соберёт новый
            Log.route.notice("граф трасс: версия \(manifest.version, privacy: .public)")
        } catch {
            Log.route.notice("граф трасс: индекс не получен — \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeStale(keeping name: String) {
        // Каталога нет — чистить нечего.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for stale in names where stale.hasPrefix("route_graph.") && stale != name {
            do {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(stale))
            } catch {
                Log.route.error("граф трасс: старый файл не удалён — \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
