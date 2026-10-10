//
//  APIClient.swift
//  RadarMap
//
//  Единая точка сети: базовый URL, таймауты, проверка статуса, JSON-кодирование
//  и декодирование, лог. Сервисы описывают ЧТО хотят, а не КАК ходить в сеть.
//

import Foundation
import os

/// `nonisolated` — значимый тип над `URLSession`/`URL`: сеть дёргают и фоновые
/// контексты (MetricKit-делегат, `@concurrent`-загрузка базы), main им не нужен.
nonisolated struct APIClient {
    enum Failure: Error { case badStatus(Int), transport(Error) }

    private let session: URLSession
    private let base: URL

    /// `timeout` — на запрос; для тяжёлых загрузок (база камер) ставим больше.
    init(timeout: TimeInterval = 10, resourceTimeout: TimeInterval = 60,
         base: URL = AppConfig.syncBaseURL) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = resourceTimeout
        session = URLSession(configuration: config)
        self.base = base
    }

    // MARK: - GET

    /// GET с декодированием в `T`. Бросает на сети/статусе/формате.
    func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let (data, response) = try await transport(request(path))
        try Self.checkStatus(response, path: path)
        return try decode(data, path: path)
    }

    /// GET «только если изменилось»: отпечаток прошлого ответа уходит в
    /// `If-None-Match`, и сервер на неизменившийся список отвечает 304 без тела.
    ///
    /// `nil` в ответе — это и есть 304: у нас уже есть ровно то же самое.
    /// Разница для телефона не в трафике как таковом, а в работе радио и в
    /// разборе JSON: пустой ответ дешевле полного списка отметок по стране на
    /// порядок, и именно он позволяет спрашивать чаще.
    ///
    /// Кэш URLSession здесь обходим намеренно: он ответил бы нам двухсоткой из
    /// своей памяти, и мы бы заново разбирали тот же JSON, не узнав, что
    /// ничего не изменилось.
    func getIfChanged<T: Decodable>(_ path: String, as type: T.Type,
                                    etag: String?) async throws -> (value: T, etag: String?)? {
        var req = request(path)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await transport(req)
        if let http = response as? HTTPURLResponse, http.statusCode == 304 { return nil }
        try Self.checkStatus(response, path: path)
        let fresh = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
        return (try decode(data, path: path), fresh)
    }

    /// GET сырых данных (файлы базы) с проверкой статуса.
    func getData(_ path: String, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) async throws -> Data {
        var req = request(path)
        req.cachePolicy = cachePolicy
        let (data, response) = try await transport(req)
        try Self.checkStatus(response, path: path)
        return data
    }

    // MARK: - Файлы

    /// Скачать файл (офлайн-регион, десятки МБ) с прогрессом 0…1. Возвращает
    /// временный файл, принадлежащий вызывающему: проверить и перенести его —
    /// его дело. Таймаут ресурса задаёт `resourceTimeout` клиента.
    func download(_ path: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let watcher = DownloadProgress(progress)
        let (temporary, response): (URL, URLResponse)
        do {
            (temporary, response) = try await session.download(for: request(path), delegate: watcher)
        } catch {
            throw Failure.transport(error)
        }
        try Self.checkStatus(response, path: path)
        // Временный файл системы живёт недолго — сразу переносим в свой.
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + base.appendingPathComponent(path).lastPathComponent)
        try FileManager.default.moveItem(at: temporary, to: owned)
        return owned
    }

    // MARK: - POST

    /// POST JSON-словаря с декодированием ответа в `T`.
    @discardableResult
    func post<T: Decodable>(_ path: String, json: [String: Any], as type: T.Type) async throws -> T {
        let (data, response) = try await transport(jsonRequest(path, body: json))
        try Self.checkStatus(response, path: path)
        return try decode(data, path: path)
    }

    /// POST без разбора тела ответа — важен только факт приёма (2xx).
    /// `true` — сервер принял; ошибки сети/статуса логируются, не бросаются.
    func postAccepted(_ path: String, json: [String: Any]) async -> Bool {
        do {
            let (_, response) = try await transport(jsonRequest(path, body: json))
            try Self.checkStatus(response, path: path)
            return true
        } catch {
            Log.network.error("POST \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// POST сырого тела (готовый JSON Data) без разбора ответа — для MetricKit.
    func postAccepted(_ path: String, body: Data) async -> Bool {
        var req = request(path)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            let (_, response) = try await transport(req)
            try Self.checkStatus(response, path: path)
            return true
        } catch {
            Log.network.error("POST \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Построение запроса

    private func request(_ path: String) -> URLRequest {
        URLRequest(url: base.appendingPathComponent(path))
    }

    private func jsonRequest(_ path: String, body: [String: Any]) -> URLRequest {
        var req = request(path)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Ошибки сети и статуса пишутся в журнал ЗДЕСЬ, один раз на всех: вызовы
    /// `getData` у дорог и лимитов идут через `try?`, и без этой записи сбой
    /// загрузки (в том числе подмена набора на сервере) не оставлял следа
    /// нигде (ARCHITECTURE.md, правило 3). Без сети — `notice`: это обычное
    /// состояние в дороге, а не ошибка программы.
    private func transport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            Log.network.notice("\(request.url?.path ?? "?", privacy: .public): сеть — \(error.localizedDescription, privacy: .public)")
            throw Failure.transport(error)
        }
    }

    private func decode<T: Decodable>(_ data: Data, path: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Log.network.error("\(path, privacy: .public): ответ не декодировался — \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private static func checkStatus(_ response: URLResponse, path: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            Log.network.error("\(path, privacy: .public): HTTP \(http.statusCode)")
            throw Failure.badStatus(http.statusCode)
        }
    }
}

/// Прогресс загрузки: задача создаётся внутри URLSession, её `progress`
/// наблюдается с момента создания (`didCreateTask`).
private nonisolated final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
            report(progress.fractionCompleted)
        }
    }
}
