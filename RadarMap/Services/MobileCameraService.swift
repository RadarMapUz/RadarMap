//
//  MobileCameraService.swift
//  RadarMap
//
//  Краудсорсинг передвижных радаров: пользователи отмечают радар на карте,
//  сервер объединяет отметки (TTL ~3 ч, продление подтверждениями, скрытие
//  дизлайками), приложение опрашивает список каждые 3 минуты на переднем плане.
//  Анонимность: случайный UUID устройства, никакой привязки к личности.
//

import Foundation
import os
import CoreLocation
import Observation

@MainActor
@Observable
final class MobileCameraService {
    enum ReportResult { case created, confirmed, amended, failed }

    private(set) var reports: [Camera] = []
    private(set) var isRefreshing = false

    @ObservationIgnored private weak var store: CameraStore?
    @ObservationIgnored private let api = APIClient()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Пульт: позволяет погасить краудсорс на сутки (волна фейковых отметок) или
    /// разредить опрос, не дожидаясь релиза. Без пульта — обычное поведение.
    @ObservationIgnored weak var config: RemoteConfigService?

    /// Анонимный идентификатор устройства для защиты от спама.
    @ObservationIgnored private let deviceID = Storage.anonymousID(.mobileDeviceID)

    /// Смещение id, чтобы передвижные не пересекались с базой (1…) и своими (1 000 001…).
    static let idOffset = 2_000_000

    init(store: CameraStore) {
        self.store = store
    }

    // MARK: - Опрос

    /// Интервал опроса: из пульта, если он прислан и вменяем, иначе из сборки.
    private var pollInterval: TimeInterval {
        config?.pollInterval ?? AppConfig.mobilePollInterval
    }

    /// Краудсорс целиком выключается пультом — на случай волны фейковых отметок.
    var isEnabled: Bool { config?.areMobileReportsEnabled ?? true }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Частые пары inactive→active (Face ID, шторка, переключатель
                // приложений) перезапускают цикл — интервал держим и между ними,
                // иначе каждый возврат в приложение будил бы радио лишним GET.
                guard let self else { return }
                let interval = self.pollInterval
                if !self.isEnabled {
                    self.clearAll()   // выключили краудсорс — убираем и то, что уже на карте
                } else if Date().timeIntervalSince(self.lastRefreshAt) >= interval {
                    await self.refresh()
                }
                await Task.pause(seconds: interval)
            }
        }
    }

    @ObservationIgnored private var lastRefreshAt: Date = .distantPast

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Убрать отметки с карты (пульт погасил краудсорс). Идемпотентно.
    private func clearAll() {
        guard !reports.isEmpty else { return }
        reports = []
        confirmations = [:]
        passTracks = [:]
        pendingConfirm = nil
        store?.setMobileCameras([])
    }

    private struct APIReport: Decodable {
        let id: Int
        let lat: Double
        let lon: Double
        let expires: Double
        let type: String?      // старый сервер поля не шлёт — трактуем как радар
        let up: Int?
        let created: Double?
        /// Подтверждена ли независимым водителем (другое устройство и адрес).
        /// Старый сервер поля не шлёт — nil трактуем как «подтверждена», чтобы
        /// не рисовать призраками всю карту до обновления сервера.
        let confirmed: Bool?
    }
    private struct MobileResponse: Decodable { let reports: [APIReport] }

    /// Подтверждения по отметке (для бейджа доверия в карточке).
    struct Confirmation {
        let upvotes: Int
        let created: Date
        /// false — точка на испытательном сроке, её ещё никто не подтвердил.
        let confirmed: Bool
    }
    @ObservationIgnored private var confirmations: [Int: Confirmation] = [:]

    func confirmation(for cameraID: Int) -> Confirmation? { confirmations[cameraID] }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastRefreshAt = Date()   // считаем попытку, не успех — при ошибке сети не долбим сервер
        do {
            let decoded = try await api.get("api/mobile", as: MobileResponse.self)
            var fresh: [Int: Confirmation] = [:]
            reports = decoded.reports.map { report in
                let kind = ReportKind(rawValue: report.type ?? "") ?? .radar
                let id = Self.idOffset + report.id
                fresh[id] = Confirmation(upvotes: report.up ?? 0,
                                         created: Date(timeIntervalSince1970: report.created ?? 0),
                                         confirmed: report.confirmed ?? true)
                return Camera(
                    id: id,
                    region: kind.cameraType.displayName,
                    city: "",
                    location: String(format: String(localized: "Отмечен водителями, исчезнет ~%@"),
                                     Self.expiryText(report.expires)),
                    lat: report.lat,
                    lon: report.lon,
                    type: kind.cameraType.sourceString,
                    violations: Camera.defaultViolations(forType: kind.cameraType.sourceString),
                    needsReview: nil,
                    mobileConfirmed: report.confirmed ?? true
                )
            }
            confirmations = fresh
            store?.setMobileCameras(reports)
        } catch {
            // сети нет — молча живём на последнем известном списке
        }
    }

    // MARK: - Отметка и голосование

    func report(at coordinate: CLLocationCoordinate2D,
                kind: ReportKind = .radar) async -> ReportResult {
        struct Response: Decodable { let id: Int; let merged: Bool; let amended: Bool? }
        // Краудсорс погашен пультом — отправлять некуда, и честнее сказать это
        // сразу, чем ждать таймаута сети.
        guard isEnabled else { return .failed }
        do {
            let payload = ["lat": coordinate.latitude, "lon": coordinate.longitude,
                           "device": deviceID, "type": kind.rawValue] as [String: Any]
            let response = try await api.post("api/report", json: payload, as: Response.self)
            lastSent = ReportGuard.Sent(kind: kind, latitude: coordinate.latitude,
                                        longitude: coordinate.longitude, at: Date())
            await refresh()
            // amended: сервер счёл это уточнением типа СВОЕЙ свежей отметки
            // (другой тип в 400 м / 10 мин) и переписал её, а не создал вторую.
            if response.amended == true { return .amended }
            return response.merged ? .confirmed : .created
        } catch {
            // Пользователь увидит «не удалось» — причина (таймаут/4xx) обязана
            // дойти хотя бы до Console: это главный краудсорс-путь приложения.
            Log.network.error("отметка радара не ушла: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    // MARK: - Кнопка «Радар!» за рулём

    /// Последняя ушедшая отметка — только в памяти сессии: защита от дублей
    /// нужна на протяжении поездки, а не между запусками.
    @ObservationIgnored private(set) var lastSent: ReportGuard.Sent?

    /// Итог одного тапа по кнопке в поездке: что сказать вслух и показать.
    enum QuickOutcome {
        case sent(ReportResult)
        case refused(ReportGuard.Refusal)

        /// Фраза голосом. За рулём на экран не смотрят — ответ обязан звучать,
        /// иначе непонятно, ушло или нет, и человек жмёт ещё раз.
        var spoken: String {
            switch self {
            case .sent(.created):   return String(localized: "Принято, спасибо")
            case .sent(.confirmed): return String(localized: "Подтвердили, спасибо")
            case .sent(.amended):   return String(localized: "Тип уточнён")
            case .sent(.failed):    return String(localized: "Не отправилось, нет связи")
            case .refused(.duplicate):  return String(localized: "Уже отметили здесь")
            case .refused(.noPosition): return String(localized: "Ждём спутники")
            case .refused(.notDriving): return String(localized: "Отметка ставится в движении")
            }
        }

        var isSuccess: Bool {
            if case .sent(let result) = self { return result != .failed }
            return false
        }
    }

    /// Один тап: проверить, отправить, ответить. Вся кнопка «Радар!» — здесь,
    /// чтобы телефон, CarPlay и Siri вели себя одинаково.
    func quickReport(kind: ReportKind = .radar,
                     coordinate: CLLocationCoordinate2D?,
                     speedKmh: Double,
                     isTripActive: Bool) async -> QuickOutcome {
        if let refusal = ReportGuard.check(kind: kind, coordinate: coordinate,
                                           speedKmh: speedKmh, isTripActive: isTripActive,
                                           lastSent: lastSent, now: Date()) {
            return .refused(refusal)
        }
        guard let coordinate else { return .refused(.noPosition) }
        let result = await report(at: coordinate, kind: kind)
        // Окно уточнения типа — только для СВОЕЙ свежесозданной точки:
        // merged-точка чужая, и «уточнение» родило бы рядом вторую сущность.
        if kind == .radar, result == .created {
            refineOffer = lastSent
        }
        return .sent(result)
    }

    // MARK: - «Что это было?» после быстрой отметки

    /// Предложение уточнить тип только что созданной отметки. Показывается
    /// несколько секунд (AppConfig.reportRefineSeconds); молчание оставляет
    /// «радар» — он покрывает почти все случаи.
    private(set) var refineOffer: ReportGuard.Sent?

    func dismissRefine() { refineOffer = nil }

    /// Второй тап: «это была тренога/пост/ДТП». Сервер переписывает тип ТОЙ ЖЕ
    /// точки (amend) — новая не создаётся, срок жизни не продлевается.
    func refine(to kind: ReportKind, offer: ReportGuard.Sent) async -> Bool {
        struct Response: Decodable { let id: Int; let merged: Bool; let amended: Bool? }
        guard isEnabled else { return false }
        do {
            let payload = ["lat": offer.latitude, "lon": offer.longitude,
                           "device": deviceID, "type": kind.rawValue] as [String: Any]
            let response = try await api.post("api/report", json: payload, as: Response.self)
            // Дубль-гейту важен итоговый тип, а время оставляем исходное:
            // окно «а вдруг не нажалось» считается от первого тапа.
            lastSent = ReportGuard.Sent(kind: kind, latitude: offer.latitude,
                                        longitude: offer.longitude, at: offer.at)
            await refresh()
            return response.amended == true || response.merged
        } catch {
            Log.network.error("уточнение типа не ушло: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - «Радар ещё стоит?» после проезда

    /// Точка, о которой уместно спросить прямо сейчас. nil — спрашивать нечего.
    /// Ставится, только когда водитель прошёл вплотную и уже отъехал.
    private(set) var pendingConfirm: Camera?

    @ObservationIgnored private var passTracks: [Int: MobilePassWatch.Track] = [:]

    /// Тик положения: обновить наблюдение за передвижными точками.
    /// Дёргается с карты — там же, где показывается вопрос.
    func trackPasses(from coordinate: CLLocationCoordinate2D) {
        guard isEnabled, pendingConfirm == nil else { return }
        guard let askID = MobilePassWatch.update(tracks: &passTracks,
                                                 mobileCameras: reports,
                                                 from: coordinate) else { return }
        pendingConfirm = reports.first { $0.id == askID }
    }

    /// Ответили. `nil` — закрыли/промолчали: не шлём ничего, потому что
    /// «не знаю» испортит данные сильнее, чем их отсутствие.
    func answerConfirm(stillThere: Bool?) {
        guard let camera = pendingConfirm else { return }
        pendingConfirm = nil
        guard let stillThere else { return }
        // origin="pass" — голос после реального проезда: сервер хранит пометку,
        // модератор в админке отличает его от тапа в карточке с дивана.
        Task { await vote(cameraID: camera.id, stillThere: stillThere, origin: "pass") }
    }

    /// value: true = «радар на месте» (продлевает жизнь), false = «радара нет».
    /// `origin` — происхождение голоса ("pass" — после проезда), уходит серверу.
    func vote(cameraID: Int, stillThere: Bool, origin: String = "") async {
        struct Response: Decodable { let ok: Bool }
        var payload = ["id": cameraID - Self.idOffset, "device": deviceID,
                       "value": stillThere ? 1 : -1] as [String: Any]
        if !origin.isEmpty { payload["kind"] = origin }
        // Голос — best-effort: не дошёл — не страшно, сервер дедуплицирует повторы.
        let _: Response? = try? await api.post("api/vote", json: payload, as: Response.self)
        await refresh()
    }

    func isMobile(_ camera: Camera) -> Bool { camera.id >= Self.idOffset }

    // MARK: - Внутреннее

    private static func expiryText(_ expires: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: expires)
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// Тип отметки водителя: у каждого свой вид на карте и время жизни на сервере
/// (радар/тренога — часы, пост стоит дольше, ДТП рассасывается за час).
enum ReportKind: String, CaseIterable, Identifiable {
    case radar, tripod, post, accident
    var id: String { rawValue }

    var cameraType: CameraType {
        switch self {
        case .radar:    return .mobileRadar
        case .tripod:   return .tripod
        case .post:     return .dpsPost
        case .accident: return .accident
        }
    }
    var title: String { cameraType.displayName }
    var symbol: String { cameraType.symbolName }
}
