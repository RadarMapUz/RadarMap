//
//  RoadWeatherService.swift
//  RadarMap
//
//  Погода на перевалах (19.2): файл сервера и одна спокойная фраза о нём.
//
//  Приём. Пока на приложение кто-то смотрит (экран телефона, машина) или
//  идёт поездка, weather/roads.json перечитывается раз в 30 минут с ETag —
//  неизменившийся файл стоит пустой 304, одно пробуждение радио на полчаса.
//  Разбор — вне главного потока. Файл старше двух часов — данных нет.
//
//  Решение — в чистом RoadWeatherAlert; здесь живые данные, «уже сказано в
//  этой поездке» и баннер (телефон и CarPlay читают один `banner`). Голос
//  звучит из LocationService — после камеры и никогда вместо неё.
//
//  Выключатели — «Погода на перевалах» в настройках и пульт
//  (`features.roadWeather`). На оповещения о камерах не влияет никак
//  (ARCHITECTURE.md, правило 20).
//

import CoreLocation
import Foundation
import Observation
import os

@MainActor
@Observable
final class RoadWeatherService {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    /// Показанное предупреждение: телефон — карточкой над картой, машина —
    /// баннером в общей очереди (ниже камеры и объезда).
    struct Banner: Equatable, Sendable {
        let id: Int
        let notice: RoadWeatherAlert.Notice
        let until: Date
    }

    private(set) var banner: Banner?
    /// Последний свежий набор; nil — нет данных, выключено или протухло.
    @ObservationIgnored private(set) var snapshot: RoadWeatherSnapshot?

    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var fetchedAt = Date.distantPast
    @ObservationIgnored private var failedAt = Date.distantPast
    /// О каких перевалах уже сказали в этой поездке (группы точек).
    @ObservationIgnored private var voiced: Set<String> = []
    @ObservationIgnored private var checkedAt: Date?
    /// Последнее решение — «подождать камеру»: тогда спрашиваем снова на
    /// каждом фиксе, как только камера позади, а не через `roadWeatherCheckSeconds`.
    @ObservationIgnored private var waitingForCamera = false
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var bannerSerial = 0

    private let api = APIClient()
    private let settings: AppSettings

    /// Пульт и сеть — замыканиями: живут в AppEnvironment и готовы только
    /// после его инициализации.
    @ObservationIgnored var allowedByConfig: () -> Bool = { true }
    @ObservationIgnored var isOnline: () -> Bool = { true }

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isEnabled: Bool { settings.roadWeatherAlerts && allowedByConfig() }

    // MARK: - Приём

    /// Пора ли за файлом (без сети). Когда смотрят или едут — ходит
    /// планировщик сети (NetScheduler, 36B), прицепом к такту отметок:
    /// файл меняется раз в полчаса, своё пробуждение радио ему не нужно.
    var isFetchDue: Bool { untilNextFetch(now: Date()) <= 0 }

    /// Выключено (настройка или пульт): забыть набор и баннер, без сети.
    func clearIfDisabled() {
        guard !isEnabled, snapshot != nil || banner != nil || etag != nil else { return }
        snapshot = nil
        etag = nil
        hideBanner()
    }

    /// Сколько ждать до следующей загрузки.
    private func untilNextFetch(now: Date) -> TimeInterval {
        let next = max(fetchedAt.addingTimeInterval(AppConfig.roadWeatherRefreshInterval),
                       failedAt.addingTimeInterval(AppConfig.roadWeatherRetrySeconds))
        return next.timeIntervalSince(now)
    }

    func refresh() async {
        let now = Date()
        guard isEnabled else {
            // Выключили — набор и баннер забываем, следующая загрузка — с нуля.
            snapshot = nil
            etag = nil
            fetchedAt = now
            hideBanner()
            return
        }
        if let current = snapshot, !current.isFresh(now: now) { snapshot = nil }
        guard isOnline() else {
            failedAt = now
            return
        }
        do {
            guard let fresh = try await Self.fetch(api: api, etag: etag) else {
                fetchedAt = now   // 304: тот же файл
                return
            }
            fetchedAt = now
            etag = fresh.etag
            guard let decoded = fresh.snapshot, decoded.isFresh(now: Date()) else {
                snapshot = nil
                Log.network.notice("погода на трассах: файл устарел или не того вида")
                return
            }
            snapshot = decoded
            let risky = decoded.points.filter { !$0.hazards(at: now).isEmpty }.map(\.id)
            Log.network.info("погода на трассах: точек \(decoded.points.count, privacy: .public), опасно \(risky.joined(separator: ","), privacy: .public)")
        } catch {
            failedAt = now
            Log.network.notice("погода на трассах не загрузилась: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Загрузка и разбор вне главного потока.
    @concurrent
    private static func fetch(api: APIClient, etag: String?) async throws
        -> (snapshot: RoadWeatherSnapshot?, etag: String?)? {
        guard let answer = try await api.getRawIfChanged("weather/roads.json", etag: etag) else { return nil }
        return (RoadWeatherSnapshot.decode(answer.data), answer.etag)
    }

    // MARK: - Поездка

    /// Новая поездка — о перевалах можно сказать снова.
    func tripStarted() {
        voiced.removeAll()
        checkedAt = nil
        waitingForCamera = false
    }

    func tripEnded() {
        waitingForCamera = false
        hideBanner()
    }

    /// Что сказать сейчас (и показать баннером) или nil. Зовёт LocationService
    /// на каждом фиксе поездки, поэтому путь тика дешёвый: без набора — сразу
    /// выход; гейт камеры и `situation` (линия маршрута на 70 км) — не чаще
    /// `roadWeatherCheckSeconds`. Пока ждём камеру — гейт на каждом фиксе,
    /// а решение — как только камера позади.
    func notice(cameraBusy: @autoclosure () -> Bool, now: Date = Date(),
                situation: () -> RoadWeatherAlert.Situation) -> RoadWeatherAlert.Notice? {
        guard let snapshot, isEnabled else { return nil }
        if !waitingForCamera, let checkedAt,
           now.timeIntervalSince(checkedAt) < AppConfig.roadWeatherCheckSeconds {
            return nil
        }
        let busy = cameraBusy()
        if waitingForCamera, busy { return nil }
        checkedAt = now
        switch RoadWeatherAlert.decide(snapshot: snapshot, situation: situation(), cameraBusy: busy,
                                       voiced: voiced, now: now) {
        case .silent:
            waitingForCamera = false
            return nil
        case .wait:
            waitingForCamera = true
            return nil
        case .announce(let notice):
            waitingForCamera = false
            voiced.insert(notice.key)
            show(notice, now: now)
            Log.alerts.notice("погода: \(notice.pointID, privacy: .public) \(notice.hazards.map(\.rawValue).joined(separator: "+"), privacy: .public), \(Int(notice.distance / 1000), privacy: .public) км\(notice.isLate ? " (поздно)" : "", privacy: .public)")
            return notice
        }
    }

    // MARK: - Баннер

    private func show(_ notice: RoadWeatherAlert.Notice, now: Date) {
        bannerSerial &+= 1
        let shown = Banner(id: bannerSerial, notice: notice,
                           until: now.addingTimeInterval(AppConfig.roadWeatherBannerSeconds))
        banner = shown
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            await Task.pause(seconds: AppConfig.roadWeatherBannerSeconds)
            guard !Task.isCancelled, let self, self.banner?.id == shown.id else { return }
            self.banner = nil
        }
    }

    /// Закрыли на телефоне (крестик) или поездка кончилась.
    func hideBanner() {
        bannerTask?.cancel()
        bannerTask = nil
        if banner != nil { banner = nil }
    }

    #if DEBUG
    /// Скриншот-хук `-demoRoadWeather`: баннер о тумане на Камчике без
    /// сервера и поездки — посмотреть телефон и машину.
    func seedDemo() {
        let notice = RoadWeatherAlert.Notice(
            key: "kamchik", pointID: "kamchik-tunnel", hazards: [.fog, .wind], distance: 32_000,
            name: .init(ru: "Перевал Камчик", uz: "Qamchiq dovoni"),
            place: .init(ru: "На перевале Камчик", uz: "Qamchiq dovonida"), isLate: false)
        bannerSerial &+= 1
        banner = Banner(id: bannerSerial, notice: notice, until: Date().addingTimeInterval(3600))
    }
    #endif
}
