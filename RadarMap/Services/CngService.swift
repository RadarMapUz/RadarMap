//
//  CngService.swift
//  RadarMap
//
//  Метан на АГНКС (12б.4): статусы станций с сервера и вопрос «Как на
//  заправке?». Правила — в CngRules; здесь сеть, память «уже спрашивали» и
//  постановка уведомления.
//
//  Только для машины на метане (Настройки → Поездка → «Машина»): остальным
//  статусы не нужны, и радио ради них не будится. Опрос — вместе с опросом
//  отметок водителей (onRadioAwake), не своим таймером. Файл заведений — с
//  диска, один раз на клетку за сессию: на каждом светофоре его не читаем и
//  ради вопроса в поездке не скачиваем (ревью 12б.4).
//

import Foundation
import CoreLocation
import os

@MainActor
@Observable
final class CngService {
    /// Ответ сервера и когда он пришёл: на экране — состаренный (CngRules.live).
    private var fetched: [CngStation] = []
    private var fetchedAt = Date.distantPast

    /// Станции на сейчас: статус старше 3 ч и очередь старше 45 мин сняты и
    /// без сети — «газ есть, 5 мин назад» вчерашним утром не показываем.
    var stations: [CngStation] { CngRules.live(fetched, fetchedAt: fetchedAt, now: Date()) }

    /// Станции для карты — только у АГНКС из своих файлов заведений
    /// (CngRules.onKnownVenues): сервер принимает отметку в любой точке, а
    /// пилюля на карте выглядит фактом о станции. Поиск и CarPlay сверяют
    /// со своим заведением сами (`station(for:)`) и берут `stations`.
    var mapStations: [CngStation] {
        _ = venueRevision   // прочитали клетку — карта пересчитывает
        return CngRules.onKnownVenues(stations, venues: Array(cellStations.values.joined()))
    }
    /// Растёт, когда с диска прочитана клетка заведений.
    private(set) var venueRevision = 0

    @ObservationIgnored private let api = APIClient()
    /// Тот же ротируемый раз в 30 дней идентификатор, что у отметок.
    @ObservationIgnored private let deviceID = Storage.anonymousID(.mobileDeviceID)
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var lastRefreshAt: Date = .distantPast
    /// О какой станции и когда спрашивали — 3 ч тишины на станцию. На диске:
    /// ответ кнопкой из уведомления поднимает приложение холодным, и без
    /// памяти оно спросило бы ещё раз у той же колонки.
    @ObservationIgnored private var askedAt: [String: Date] = CngService.loadAsked()
    /// Поставленный вопрос: станция и когда он прозвучит.
    @ObservationIgnored private var pending: (point: CLLocationCoordinate2D, key: String, fireAt: Date)?
    /// АГНКС клетки заведений — в памяти; клетки без файла — с отметкой времени.
    @ObservationIgnored private var cellStations: [String: [Venue]] = [:]
    @ObservationIgnored private var cellMisses: [String: Date] = [:]
    /// Клетки в чтении и кто ждёт их конца (вопрос у колонок).
    @ObservationIgnored private var loadingCells: [String: [() -> Void]] = [:]

    /// Пульт гасит краудсорс целиком — и метан с ним (MobileCameraService.isEnabled).
    @ObservationIgnored var crowdEnabled: () -> Bool = { true }
    /// Заведения клетки только с диска (RoadNetworkService.venueBook, allowDownload: false).
    @ObservationIgnored var venues: ((CLLocationCoordinate2D) async -> VenueBook?)?
    @ObservationIgnored weak var notifier: NotificationService?
    @ObservationIgnored weak var network: NetworkMonitor?

    init(settings: AppSettings) {
        self.settings = settings
    }

    nonisolated deinit {}

    /// Машина на метане и краудсорс не выключен.
    var isActive: Bool { settings.vehicleEnergy == .cng && crowdEnabled() }

    // MARK: - Статусы

    /// Зовётся, когда радио и так проснулось (опрос отметок): не чаще
    /// `cngPollSeconds`. Выключено — список пуст.
    func refreshIfDue(now: Date = Date()) {
        guard isActive else {
            if !fetched.isEmpty { fetched = [] }
            etag = nil
            return
        }
        guard now.timeIntervalSince(lastRefreshAt) >= AppConfig.cngPollSeconds,
              network?.isOnline ?? true else { return }
        lastRefreshAt = now
        Task { await refresh() }
    }

    private struct Response: Decodable { let stations: [CngStation] }

    func refresh() async {
        do {
            guard let answer = try await api.getIfChanged("api/cng", as: Response.self, etag: etag) else {
                fetchedAt = Date()   // 304: тот же список, но свежий на этот момент
                return
            }
            etag = answer.etag
            fetched = answer.value.stations
            fetchedAt = Date()
            // Карта рисует станции только у своих АГНКС — их клетки с диска.
            for station in fetched { loadCell(VenueBook.key(for: station.coordinate), around: station.coordinate) }
        } catch {
            Log.network.debug("метан: статусы не загрузились — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Статус для заведения из своего файла.
    func station(for point: CLLocationCoordinate2D) -> CngStation? {
        CngRules.station(for: point, in: stations)
    }

    #if DEBUG
    /// Скриншот-хук «По пути» (`-demoLongRoute`): статусы станций без сервера.
    func seedDemo(_ stations: [CngStation]) {
        fetched = stations
        fetchedAt = Date()
    }
    #endif

    // MARK: - Вопрос «Как на заправке?»

    /// Фикс или погасшая без фиксов скорость: тронулись — снять вопрос;
    /// встали у колонок АГНКС — поставить. Ни одного нового запроса GPS.
    func noteFix(_ here: CLLocationCoordinate2D, speedKmh: Double, now: Date = Date()) {
        guard isActive else { return }
        if let asked = pending {
            guard CngRules.shouldCancel(here: here, speedKmh: speedKmh, station: asked.point) else { return }
            pending = nil
            notifier?.cancelCngAsk()
            // Сняли до того, как вопрос прозвучал (светофор у станции, пробка
            // на проспекте) — станция не потрачена: у колонок спросим.
            if now < asked.fireAt {
                askedAt[asked.key] = nil
                saveAsked()
            }
            return
        }
        guard speedKmh >= 0, speedKmh < AppConfig.cngStandingKmh else { return }
        let cell = VenueBook.key(for: here)
        guard let venues = cellStations[cell] else {
            // Тот же момент заново, когда клетка прочитается: телефон в
            // кармане у колонки шлёт одну «стоим» — второго случая спросить
            // не будет.
            loadCell(cell, around: here) { [weak self] in self?.noteFix(here, speedKmh: speedKmh) }
            return
        }
        prune(now: now)
        guard let venue = CngRules.stationToAsk(here: here, speedKmh: speedKmh, venues: venues,
                                                askedAt: askedAt, now: now) else { return }
        let key = CngRules.stationKey(venue.point)
        askedAt[key] = now
        saveAsked()
        pending = (venue.point, key, now.addingTimeInterval(AppConfig.cngAskDelaySeconds))
        notifier?.scheduleCngAsk(station: venue.title, point: venue.point, after: AppConfig.cngAskDelaySeconds)
        Log.app.notice("метан: вопрос поставлен на стоянку у АГНКС")
    }

    /// АГНКС клетки — один раз за сессию и только с диска. Нет файла — не
    /// спрашиваем повторно полчаса. Нужны и вопросу у колонок, и карте
    /// (`mapStations`). `then` — после успешного чтения.
    private func loadCell(_ cell: String, around here: CLLocationCoordinate2D,
                          then: (() -> Void)? = nil) {
        let now = Date()
        guard cellStations[cell] == nil, let venues else { return }
        // Клетку уже читают (карта) — вопрос подождёт того же чтения, а не
        // потеряется.
        if loadingCells[cell] != nil {
            if let then { loadingCells[cell]?.append(then) }
            return
        }
        if let missed = cellMisses[cell], now.timeIntervalSince(missed) < AppConfig.cngCellRetrySeconds { return }
        loadingCells[cell] = then.map { [$0] } ?? []
        Task { [weak self] in
            let book = await venues(here)
            guard let self else { return }
            let waiting = self.loadingCells.removeValue(forKey: cell) ?? []
            if let book {
                self.cellStations[cell] = book.venues.filter { $0.kind == .cng }
                self.venueRevision &+= 1
                waiting.forEach { $0() }
            } else {
                self.cellMisses[cell] = Date()
            }
        }
    }

    /// Ответ из уведомления. Без ответа не уходит ничего — сюда не попадаем.
    func answer(_ answer: CngAnswer, point: CLLocationCoordinate2D) async {
        struct Response: Decodable { let ok: Bool? }
        pending = nil
        askedAt[CngRules.stationKey(point)] = Date()
        saveAsked()
        guard crowdEnabled() else { return }
        do {
            _ = try await api.post("api/cng", json: ["lat": point.latitude, "lon": point.longitude,
                                                     "kind": answer.rawValue, "device": deviceID],
                                   as: Response.self)
            lastRefreshAt = .distantPast   // свой ответ — сразу на карту
            await refresh()
        } catch {
            Log.network.error("метан: ответ не ушёл — \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Память «уже спрашивали»

    private func prune(now: Date) {
        let before = askedAt.count
        askedAt = askedAt.filter { now.timeIntervalSince($0.value) < AppConfig.cngAskCooldownSeconds }
        if askedAt.count != before { saveAsked() }
    }

    private func saveAsked() {
        do {
            Storage.set(try JSONEncoder().encode(askedAt), for: .cngAskedAt)
        } catch {
            Log.app.error("метан: память вопросов не записалась — \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadAsked() -> [String: Date] {
        guard let data = Storage.data(.cngAskedAt) else { return [:] }
        do {
            return try JSONDecoder().decode([String: Date].self, from: data)
        } catch {
            Log.app.error("метан: память вопросов не прочиталась — \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }
}
