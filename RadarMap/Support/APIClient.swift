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
    private let timeout: TimeInterval

    /// `timeout` — на запрос; для тяжёлых загрузок (база камер) ставим больше.
    ///
    /// Сессия — ОБЩАЯ для всех клиентов (36B, 28.10). До этого каждый сервис
    /// заводил свою `URLSession`, а у каждой сессии свой пул соединений: такт
    /// планировщика, в котором отметки, дорога и пробки уходят вместе, открывал
    /// к одному soulmed.uz три TCP+TLS вместо одного HTTP/2 с тремя потоками —
    /// и рукопожатия держали радио дольше самих ответов. Таймаут запроса
    /// ставится на сам запрос (`URLRequest.timeoutInterval`), таймаут ресурса —
    /// свойство сессии, поэтому всё до минуты делит одну сессию с минутным
    /// потолком, а загрузки областей (полчаса) живут в своей.
    init(timeout: TimeInterval = 10, resourceTimeout: TimeInterval = 60,
         base: URL = AppConfig.syncBaseURL) {
        session = SessionPool.session(resourceTimeout: resourceTimeout)
        self.timeout = timeout
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
    /// `serverDate` — заголовок `Date` ответа: часы сервера, по ним сроки из
    /// ответа переводятся на часы телефона (S31).
    func getIfChanged<T: Decodable>(_ path: String, as type: T.Type,
                                    etag: String?) async throws -> (value: T, etag: String?, serverDate: Date?)? {
        var req = request(path)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await transport(req)
        if let http = response as? HTTPURLResponse, http.statusCode == 304 { return nil }
        try Self.checkStatus(response, path: path)
        let http = response as? HTTPURLResponse
        let fresh = http?.value(forHTTPHeaderField: "ETag")
        return (try decode(data, path: path), fresh,
                http?.value(forHTTPHeaderField: "Date").flatMap(Self.httpDate))
    }

    /// RFC 7231 IMF-fixdate: «Tue, 20 Oct 2026 10:15:30 GMT».
    nonisolated static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    /// Сырые данные «только если изменилось» — для файлов, которые разбирает
    /// сам вызывающий (пробки: свой формат, разбор вне главного потока).
    /// `nil` — 304, у нас уже есть то же самое.
    func getRawIfChanged(_ path: String, etag: String?) async throws -> (data: Data, etag: String?)? {
        var req = request(path)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await transport(req)
        if let http = response as? HTTPURLResponse, http.statusCode == 304 { return nil }
        try Self.checkStatus(response, path: path)
        return (data, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"))
    }

    /// Только код ответа, тип содержимого и, по просьбе, один заголовок —
    /// есть ли адрес на сервере вообще (новая функция при старом сервере) и
    /// что он о себе говорит (X-Eta-Bot, 22.1). nil — сети нет.
    func probe(_ path: String, header: String? = nil) async -> (status: Int, contentType: String?, header: String?)? {
        var req = request(path)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        // Сбой сети уже записан в журнал в transport; здесь он значит «не знаем».
        guard let (_, response) = try? await transport(req),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, http.value(forHTTPHeaderField: "Content-Type"),
                header.flatMap { http.value(forHTTPHeaderField: $0) })
    }

    /// GET с параметрами и кодом ответа, без проверки статуса: отказ сервера
    /// маршрутов несёт тело (OSRM: 400 и `{"code":"NoRoute"}`), его разбирает
    /// вызывающий. `label` — что писать в журнал вместо пути: в пути OSRM
    /// координаты поездки.
    func getRaw(_ path: String, query: [URLQueryItem], label: String,
                cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) async throws -> (status: Int, data: Data) {
        var req = request(path)
        if !query.isEmpty, let url = req.url,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            req.url = components.url ?? url
        }
        req.cachePolicy = cachePolicy
        let (data, response) = try await transport(req, label: label)
        return ((response as? HTTPURLResponse)?.statusCode ?? 200, data)
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
        NetActivity.began(path, at: Date())
        defer { NetActivity.ended(at: Date()) }
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

    /// Исход отправки, когда тело можно отложить и повторить: принято;
    /// не примут никогда — только статусы про САМО тело (400, 413, 415, 422:
    /// повтор того же тела только забил бы очередь); всё прочее — повторить:
    /// 404/405/403 значат «не тот адрес», а не «не то тело» — откат строки
    /// nginx стёр бы всю очередь крэшей за одну досылку (ревью S26).
    enum PostOutcome: Equatable { case accepted, retry, rejected(Int) }

    nonisolated static func outcome(status: Int) -> PostOutcome {
        switch status {
        case 200..<300: .accepted
        case 400, 413, 415, 422: .rejected(status)
        default: .retry
        }
    }

    /// POST сырого тела с исходом из трёх (см. `PostOutcome`).
    func post(_ path: String, body: Data) async -> PostOutcome {
        var req = request(path)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            let (_, response) = try await transport(req)
            guard let http = response as? HTTPURLResponse else { return .accepted }
            let outcome = Self.outcome(status: http.statusCode)
            if outcome != .accepted {
                Log.network.error("POST \(path, privacy: .public): HTTP \(http.statusCode, privacy: .public)")
            }
            return outcome
        } catch {
            Log.network.error("POST \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .retry
        }
    }

    /// POST сырого тела (готовый JSON Data) без разбора ответа.
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
        URLRequest(url: Self.url(path, base: base), timeoutInterval: timeout)
    }

    /// Адрес запроса. Путь `api/…` при DEBUG `-apiBase` — на подменный сервер
    /// (`AppConfig.debugAPIBaseURL`), всё прочее — от корня клиента.
    nonisolated static func url(_ path: String, base: URL,
                                apiOverride: URL? = AppConfig.debugAPIBaseURL) -> URL {
        if let apiOverride, path.hasPrefix("api/") || path.hasPrefix("/api/") {
            return apiOverride.appendingPathComponent(path)
        }
        return base.appendingPathComponent(path)
    }

    private func jsonRequest(_ path: String, body: [String: Any]) -> URLRequest {
        var req = request(path)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            // POST без тела ушёл бы молча и вернул бы 400 без объяснения.
            Log.network.fault("тело \(path, privacy: .public) не закодировано: \(error.localizedDescription, privacy: .public)")
        }
        return req
    }

    /// Ошибки сети и статуса пишутся в журнал ЗДЕСЬ, один раз на всех: вызовы
    /// `getData` у дорог и лимитов идут через `try?`, и без этой записи сбой
    /// загрузки (в том числе подмена набора на сервере) не оставлял следа
    /// нигде (ARCHITECTURE.md, правило 3). Без сети — `notice`: это обычное
    /// состояние в дороге, а не ошибка программы.
    private func transport(_ request: URLRequest, label: String? = nil) async throws -> (Data, URLResponse) {
        let started = Date()
        let name = label ?? request.url?.path ?? "?"
        NetActivity.began(name, at: started)
        defer { NetActivity.ended(at: Date()) }
        do {
            return try await session.data(for: request)
        } catch {
            Log.network.notice("\(name, privacy: .public): сеть — \(error.localizedDescription, privacy: .public)")
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

/// Общие сессии клиентов: одна на потолок времени ресурса. Всё, что
/// укладывается в минуту, — в одной (один пул соединений, HTTP/2 к одному
/// серверу), долгие загрузки областей — в своей. Эфемерные: ни кук, ни
/// дискового кэша, как и прежде.
private nonisolated enum SessionPool {
    private static let sessions = OSAllocatedUnfairLock(initialState: [TimeInterval: URLSession]())

    static func session(resourceTimeout: TimeInterval) -> URLSession {
        let ceiling = max(resourceTimeout, AppConfig.netSharedResourceTimeout)
        return sessions.withLock { pool in
            if let ready = pool[ceiling] { return ready }
            let config = URLSessionConfiguration.ephemeral
            // Потолок ожидания — у самого запроса (`timeoutInterval`); здесь
            // только верхняя граница, чтобы она не обрезала его раньше.
            config.timeoutIntervalForRequest = ceiling
            config.timeoutIntervalForResource = ceiling
            let session = URLSession(configuration: config)
            pool[ceiling] = session
            return session
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
