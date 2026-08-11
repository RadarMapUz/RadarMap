//
//  MobileCameraService.swift
//  RadarMap
//
//  Краудсорсинг передвижных радаров: пользователи отмечают радар на карте,
//  сервер объединяет отметки (TTL ~3 ч, продление подтверждениями, скрытие
//  дизлайками), приложение опрашивает список каждые 3 минуты на переднем плане
//  и каждые 75 секунд в поездке — включая погашенный экран, потому что именно
//  тогда чужая отметка и должна доехать до водителя (см. setTripActive).
//  Анонимность: случайный UUID устройства, никакой привязки к личности. Своё
//  положение телефон серверу НЕ сообщает: забирает все живые отметки (их
//  единицы на страну) и решает сам, что из них по пути.
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

    /// Дорожная сеть для снапа отметки на ось. Слабая ссылка: сервис отметок
    /// живёт дольше тайлов и обязан работать, когда их нет вовсе.
    @ObservationIgnored weak var roads: RoadNetworkService?
    /// Связь. Отметка, не ушедшая из-за сети, ждёт её возврата.
    @ObservationIgnored weak var network: NetworkMonitor?

    /// Смещение id, чтобы передвижные не пересекались с базой (1…) и своими (1 000 001…).
    static let idOffset = 2_000_000

    init(store: CameraStore) {
        self.store = store
    }

    // MARK: - Опрос

    /// Идёт ли поездка. Меняет две вещи: опрос учащается и продолжается с
    /// погашенным экраном — именно за рулём чужая отметка и нужна.
    @ObservationIgnored private(set) var isTripActive = false

    /// Интервал опроса: из пульта, если он прислан и вменяем, иначе из сборки.
    /// В поездке — чаще, но пульт остаётся главнее: если он СПЕЦИАЛЬНО разредил
    /// опрос (значение больше сборочного), это защита сервера от наплыва, и
    /// обходить её поездкой нельзя.
    private var pollInterval: TimeInterval {
        let baseline = config?.pollInterval ?? AppConfig.mobilePollInterval
        guard isTripActive, baseline <= AppConfig.mobilePollInterval else { return baseline }
        return AppConfig.mobilePollIntervalTrip
    }

    /// Ставит LocationService на старте и финише поездки (через AppEnvironment).
    func setTripActive(_ active: Bool) {
        guard active != isTripActive else { return }
        isTripActive = active
        // Цикл спит с прежним интервалом — пересоздаём, иначе учащение начнётся
        // только через три минуты, то есть к середине первой поездки.
        if pollTask != nil {
            stopPolling()
            startPolling()
        }
        if active {
            startPolling()
            // Отметка, сделанная кем-то пару минут назад, актуальна прямо
            // сейчас — стартовать поездку со списком получасовой давности
            // означает пропустить ровно тот случай, ради которого всё это.
            Task { await refresh() }
        }
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
                    // Сначала досылаем накопленное: чужая отметка подождёт
                    // секунду, своя ждала связи и может протухнуть.
                    await self.flushPending()
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
            for confirmed in reconcileMine(live: fresh) {
                onMyReportConfirmed?(confirmed)
            }
        } catch {
            // сети нет — молча живём на последнем известном списке
        }
    }

    // MARK: - Отметка и голосование

    /// Посадить отметку на ось дороги и заодно узнать её класс.
    ///
    /// Координата телефона — это место ВОДИТЕЛЯ в момент тапа, а не радара:
    /// на 90 км/ч время реакции уводит точку на два десятка метров назад, а на
    /// разделённой трассе она вообще ложится между полотнами. Дороги рядом нет
    /// — отправляем сырую координату: промолчать о радаре хуже, чем поставить
    /// его чуть мимо.
    private func placed(_ coordinate: CLLocationCoordinate2D,
                        course: Double) -> (CLLocationCoordinate2D, String) {
        guard let network = roads?.network else { return (coordinate, "") }
        let nearby = network.roads(near: coordinate,
                                   radius: AppConfig.reportSnapMaxMeters)
        guard let placement = ReportPlacement.snapped(coordinate, course: course,
                                                      roads: nearby,
                                                      maxMeters: AppConfig.reportSnapMaxMeters)
        else { return (coordinate, "") }
        return (placement.coordinate, placement.roadClass.osmValue)
    }

    func report(at coordinate: CLLocationCoordinate2D,
                kind: ReportKind = .radar,
                course: Double = -1) async -> ReportResult {
        // Краудсорс погашен пультом — отправлять некуда, и честнее сказать это
        // сразу, чем ждать таймаута сети.
        guard isEnabled else { return .failed }
        let (point, cls) = placed(coordinate, course: course)
        return await send(PendingReport(kind: kind.rawValue, lat: point.latitude,
                                        lon: point.longitude, cls: cls, at: Date()),
                          queueOnFailure: true)
    }

    /// Один POST. Общий путь для живой отметки и для отложенной — иначе
    /// очередь неминуемо разъедется с основным путём.
    @discardableResult
    private func send(_ item: PendingReport, queueOnFailure: Bool) async -> ReportResult {
        struct Response: Decodable { let id: Int; let merged: Bool; let amended: Bool? }
        let kind = ReportKind(rawValue: item.kind) ?? .radar
        do {
            var payload = ["lat": item.lat, "lon": item.lon,
                           "device": deviceID, "type": item.kind] as [String: Any]
            if !item.cls.isEmpty { payload["cls"] = item.cls }
            let response = try await api.post("api/report", json: payload, as: Response.self)
            lastSent = ReportGuard.Sent(kind: kind, latitude: item.lat,
                                        longitude: item.lon, at: item.at)
            lastSentID = response.id
            if response.merged != true { noteMine(id: response.id, item: item) }
            await refresh()
            // amended: сервер счёл это уточнением типа СВОЕЙ свежей отметки
            // (другой тип в 400 м / 10 мин) и переписал её, а не создал вторую.
            if response.amended == true { return .amended }
            return response.merged ? .confirmed : .created
        } catch {
            // Пользователь увидит «не удалось» — причина (таймаут/4xx) обязана
            // дойти хотя бы до Console: это главный краудсорс-путь приложения.
            Log.network.error("отметка радара не ушла: \(error.localizedDescription, privacy: .public)")
            if queueOnFailure {
                pending = ReportQueue.enqueued(item, into: pending)
                savePending()
            }
            return .failed
        }
    }

    // MARK: - Очередь без сети

    /// Отметки, ждущие связи. Треноги стоят ровно там, где её нет.
    @ObservationIgnored private var pending: [PendingReport] = Storage.decoded(
        [PendingReport].self, for: .pendingReports) ?? []

    private func savePending() { Storage.encode(pending, for: .pendingReports) }

    /// Отправить накопленное. Дёргается на каждом опросе: отдельного таймера
    /// очередь не заслуживает — она пуста в подавляющем большинстве запусков.
    func flushPending() async {
        guard isEnabled, !pending.isEmpty, network?.isOnline ?? true else { return }
        let (send, expired) = ReportQueue.split(pending, now: Date())
        if !expired.isEmpty {
            Log.network.notice("отметок протухло в очереди: \(expired.count, privacy: .public)")
        }
        pending = []
        savePending()
        for item in send {
            await self.send(item, queueOnFailure: true)
        }
    }

    /// Сколько отметок ждёт связи — для честной подписи в интерфейсе.
    var pendingCount: Int { pending.count }

    // MARK: - Свои отметки и их судьба

    /// Своя отметка: что поставил и чем это кончилось. Раньше автору не
    /// возвращалось ничего — ни «подтвердили», ни счётчика, — и человек не мог
    /// узнать, работает ли его тап вообще. В краудсорсе это главный (и
    /// единственный бесплатный) мотиватор, и его не было.
    struct MyReport: Codable, Equatable, Identifiable {
        let id: Int
        let kind: String
        let lat: Double
        let lon: Double
        let at: Date
        /// Подтверждена независимым водителем — узнаём из обычного /api/mobile.
        var confirmed = false
        /// О подтверждении уже сказали: второй раз радовать той же новостью
        /// незачем.
        var announced = false
        /// Отметка исчезла из живого списка: истекла или снята.
        var gone = false
    }

    @ObservationIgnored private(set) var mine: [MyReport] = Storage.decoded(
        [MyReport].self, for: .myReports) ?? []

    /// Свои отметки за окно — цифра для Итогов.
    func mineSummary(days: Int = 30, now: Date = Date()) -> (total: Int, confirmed: Int) {
        let since = now.addingTimeInterval(-Double(days) * 86400)
        let window = mine.filter { $0.at >= since }
        return (window.count, window.count { $0.confirmed })
    }

    private func noteMine(id: Int, item: PendingReport) {
        mine.append(MyReport(id: id, kind: item.kind, lat: item.lat,
                             lon: item.lon, at: item.at))
        trimMine()
        saveMine()
    }

    /// Своя история — не архив: держим окно, которое показываем, плюс запас.
    private func trimMine() {
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        mine = mine.filter { $0.at >= cutoff }.suffix(200).map { $0 }
    }

    private func saveMine() { Storage.encode(mine, for: .myReports) }

    /// Вызывается после каждого обновления списка: сверяем судьбу своих точек.
    /// Возвращает отметки, о подтверждении которых стоит сказать вслух —
    /// решение «говорить или нет» принимает вызывающий, у сервиса нет голоса.
    private func reconcileMine(live: [Int: Confirmation]) -> [MyReport] {
        var news: [MyReport] = []
        var changed = false
        for index in mine.indices {
            let id = Self.idOffset + mine[index].id
            guard let live = live[id] else {
                // Точки нет в живом списке — истекла или снята. Это не повод
                // грустить вслух, но и «ждёт подтверждения» показывать больше
                // нельзя.
                if !mine[index].gone { mine[index].gone = true; changed = true }
                continue
            }
            if mine[index].gone { mine[index].gone = false; changed = true }
            if live.confirmed, !mine[index].confirmed {
                mine[index].confirmed = true
                changed = true
                if !mine[index].announced {
                    mine[index].announced = true
                    news.append(mine[index])
                }
            }
        }
        if changed { saveMine() }
        return news
    }

    /// «Вашу отметку подтвердил другой водитель» — сказать это некому, кроме
    /// вызывающего: сервис отметок не владеет ни голосом, ни уведомлениями.
    @ObservationIgnored var onMyReportConfirmed: ((MyReport) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onMyReportConfirmed,
                                               "MobileCameraService.onMyReportConfirmed") }
    }

    // MARK: - Кнопка «Радар!» за рулём

    /// Последняя ушедшая отметка — только в памяти сессии: защита от дублей
    /// нужна на протяжении поездки, а не между запусками.
    @ObservationIgnored private(set) var lastSent: ReportGuard.Sent?
    /// Серверный id последней созданной отметки — по нему её и отзывают.
    @ObservationIgnored private(set) var lastSentID: Int?

    /// Итог одного тапа по кнопке в поездке: что сказать вслух и показать.
    enum QuickOutcome {
        case sent(ReportResult)
        case refused(ReportGuard.Refusal)
        /// Нет связи — отметка ждёт её в очереди, а не потеряна.
        case queued

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
            case .queued: return String(localized: "Нет связи, отправлю позже")
            }
        }

        var isSuccess: Bool {
            if case .queued = self { return true }   // тап принят, дело за сетью
            if case .sent(let result) = self { return result != .failed }
            return false
        }
    }

    /// Один тап: проверить, отправить, ответить. Вся кнопка «Радар!» — здесь,
    /// чтобы телефон, CarPlay и Siri вели себя одинаково.
    func quickReport(kind: ReportKind = .radar,
                     coordinate: CLLocationCoordinate2D?,
                     speedKmh: Double,
                     isTripActive: Bool,
                     course: Double = -1) async -> QuickOutcome {
        if let refusal = ReportGuard.check(kind: kind, coordinate: coordinate,
                                           speedKmh: speedKmh, isTripActive: isTripActive,
                                           lastSent: lastSent, now: Date()) {
            return .refused(refusal)
        }
        guard let coordinate else { return .refused(.noPosition) }
        let result = await report(at: coordinate, kind: kind, course: course)
        // Сеть подвела, но тап не пропал: отметка легла в очередь и уйдёт, как
        // только связь вернётся, — если не протухнет раньше.
        if result == .failed, pendingCount > 0 { return .queued }
        // Считаем только созданную отметку, и только здесь: уточнение типа
        // (refine) переписывает ту же точку и второй отметкой не является.
        onReportSent?()
        // Окно уточнения типа — только для СВОЕЙ свежесозданной точки:
        // merged-точка чужая, и «уточнение» родило бы рядом вторую сущность.
        if kind == .radar, result == .created {
            refineOffer = lastSent
        }
        return .sent(result)
    }

    // MARK: - «Что это было?» после быстрой отметки

    /// Водитель отметил радар — дневной счётчик воронки. Хук, а не прямая
    /// ссылка на статистику: сервис отметок о ней знать не должен.
    @ObservationIgnored var onReportSent: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onReportSent,
                                               "MobileCameraService.onReportSent") }
    }

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

    // MARK: - Отзыв своей отметки

    /// Можно ли ещё отозвать последнюю отметку. Окно то же, что у уточнения
    /// типа: это исправление промаха пальцем, а не право распоряжаться точкой.
    func cancellableReportID(now: Date = Date()) -> Int? {
        guard let id = lastSentID, let sent = lastSent,
              now.timeIntervalSince(sent.at) <= AppConfig.reportCancelWindow else { return nil }
        // Точку, которую уже подтвердил кто-то ещё, автор не снимает — сервер
        // откажет, и незачем показывать кнопку, которая не сработает.
        if let confirmation = confirmations[Self.idOffset + id], confirmation.upvotes > 0 {
            return nil
        }
        return id
    }

    /// Убрать свою отметку с карты. `true` — её там больше нет.
    func cancelReport(id: Int) async -> Bool {
        struct Response: Decodable { let ok: Bool? }
        do {
            let payload = ["id": id, "device": deviceID] as [String: Any]
            let response = try await api.post("api/report/cancel", json: payload,
                                              as: Response.self)
            guard response.ok == true else { return false }
            mine.removeAll { $0.id == id }
            saveMine()
            if lastSentID == id { lastSentID = nil; lastSent = nil }
            refineOffer = nil
            await refresh()
            return true
        } catch {
            Log.network.error("отметку не удалось отозвать: \(error.localizedDescription, privacy: .public)")
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

    /// Серверный id отметки в нумерации камер приложения — чтобы вью могла
    /// сравнить «моя ли это точка» без знания про смещение.
    func idOffsetApplied(_ serverID: Int) -> Int { Self.idOffset + serverID }

    #if DEBUG
    /// Скриншот-хук `-demoMobileTrust`: подтверждённая отметка и призрак на
    /// испытательном сроке плюс окно «Что это было?» с «Отменить» — без сети и
    /// без настоящего POST в общую базу (фейк на проде увидят живые водители).
    func seedTrustDemo(near coordinate: CLLocationCoordinate2D) {
        func demo(_ id: Int, dLat: Double, dLon: Double, confirmed: Bool) -> Camera {
            Camera(id: Self.idOffset + id,
                   region: CameraType.mobileRadar.displayName, city: "",
                   location: String(format: String(localized: "Отмечен водителями, исчезнет ~%@"),
                                    Self.expiryText(Date().addingTimeInterval(3600).timeIntervalSince1970)),
                   lat: coordinate.latitude + dLat, lon: coordinate.longitude + dLon,
                   type: CameraType.mobileRadar.sourceString,
                   violations: Camera.defaultViolations(forType: CameraType.mobileRadar.sourceString),
                   needsReview: nil, mobileConfirmed: confirmed)
        }
        reports = [demo(900_001, dLat: 0.004, dLon: 0.0015, confirmed: true),
                   demo(900_002, dLat: 0.004, dLon: -0.0035, confirmed: false)]
        confirmations = [
            Self.idOffset + 900_001: Confirmation(upvotes: 3, created: Date(), confirmed: true),
            Self.idOffset + 900_002: Confirmation(upvotes: 0, created: Date(), confirmed: false),
        ]
        store?.setMobileCameras(reports)
        let sent = ReportGuard.Sent(kind: .radar, latitude: coordinate.latitude,
                                    longitude: coordinate.longitude, at: Date())
        lastSent = sent
        // Свежая своя отметка — иначе «Отменить» в панели не показать на
        // скриншотах, а именно её и надо смотреть глазами.
        lastSentID = 900_003
        refineOffer = sent
    }
    #endif

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

    /// Что предлагаем ставить рукой. `post` намеренно вне списка на первый
    /// релиз: App Review отдельно смотрит на приложения, показывающие посты
    /// контроля не из официальных источников (Guideline 1.4.4), и рисковать
    /// первой подачей ради типа, который покрывается «радаром», не стоит.
    /// Сам тип остаётся: старые отметки с сервера обязаны рисоваться, а
    /// вернуть его в интерфейс — одна строка.
    static var offered: [ReportKind] { [.radar, .tripod, .accident] }

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
