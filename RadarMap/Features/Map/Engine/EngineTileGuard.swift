//
//  EngineTileGuard.swift
//  RadarMap
//
//  Сторож тайлов движка: НИ ОДНА геометрия дороги не попадает на экран, пока
//  её sha256 не сошёлся с подписанным индексом.
//
//  Зачем это вообще есть. Наш собственный формат тайлов возит телефон сам, и
//  каждый тайл сверяется с подписанным индексом (RoadNetworkService) — правило
//  19 из ARCHITECTURE.md: применяем без спроса только то, что подписано
//  владельцем, и при любой неисправности отказываем, а не «спасаем часть».
//  Взломанный сервер не должен уметь нарисовать водителю свои дороги.
//
//  MVT ходит мимо этого пути: тайлы качает сам движок. Значит либо сторож
//  встаёт на его дорогу, либо правило отменяется на самом важном слое карты.
//  Отменять нельзя, поэтому сторож — обычный URLProtocol в сессии движка:
//  он забирает тайл сам, считает sha256 и отдаёт дальше только совпавшее.
//
//  Индекс MVT подписан тем же ключом, что и наш (publish_roads.sh). Пока
//  индекса на сервере нет, сторож не пускает НИЧЕГО: карта на движке будет
//  пустой, и это правильный отказ — пустая карта честнее подделанной.
//

#if canImport(MapLibre)
import CryptoKit
import Foundation
import MapLibre
import os

nonisolated final class EngineTileGuard: URLProtocol, @unchecked Sendable {

    /// Ключ, по которому наш собственный запрос отличается от чужого: без него
    /// протокол ловил бы сам себя и уходил в бесконечную рекурсию.
    private static let ownRequest = "X-RadarMap-Tile-Guard"
    /// Часть пути, по которой узнаётся тайл движка.
    private static let mvtPath = "/mvt/"

    private static let log = Log.network

    // MARK: - Индекс

    nonisolated struct Index: Decodable, Sendable {
        struct Meta: Decodable, Sendable {
            let sha256: String
            let bytes: Int
        }
        let version: Int
        let tiles: [String: Meta]
    }

    /// Индекс живёт в одном экземпляре и читается из многих потоков сессии
    /// движка, поэтому — под замком, а не «просто переменная».
    private static let lock = OSAllocatedUnfairLock(initialState: Index?.none)

    static var isReady: Bool { lock.withLock { $0 != nil } }

    /// Забрать и проверить индекс. Без него сторож не пропускает ни одного
    /// тайла — сознательно.
    static func prepare() async {
        if isReady { return }
        let url = AppConfig.syncBaseURL.appendingPathComponent("mvt_index.json")
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: ownRequest)
        request.cachePolicy = .reloadRevalidatingCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let envelope = try? JSONDecoder().decode(SignedPayload<Index>.self, from: data),
              let index = envelope.verified()
        else {
            log.error("индекс MVT не пришёл или не проверился — карта на движке останется пустой")
            return
        }
        lock.withLock { $0 = index }
        log.info("индекс MVT принят: \(index.tiles.count) тайлов")
    }

    /// Ключ тайла из адреса: .../mvt/15/22686/12246.mvt → «15/22686/12246».
    static func tileKey(for url: URL) -> String? {
        let parts = url.path.components(separatedBy: mvtPath)
        guard parts.count == 2 else { return nil }
        let tail = parts[1]
        guard tail.hasSuffix(".mvt") else { return nil }
        return String(tail.dropLast(4))
    }

    static func expected(for url: URL) -> Index.Meta? {
        guard let key = tileKey(for: url) else { return nil }
        return lock.withLock { $0?.tiles[key] }
    }

    /// Поставить сторожа на сессию движка. Зовётся один раз, до первой карты.
    @MainActor
    static func install() {
        let configuration = MLNNetworkConfiguration.sharedManager.sessionConfiguration
            ?? URLSessionConfiguration.default
        var classes = configuration.protocolClasses ?? []
        guard !classes.contains(where: { $0 == EngineTileGuard.self }) else { return }
        classes.insert(EngineTileGuard.self, at: 0)
        configuration.protocolClasses = classes
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = configuration
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        guard request.value(forHTTPHeaderField: ownRequest) == nil,
              let url = request.url else { return false }
        return url.path.contains(mvtPath) && url.path.hasSuffix(".mvt")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return finish(with: URLError(.badURL)) }
        guard let meta = Self.expected(for: url) else {
            // Тайла нет в индексе — либо индекс не пришёл, либо сервер отдаёт
            // то, чего владелец не подписывал. Оба случая — отказ.
            Self.log.error("тайл вне подписанного индекса: \(url.path, privacy: .public)")
            return finish(with: URLError(.userAuthenticationRequired))
        }
        var own = request
        own.setValue("1", forHTTPHeaderField: Self.ownRequest)
        loader = URLSession.shared.dataTask(with: own) { [weak self] data, response, error in
            guard let self else { return }
            if let error { return self.finish(with: error) }
            guard let data, let response else {
                return self.finish(with: URLError(.badServerResponse))
            }
            // 404 и 204 — «тайла нет», и это НЕ ошибка: пирамида дырявая по
            // построению, движок такой ответ понимает и рисует пустоту.
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 204 || code == 404 {
                return self.deliver(data: Data(), response: response)
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == meta.sha256 else {
                Self.log.error("sha256 тайла не сошёлся: \(url.path, privacy: .public)")
                return self.finish(with: URLError(.userAuthenticationRequired))
            }
            self.deliver(data: data, response: response)
        }
        loader?.resume()
    }

    override func stopLoading() {
        loader?.cancel()
        loader = nil
    }

    /// Своя загрузка тайла. Имя не `task`: у URLProtocol такое свойство уже
    /// есть, и перекрыть его хранимым нельзя.
    private var loader: URLSessionDataTask?

    private func deliver(data: Data, response: URLResponse) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func finish(with error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }
}
#endif
