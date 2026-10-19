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

    /// Своя сессия сторожа — БЕЗ URLCache, и это не микрооптимизация.
    ///
    /// Тайлы кэшировались ДВАЖДЫ: у движка своя база на 200 МБ
    /// (`engineMapCacheBytes`, она же офлайн в поездке по стране), а сторож
    /// вдобавок ходил через `URLSession.shared` и складывал каждый тайл в
    /// общий `URLCache` — та же геометрия второй раз, и на диске, и в памяти.
    /// Второй экземпляр не давал ничего: офлайн держит движок, а сторож
    /// каждый тайл всё равно проверяет по подписи заново.
    ///
    /// Индекс сюда же: 23,5 МБ ответа в общем кэше — чистая трата, он и так
    /// лежит разобранным своим файлом.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    // MARK: - Индекс

    /// Подписанный индекс, как он лежит в JSON. Разбирается ОДИН раз за жизнь
    /// установленной версии и тут же сворачивается в `TileDigestIndex`:
    /// держать эту форму в памяти — тридцать с лишним мегабайт строк.
    ///
    /// Поле `bytes` из формата убрано: оно декодировалось и не читалось нигде.
    nonisolated struct Index: Decodable, Sendable {
        struct Meta: Decodable, Sendable {
            let sha256: String
        }
        let version: Int
        let tiles: [String: Meta]
    }

    /// Индекс живёт в одном экземпляре и читается из многих потоков сессии
    /// движка, поэтому — под замком, а не «просто переменная».
    private static let lock = OSAllocatedUnfairLock(initialState: TileDigestIndex?.none)

    static var isReady: Bool { lock.withLock { $0 != nil } }

    /// Где лежит разобранный индекс между запусками.
    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("mvt_index.bin")
    }
    private static var etagURL: URL { cacheURL.appendingPathExtension("etag") }

    /// Забрать и проверить индекс. Без него сторож не пропускает ни одного
    /// тайла — сознательно.
    ///
    /// Порядок такой, и он про память. `mvt_index.json` — 23,5 МБ и 165 054
    /// записи; полный разбор стоит около сотни мегабайт транзиентно (ответ,
    /// base64-строка из него, данные из неё, потом словарь). Раньше это
    /// повторялось НА КАЖДОМ запуске, включая тот, который делает подключение
    /// CarPlay, — и телеметрия показала 73 отстрела по памяти за сорок суток.
    ///
    /// Теперь: сперва условный запрос с прошлым ETag. Сервер отвечает 304 —
    /// берём разобранный индекс с диска и ни одного мегабайта не трогаем.
    /// Ответил 200 — значит индекс правда сменился, и только тогда платим
    /// полным разбором, один раз, с записью результата на диск.
    ///
    /// `@concurrent`: без него обычный `async` здесь выполнялся на акторе
    /// вызывающего — то есть на главном (EngineMapView зовёт из MainActor), и
    /// разбор 23,5 МБ с проверкой подписи и записью 6,6 МБ подвешивал экран на
    /// секунды (аудит 11.10). Всё состояние — под `lock`, главный ему не нужен.
    @concurrent static func prepare() async {
        if isReady { return }
        let url = AppConfig.syncBaseURL.appendingPathComponent("mvt_index.json")
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: ownRequest)
        // Кэш URLSession здесь НЕ помощник: на 304 он молча отдаёт тело из
        // своего хранилища, и мы снова получаем 23,5 МБ. Условие ставим сами,
        // чтобы увидеть именно код ответа.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let knownTag = try? String(contentsOf: etagURL, encoding: .utf8)
        if let knownTag, !knownTag.isEmpty {
            request.setValue(knownTag, forHTTPHeaderField: "If-None-Match")
        }

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            // Сети нет. Разобранный индекс с прошлого раза — законный запас:
            // он получен из проверенной подписи и лежит в песочнице приложения,
            // там же, где скачанная база камер.
            if loadCached() { return }
            log.error("индекс MVT не пришёл — карта на движке останется пустой")
            return
        }

        if http.statusCode == 304 {
            if loadCached() { return }
            // 304 есть, а разобранного индекса нет: метка пережила файл
            // (диск очистили, запись не удалась). Без этой ветки метка навсегда
            // запирала бы карту пустой — сервер отвечает «не менялось», брать
            // нечего, и следующий запуск повторял бы то же самое.
            try? FileManager.default.removeItem(at: etagURL)
            log.error("метка индекса MVT есть, разобранного файла нет — качаем заново")
            lock.withLock { $0 = nil }
            return await prepare()
        }

        guard http.statusCode == 200,
              let envelope = try? JSONDecoder().decode(SignedPayload<Index>.self, from: data),
              let parsed = envelope.verified()
        else {
            if loadCached() { return }
            log.error("индекс MVT не проверился — карта на движке останется пустой")
            return
        }

        let index = TileDigestIndex(version: parsed.version,
                                    tiles: parsed.tiles.mapValues(\.sha256))
        guard !index.isEmpty else {
            log.error("индекс MVT пуст после разбора — карта на движке останется пустой")
            return
        }
        lock.withLock { $0 = index }
        // Запись — уже после того, как индекс принят: даже если диск откажет,
        // текущий сеанс работает.
        try? index.serialized().write(to: cacheURL, options: .atomic)
        if let tag = http.value(forHTTPHeaderField: "ETag") {
            // Метка — только экономия трафика: не записалась — следующий запуск
            // просто скачает индекс целиком.
            try? tag.write(to: etagURL, atomically: true, encoding: .utf8)
        }
        log.info("индекс MVT принят: \(index.count, privacy: .public) тайлов, разобран заново")
    }

    /// Поднять разобранный индекс с диска. false — файла нет либо он негоден.
    private static func loadCached() -> Bool {
        guard let data = try? Data(contentsOf: cacheURL, options: .mappedIfSafe),
              let index = TileDigestIndex(serialized: data), !index.isEmpty else { return false }
        lock.withLock { $0 = index }
        log.info("индекс MVT взят с диска: \(index.count, privacy: .public) тайлов, разбор не понадобился")
        return true
    }

    /// Ключ тайла из адреса: .../mvt/15/22686/12246.mvt → «15/22686/12246».
    static func tileKey(for url: URL) -> String? {
        let parts = url.path.components(separatedBy: mvtPath)
        guard parts.count == 2 else { return nil }
        let tail = parts[1]
        guard tail.hasSuffix(".mvt") else { return nil }
        return String(tail.dropLast(4))
    }

    /// Есть ли тайл в подписанном индексе. Сам дайджест наружу не отдаётся —
    /// сравнение делает индекс, по байтам (см. `matches`).
    static func isSigned(_ url: URL) -> Bool {
        guard let key = tileKey(for: url) else { return false }
        return lock.withLock { $0?.contains(tileKey: key) ?? false }
    }

    /// Совпал ли sha256 скачанного тайла с подписанным.
    static func matches(_ url: URL, digest: some Collection<UInt8>) -> Bool {
        guard let key = tileKey(for: url) else { return false }
        return lock.withLock { $0?.matches(tileKey: key, digest: digest) ?? false }
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
        // Тайлы выпуска (/v/<N>/…) — и наши, и основа карты: основа тоже
        // проходит через подпись, иначе правило 19 кончалось бы на подложке.
        if TileRelease.parse(url) != nil {
            return url.pathExtension == "mvt" || url.pathExtension == "pbf"
        }
        return url.path.contains(mvtPath) && url.path.hasSuffix(".mvt")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return finish(with: URLError(.badURL)) }
        if let tile = TileRelease.parse(url) { return startRelease(tile, url: url) }
        guard Self.isSigned(url) else {
            // Тайла нет в индексе — либо индекс не пришёл, либо сервер отдаёт
            // то, чего владелец не подписывал. Оба случая — отказ.
            Self.log.error("тайл вне подписанного индекса: \(url.path, privacy: .public)")
            return finish(with: URLError(.userAuthenticationRequired))
        }
        let own = Self.guardRequest(from: request)
        loader = Self.session.dataTask(with: own) { [weak self] data, response, error in
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
            // Сравниваем БАЙТЫ. Прежде здесь на каждый тайл строилось
            // тридцать две строки через String(format:) и склеивалось в hex
            // только ради сравнения — а тайлов на экране сотни.
            // `SHA256Digest` — Sequence, а не Collection. `withUnsafeBytes`
            // даёт Collection<UInt8> поверх тех же тридцати двух байт и не
            // копирует их — ровно то, ради чего здесь ушли от hex-строк.
            let signed = SHA256.hash(data: data).withUnsafeBytes {
                Self.matches(url, digest: $0)
            }
            guard signed else {
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
        releaseTask?.cancel()
        releaseTask = nil
    }

    // MARK: - Тайл выпуска: корень → корзина → тайл

    private var releaseTask: Task<Void, Never>?

    /// Цепочка доверия выпуска (TileRelease): корень подписан, корзина сошлась
    /// с корнем, тайл — с корзиной. Корзины или тайла в ней нет — это пустая
    /// клетка (степь, чужая страна), отдаём пустой тайл, а не ошибку: иначе
    /// движок переспрашивал бы её на каждом кадре.
    private func startRelease(_ tile: TileRelease.Tile, url: URL) {
        // let, а не var: изменяемую переменную нельзя захватить в задачу,
        // которая идёт параллельно.
        let own = Self.guardRequest(from: request)
        releaseTask = Task { [weak self] in
            guard let release = TileReleaseStore.current, release.tile(at: url) == tile else {
                Self.log.error("тайл не из текущего выпуска: \(url.path, privacy: .public)")
                self?.finish(with: URLError(.userAuthenticationRequired))
                return
            }
            let bucket = await TileReleaseStore.shared.bucket(for: tile)
            guard let self, !Task.isCancelled else { return }
            guard bucket.exists else { return self.deliverEmpty(url) }
            guard let index = bucket.index else {
                return self.finish(with: URLError(.userAuthenticationRequired))
            }
            guard index.contains(tileKey: tile.key) else { return self.deliverEmpty(url) }
            do {
                let (data, response) = try await Self.session.data(for: own)
                guard !Task.isCancelled else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return self.finish(with: URLError(.badServerResponse))
                }
                let signed = SHA256.hash(data: data).withUnsafeBytes {
                    index.matches(tileKey: tile.key, digest: $0)
                }
                guard signed else {
                    Self.log.error("sha256 тайла выпуска не сошёлся: \(url.path, privacy: .public)")
                    return self.finish(with: URLError(.userAuthenticationRequired))
                }
                self.deliver(data: data, response: response)
            } catch {
                self.finish(with: error)
            }
        }
    }

    /// Свой запрос сторожа. Условные заголовки движка СНИМАЮТСЯ: движок
    /// переспрашивает протухший тайл с If-None-Match, сервер честно отвечает
    /// 304 без тела — а сторожу нечего хэшировать, и тайл объявлялся
    /// неподписанным. Через пять минут кэша (max-age=300 старых адресов)
    /// карта начинала терять тайлы. Сторож всегда берёт тело целиком: кэш —
    /// забота движка, проверка — наша.
    static func guardRequest(from request: URLRequest) -> URLRequest {
        var own = request
        own.setValue(nil, forHTTPHeaderField: "If-None-Match")
        own.setValue(nil, forHTTPHeaderField: "If-Modified-Since")
        own.setValue("1", forHTTPHeaderField: ownRequest)
        return own
    }

    private func deliverEmpty(_ url: URL) {
        let response: URLResponse = HTTPURLResponse(url: url, statusCode: 204, httpVersion: "HTTP/1.1",
                                       headerFields: nil) ?? URLResponse(url: url, mimeType: nil,
                                                                         expectedContentLength: 0,
                                                                         textEncodingName: nil)
        deliver(data: Data(), response: response)
    }

    /// Своя загрузка тайла. Имя не `task`: у URLProtocol такое свойство уже
    /// есть, и перекрыть его хранимым нельзя.
    private var loader: URLSessionDataTask?

    private func deliver(data: Data, response: URLResponse) {
        // .notAllowed: кэш тайлов — работа движка, а не URLCache.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func finish(with error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }
}
#endif
