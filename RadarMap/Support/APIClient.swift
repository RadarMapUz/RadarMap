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

    /// GET сырых данных (файлы базы) с проверкой статуса.
    func getData(_ path: String, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) async throws -> Data {
        var req = request(path)
        req.cachePolicy = cachePolicy
        let (data, response) = try await transport(req)
        try Self.checkStatus(response, path: path)
        return data
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

    private func transport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
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
            throw Failure.badStatus(http.statusCode)
        }
    }
}
