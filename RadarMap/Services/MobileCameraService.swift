//
//  MobileCameraService.swift
//  RadarMap
//
//  Краудсорсинг передвижных радаров: пользователи отмечают радар на карте,
//  сервер объединяет отметки (TTL ~3 ч, продление подтверждениями, скрытие
//  дизлайками), приложение опрашивает список тактом планировщика сети
//  (NetScheduler/SyncPlan, 36B): 150 с при открытом экране и 40/70/150 с по
//  скорости в поездке — включая погашенный экран, потому что именно тогда
//  чужая отметка и должна доехать до водителя (см. setTripActive).
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

    /// Снос — БЕЗ прыжка на актор, и это не стиль, а обход живого бага рантайма.
    ///
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor синтезирует isolated deinit
    /// каждому @MainActor-классу, даже когда своего deinit нет. Такой deinit
    /// уходит в swift_task_deinitOnExecutor, тот в синхронном кадре главного
    /// потока (текущей Task нет) заводит TaskLocal::StopLookupScope, а
    /// MarkerItem::create в рантайме iOS 26 берёт память у task-аллокатора
    /// БЕЗУСЛОВНО — при task == nullptr это статический слэб внутри
    /// libswift_Concurrency. Item::destroy потом зовёт free() по этому
    /// указателю: «pointer being freed was not allocated» → SIGABRT.
    ///
    /// Условия сходятся ровно там, где SwiftUI сносит вью с @State-моделью
    /// внутри GraphHost.runTransaction: там жива task-local привязка. В ветке
    /// main рантайма баг уже исправлен; до выхода такой iOS помогает одно —
    /// не синтезировать isolated deinit вовсе.
    nonisolated deinit {}
    /// Чем кончилась отправка отметки.
    ///
    /// У неудачи есть причина, и раньше она терялась: шесть разных исходов —
    /// выключенный пультом краудсорс, отсутствие сети, «слишком часто»,
    /// блокировка устройства, поломка сервера и нечитаемый ответ — сходились в
    /// одну фразу «Не отправилось, нет связи». Водитель слышал про связь, стоя
    /// под полной антенной, жал ещё раз и получал то же самое. Причина обязана
    /// доходить до него: от неё зависит, что делать дальше — повторить, подождать
    /// или не пытаться вовсе.
    enum ReportResult: Equatable {
        case created, confirmed, amended
        /// Своя отметка уже стоит здесь — сервер ничего не записал (82).
        case mine
        case failed(Failure)

        enum Failure: Equatable {
            /// Сети нет. Единственный случай, когда «нет связи» — правда.
            case offline
            /// Сервер просит не частить (429).
            case tooOften
            /// Отказано этому устройству или адресу (403).
            case refused
            /// Сервер сломан (5xx) — наша вина, не пользователя.
            case serverBroken
            /// Краудсорс погашен пультом: отправлять некуда.
            case disabled
            /// Ответ пришёл, но разобрать его не вышло.
            case badAnswer
            /// 409: уточнять или отзывать уже нечего — время вышло или точку
            /// подтвердили другие водители (она больше не только ваша).
            case tooLate

            /// Стоит ли класть отметку в очередь и обещать доставку.
            ///
            /// Только то, что чинится временем. Отказ сервера повтором не
            /// лечится, а очередь, копящая заведомо мёртвые отметки, однажды
            /// выстрелит залпом — и получит блокировку уже за дело.
            var isWorthRetrying: Bool {
                switch self {
                case .offline, .serverBroken: return true
                case .tooOften, .refused, .disabled, .badAnswer, .tooLate: return false
                }
            }

            /// Что сказать голосом. За рулём на экран не смотрят, и фраза —
            /// единственный способ понять, что делать дальше.
            var spoken: String {
                switch self {
                // Обещание «отправлю позже» здесь не звучит намеренно: его
                // даёт только `.queued`, то есть когда отметка ДЕЙСТВИТЕЛЬНО
                // легла в очередь. Пообещать доставку и не выполнить — хуже,
                // чем честное «не вышло»: водитель на обещание рассчитывает и
                // второй раз не отметит.
                case .offline:      return String(localized: "Нет связи")
                case .tooOften:     return String(localized: "Слишком часто, подождите минуту")
                case .refused:      return String(localized: "Сервер отклонил отметку")
                case .serverBroken: return String(localized: "Сервер не отвечает")
                case .disabled:     return String(localized: "Отметки сейчас выключены")
                case .badAnswer:    return String(localized: "Странный ответ сервера")
                case .tooLate:      return String(localized: "Уже нельзя изменить")
                }
            }
        }

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    private(set) var reports: [Camera] = []
    private(set) var isRefreshing = false
    /// Перекрытия и ремонт (12б.5) — свой список, не камеры: в CameraStore
    /// и в цепочку оповещений не попадают никогда.
    private(set) var roadEvents: [RoadEvent] = []
    /// Сервер знает перекрытия и ремонт (ответил на /api/road). До этого
    /// типы не предлагаются: старый сервер отвечает «bad type», и отметка
    /// водителя пропала бы с «не отправилось».
    private(set) var roadEventsSupported = false

    @ObservationIgnored private weak var store: CameraStore?
    @ObservationIgnored private let api = APIClient()
    /// Чтение списков отметок (api/mobile, api/road) — с корня ленты
    /// (DEBUG `-trafficBase`, иначе тот же сервер); отправка — через `api`.
    @ObservationIgnored private let feed = APIClient(base: AppConfig.trafficFeedBaseURL)
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

    /// Идёт ли поездка. Сам опрос ведёт планировщик сети (NetScheduler,
    /// 36B): в поездке он продолжается с погашенным экраном — именно за рулём
    /// чужая отметка и нужна; старт поездки — внеочередной опрос, потому что
    /// отметка, сделанная кем-то пару минут назад, актуальна прямо сейчас.
    @ObservationIgnored private(set) var isTripActive = false

    /// Ставит LocationService на старте и финише поездки (через AppEnvironment).
    func setTripActive(_ active: Bool) {
        isTripActive = active
    }

    /// Краудсорс целиком выключается пультом — на случай волны фейковых отметок.
    var isEnabled: Bool { config?.areMobileReportsEnabled ?? true }

    /// Такт планировщика: свежий список. true — получен (304 тоже), false —
    /// сбой: пауза службы. Своя очередь — отдельная попутная служба
    /// (`SyncPlan.Job.reports`): ей нужен и тот выход в сеть, где списка
    /// никто не ждёт (после поездки, телефон в кармане).
    func syncTick() async -> Bool {
        await refresh()
    }

    /// Пульт выключил краудсорс — убрать и то, что уже на карте (без сети).
    func applyDisabled() { clearAll() }

    /// Убрать отметки с карты (пульт погасил краудсорс). Идемпотентно.
    private func clearAll() {
        // Выключатель гасит и дорогу: проверка только камер оставляла
        // ремонт на карте, в голосе и в выборе маршрута навсегда (ревью 12б.5).
        if roadEventsSupported { roadEventsSupported = false }
        if !roadEvents.isEmpty { roadEvents = [] }
        roadConfirmations = [:]
        lastRoadETag = nil
        roadPassTracks = [:]
        if pendingRoadConfirm != nil { pendingRoadConfirm = nil }
        pendingRoadConfirmAt = nil
        guard !reports.isEmpty else { return }
        reports = []
        confirmations = [:]
        reportCourses = [:]
        expiryTask?.cancel()
        expiryTask = nil
        passTracks = [:]
        pendingConfirm = nil
        pendingConfirmAt = nil
        // Отпечаток обязан уйти вместе со списком: иначе на включении
        // краудсорса сервер честно ответит 304 («у тебя уже это есть»), а у нас
        // пусто — и карта осталась бы без чужих отметок до первого изменения
        // где-нибудь в стране.
        lastETag = nil
        store?.setMobileCameras([])
    }

    private struct APIReport: Decodable {
        let id: Int
        let lat: Double
        let lon: Double
        let expires: Double
        let type: String?      // старый сервер поля не шлёт — трактуем как радар
        /// Курс отметившего; < 0 или нет — неизвестен. В /api/mobile — с
        /// 02.11 (вопрос «ещё стоит?» только едущим в ту же сторону).
        let course: Double?
        let up: Int?
        let created: Double?
        /// Подтверждена ли независимым водителем (другое устройство и адрес).
        /// Старый сервер поля не шлёт — nil трактуем как «подтверждена», чтобы
        /// не рисовать призраками всю карту до обновления сервера.
        let confirmed: Bool?
        /// Число независимых подтверждений — только в /api/road (28.10).
        /// Старый сервер не шлёт: nil, и перекрытие на выбор пути не влияет.
        let confirmers: Int?
        /// Свежесть (пункт 82); старый сервер не шлёт — nil.
        let last_confirmed: Double?
        let trust: Int?
        let doubted: Int?
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
    /// Отпечаток последнего полученного списка — им же и спрашиваем дальше.
    /// Только в памяти сессии: на холодном старте честнее взять список целиком,
    /// чем поверить отпечатку, пережившему переустановку базы.
    @ObservationIgnored private var lastETag: String?
    @ObservationIgnored private var lastRoadETag: String?
    /// Подтверждения событий дороги — для сверки своих отметок.
    @ObservationIgnored private var roadConfirmations: [Int: Confirmation] = [:]
    /// Расхождение часов с сервером по последнему полному ответу.
    @ObservationIgnored private var lastSkew: TimeInterval = 0

    /// Живые подтверждения обоих списков.
    private func liveConfirmations() -> [Int: Confirmation] {
        confirmations.merging(roadConfirmations) { camera, _ in camera }
    }

    func confirmation(for cameraID: Int) -> Confirmation? { confirmations[cameraID] }

    @discardableResult
    func refresh() async -> Bool {
        guard !isRefreshing else { return true }
        // Пульт погасил краудсорс — список не возвращаем на карту даже
        // после своей отметки или голоса (до окна планировщика — 150 с).
        guard isEnabled else { return true }
        // Связи нет — не будим радио впустую.
        //
        // Чужие отметки нужны в дороге, а дорога между городами — это как раз
        // часы без покрытия (ровно тот случай, ради которого заведён
        // NetworkMonitor: карта серая, а предупреждения работают). Попытка раз
        // в 40 секунд в мёртвую сеть не приносит ничего и стоит пробуждения
        // радио с ожиданием таймаута — до девяноста раз в час.
        //
        // Попытку при этом не считаем: как только связь вернётся, список
        // приедет в окне «связь вернулась», а не через интервал.
        // Отправка своих отметок эту проверку делает давно (flushPending),
        // опрос — не делал.
        guard network?.isOnline ?? true else { return false }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            guard let answer = try await feed.getIfChanged("api/mobile",
                                                          as: MobileResponse.self,
                                                          etag: lastETag) else {
                // 304: список тот же. Ни разбора, ни пересчёта окна камер —
                // ради этой ветки всё и затевалось. Но список дороги — свой:
                // новое перекрытие общий список не меняет, и без этого опроса
                // оно доходило бы до телефона, только когда где-то в стране
                // сменится радар (ревью 12б.5).
                await refreshRoadEvents(skew: lastSkew)
                for confirmed in reconcileMine(live: liveConfirmations()) {
                    onMyReportConfirmed?(confirmed)
                }
                await refreshImpactIfDue(recentDays: 2)
                return true
            }
            lastETag = answer.etag
            let decoded = answer.value
            // Сроки в ответе — по часам сервера. Часы телефона спешат на
            // десять минут — тренога «исчезала» на десять минут раньше, пока
            // ещё стоит (молчание), отстают — висела дольше (S31, 20.10).
            let skew = Self.clockSkew(serverDate: answer.serverDate, localNow: Date())
            lastSkew = skew
            var fresh: [Int: Confirmation] = [:]
            var courses: [Int: Double] = [:]
            // Перекрытие и ремонт в общем списке не приходят (у них свой) —
            // а пришли бы, камерой не становятся: это не засада, а дорога.
            reports = decoded.reports.filter { !(ReportKind(rawValue: $0.type ?? "")?.isRoadEvent ?? false) }
                .map { report in
                let kind = ReportKind(rawValue: report.type ?? "") ?? .radar
                let id = Self.idOffset + report.id
                if let course = report.course, course >= 0 { courses[id] = course }
                fresh[id] = Confirmation(upvotes: report.up ?? 0,
                                         created: Date(timeIntervalSince1970: (report.created ?? 0) + skew),
                                         confirmed: report.confirmed ?? true)
                return Camera(
                    id: id,
                    region: kind.cameraType.displayName,
                    city: "",
                    location: String(format: String(localized: "Отмечен водителями, исчезнет ~%@"),
                                     Self.expiryText(report.expires + skew)),
                    lat: report.lat,
                    lon: report.lon,
                    type: kind.cameraType.sourceString,
                    violations: Camera.defaultViolations(forType: kind.cameraType.sourceString),
                    needsReview: nil,
                    mobileConfirmed: report.confirmed ?? true,
                    mobileExpires: Date(timeIntervalSince1970: report.expires + skew),
                    mobileFresh: Self.freshness(report.created, report.last_confirmed, trust: report.trust,
                                                doubted: report.doubted, confirmed: report.confirmed, skew: skew)
                )
            }
            confirmations = fresh
            reportCourses = courses
            // Окно ближайших камер пересоберёт наблюдатель ревизии базы
            // (AppEnvironment.observeCameraRevision) — сразу, и без экрана.
            store?.setMobileCameras(reports)
            // Свои отметки сверяются с ОБОИМИ списками: своё «перекрыто»
            // живёт в списке дороги, и по одному списку камер оно числилось
            // бы пропавшим сразу после постановки.
            scheduleExpiry()
            await refreshRoadEvents(skew: skew)
            for confirmed in reconcileMine(live: liveConfirmations()) {
                onMyReportConfirmed?(confirmed)
            }
            await refreshImpactIfDue(recentDays: 2)
            return true
        } catch {
            // Сети нет или сервер не ответил — живём на последнем известном
            // списке (и снимаем истёкшее сами, pruneExpired).
            Log.network.notice("отметки водителей: опрос не удался — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Список дороги (GET /api/road). Старый сервер отвечает 404 — значит,
    /// перекрытий он не знает, и типы не предлагаются.
    private func refreshRoadEvents(skew: TimeInterval) async {
        do {
            guard let answer = try await feed.getIfChanged("api/road", as: MobileResponse.self,
                                                          etag: lastRoadETag) else {
                if !roadEventsSupported { roadEventsSupported = true }
                return
            }
            lastRoadETag = answer.etag
            if !roadEventsSupported { roadEventsSupported = true }
            let fresh = answer.value.reports.compactMap { report -> RoadEvent? in
                guard let kind = ReportKind(rawValue: report.type ?? "")?.roadEventKind else { return nil }
                return RoadEvent(id: Self.idOffset + report.id, kind: kind, lat: report.lat, lon: report.lon,
                                 course: report.course ?? -1,
                                 expires: Date(timeIntervalSince1970: report.expires + skew),
                                 confirmed: report.confirmed ?? true,
                                 confirmers: report.confirmers)
            }
            if fresh != roadEvents { roadEvents = fresh }
            // Событие сняли (кворум «нет», модератор, срок) — вопрос о нём
            // больше не нужен: «да» ушло бы в пустоту, «нет» — в мёртвую точку.
            if let asked = pendingRoadConfirm, !fresh.contains(where: { $0.id == asked.id }) {
                pendingRoadConfirm = nil
                pendingRoadConfirmAt = nil
            }
            roadConfirmations = Dictionary(uniqueKeysWithValues: answer.value.reports.map { report in
                (Self.idOffset + report.id,
                 Confirmation(upvotes: report.up ?? 0,
                              created: Date(timeIntervalSince1970: (report.created ?? 0) + skew),
                              confirmed: report.confirmed ?? true))
            })
        } catch {
            if roadEventsSupported { roadEventsSupported = false }
            Log.network.debug("события дороги недоступны: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Снять отметки, чей срок вышел. true — что-то сняли.
    @discardableResult
    func pruneExpired(now: Date) -> Bool {
        let expiries = Dictionary(uniqueKeysWithValues: reports.compactMap { camera in
            camera.mobileExpires.map { (camera.id, $0) }
        })
        let gone = Self.expired(expiries, now: now)
        // События дороги снимаются по сроку так же — без сервера.
        if roadEvents.contains(where: { $0.expires <= now }) {
            roadEvents.removeAll { $0.expires <= now }
        }
        if let asked = pendingRoadConfirm, asked.expires <= now {
            pendingRoadConfirm = nil
            pendingRoadConfirmAt = nil
        }
        guard !gone.isEmpty else { return false }
        reports.removeAll { gone.contains($0.id) }
        for id in gone {
            confirmations[id] = nil
            reportCourses[id] = nil
        }
        // «Радар ещё стоял?» о снятой отметке — не спрашиваем: «нет» голосовал
        // бы за истёкшую и возвращал её на сервере (ревью S5).
        if let asked = pendingConfirm, gone.contains(asked.id) {
            pendingConfirm = nil
            pendingConfirmAt = nil
        }
        store?.setMobileCameras(reports)
        refreshOwnFresh()
        scheduleExpiry()
        Log.network.notice("отметки водителей: сняты по сроку без сервера — \(gone.count, privacy: .public)")
        return true
    }

    // MARK: - Срок отметки — сразу, а не тактом сети

    /// Курсы отметивших по id отметки — для вопроса «ещё стоит?» (A10.4).
    @ObservationIgnored private var reportCourses: [Int: Double] = [:]

    /// Снятие по ближайшему сроку. Правило владельца (02.11): истёкшая
    /// тренога исчезает с карты и из голоса СРАЗУ. Такт сети (40–150 с) снимал
    /// её до двух с половиной минут после срока — на карте, в голосе и в
    /// баннере машины. Один таймер на ближайший срок, переставляется при
    /// каждом новом списке; батарее это одно пробуждение на отметку.
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    private func scheduleExpiry(now: Date = Date()) {
        expiryTask?.cancel()
        expiryTask = nil
        guard let next = Self.nextExpiry(reports.compactMap(\.mobileExpires), now: now) else { return }
        expiryTask = Task { [weak self] in
            // Ошибка sleep — только отмена задачи: таймер переставлен новым списком.
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSince(Date())) + 0.5))
            guard !Task.isCancelled, let self else { return }
            self.pruneExpired(now: Date())
        }
    }

    /// Ближайший срок впереди (чистая — под тестом). Уже прошедший — сразу.
    nonisolated static func nextExpiry(_ expiries: [Date], now: Date) -> Date? {
        expiries.min().map { max($0, now) }
    }

    /// Чьи сроки вышли (чистая функция — под тестом).
    nonisolated static func expired(_ expiries: [Int: Date], now: Date) -> Set<Int> {
        Set(expiries.compactMap { $0.value <= now ? $0.key : nil })
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
        guard let network = roads?.reportNetwork else { return (coordinate, "") }
        let nearby = network.roads(near: coordinate,
                                   radius: AppConfig.reportSnapMaxMeters)
        guard let placement = ReportPlacement.snapped(coordinate, course: course,
                                                      roads: nearby,
                                                      maxMeters: AppConfig.reportSnapMaxMeters)
        else { return (coordinate, "") }
        return (placement.coordinate, placement.roadClass.osmValue)
    }

    /// Приватный намеренно: снаружи есть ровно один вход — `quickReport`.
    /// Иначе очередной путь снова унесёт отметку мимо защиты от дублей.
    ///
    /// Координата приходит уже сдвинутой на время реакции — по своему треку
    /// от момента касания (ReportTrack, ReportFlow); здесь только посадка на
    /// ось: снап обязан работать по той точке, где объект стоит, а не по той,
    /// где о нём вспомнили. `touchedAt` — время касания: от него сервер
    /// считает срок жизни, а очередь — свежесть.
    private func report(at coordinate: CLLocationCoordinate2D,
                        kind: ReportKind,
                        course: Double,
                        touchedAt: Date) async -> ReportResult {
        // Краудсорс погашен пультом — отправлять некуда, и честнее сказать это
        // сразу, чем ждать таймаута сети.
        guard isEnabled else { return .failed(.disabled) }
        let (point, cls) = placed(coordinate, course: course)
        return await send(PendingReport(kind: kind.rawValue, lat: point.latitude,
                                        lon: point.longitude, cls: cls, at: touchedAt,
                                        course: course >= 0 ? course : nil),
                          live: true)
    }

    /// Один POST. Общий путь для живой отметки и для отложенной — иначе
    /// очередь неминуемо разъедется с основным путём. `live` — тап прямо
    /// сейчас: только он становится «последней отметкой» (уточнение, отзыв,
    /// защита от дублей) и только он ложится в очередь при сбое.
    @discardableResult
    private func send(_ item: PendingReport, live: Bool) async -> ReportResult {
        struct Response: Decodable { let id: Int; let merged: Bool; let amended: Bool?; let own: Bool? }
        let kind = ReportKind(rawValue: item.kind) ?? .radar
        do {
            // fresh: эта сборка уточняет только явно (amend_id) — тип из веера
            // сервер не примет за уточнение своей прошлой точки.
            var payload = ["lat": item.lat, "lon": item.lon, "device": deviceID,
                           "type": item.kind, "fresh": true] as [String: Any]
            // Из очереди — сколько секунд назад отметили: срок жизни точки
            // сервер считает от этого момента (S25). Старый сервер поле не читает.
            // Из очереди — всегда, с секунды: по моменту тапа сервер узнаёт
            // повтор уже принятой отметки (ответ потерялся) и отвечает её id.
            let age = Date().timeIntervalSince(item.at)
            if age >= (live ? 30 : 1) { payload["age"] = Int(age) }
            if !item.cls.isEmpty { payload["cls"] = item.cls }
            if let course = item.course { payload["course"] = (course * 10).rounded() / 10 }
            let response = try await api.post("api/report", json: payload, as: Response.self)
            let delivered = ReportGuard.Sent(kind: kind, latitude: item.lat, longitude: item.lon,
                                             at: item.at, serverID: response.id)
            lastSent = ReportGuard.lastAfterDelivery(current: lastSent, delivered: delivered, isLive: live)
            if live { lastSentID = response.id }
            if response.merged != true { noteMine(id: response.id, item: item) }
            // Маркеры — отдельно, не задерживая ответ: водитель ждёт «принято»
            // (голос, плашка, часы), а не второго запроса за картой — на
            // слабой связи он добавлял до 10 с, и часы успевали сказать «✕»
            // о доставленной отметке (ревью 9.3).
            Task { await self.refresh() }
            // amended: сервер счёл это уточнением типа СВОЕЙ свежей отметки
            // (другой тип в 400 м / 10 мин) и переписал её, а не создал вторую.
            if response.amended == true { return .amended }
            if response.own == true { return .mine }
            return response.merged ? .confirmed : .created
        } catch {
            // Пользователь увидит «не удалось» — причина (таймаут/4xx) обязана
            // дойти хотя бы до Console: это главный краудсорс-путь приложения.
            Log.network.error("отметка радара не ушла: \(error.localizedDescription, privacy: .public)")
            let failure = Self.failure(for: error)
            // В очередь кладём только то, что имеет смысл повторить. Отказ
            // сервера («слишком часто», блокировка) повтором не лечится, а
            // очередь, копящая заведомо мёртвые отметки, однажды выстрелит
            // залпом и получит блокировку уже за дело.
            // Уже протухшая (отмечена по треку часы назад) — в очередь не кладём:
            // «отправлю позже» было бы обещанием, которое очередь сама выбросит.
            if live, failure.isWorthRetrying, ReportQueue.split([item], now: Date()).expired.isEmpty {
                pending = ReportQueue.enqueued(item, into: pending)
                savePending()
            }
            return .failed(failure)
        }
    }

    /// Разложить ошибку сети на причину, понятную водителю.
    private static func failure(for error: Error) -> ReportResult.Failure {
        guard let failure = error as? APIClient.Failure else { return .offline }
        switch failure {
        case .transport:
            return .offline
        case .badStatus(let code):
            switch code {
            case 429:        return .tooOften
            case 401, 403:   return .refused
            case 409:        return .tooLate
            case 500...599:  return .serverBroken
            default:         return .badAnswer
            }
        }
    }

    // MARK: - Очередь без сети

    /// Отметки, ждущие связи. Треноги стоят ровно там, где её нет.
    /// Наблюдаемо: «Поездка сохранена» честно говорит, что ещё ждёт сети.
    private var pending: [PendingReport] = Storage.decoded(
        [PendingReport].self, for: .pendingReports) ?? []

    private func savePending() { Storage.encode(pending, for: .pendingReports) }

    /// Голоса, ждущие связи (VoteQueue).
    @ObservationIgnored private var pendingVotes: [PendingVote] = Storage.decoded(
        [PendingVote].self, for: .pendingVotes) ?? []

    private func savePendingVotes() { Storage.encode(pendingVotes, for: .pendingVotes) }

    /// Отметок протухло в очереди, а водителю ещё не сказали. «Отправлю
    /// позже» — обещание, и не выполненное оно не должно пропадать молча:
    /// водитель на него рассчитывал и второй раз не отметил.
    private(set) var undeliveredCount = Storage.int(.undeliveredReports)

    /// Сказали — счётчик в ноль.
    func acknowledgeUndelivered() {
        guard undeliveredCount != 0 else { return }
        undeliveredCount = 0
        Storage.set(0, for: .undeliveredReports)
    }

    /// Протухшие в очереди отметки — убрать и запомнить, без сети. Зовётся
    /// перед отправкой и в конце поездки: там итог говорит водителю правду.
    /// `notify: false` — вызывающий скажет сам (конец поездки).
    func dropExpiredPending(now: Date = Date(), notify: Bool = true) {
        let (_, expired) = ReportQueue.split(pending, now: now)
        let (_, staleVotes) = VoteQueue.split(pendingVotes, now: now)
        if !staleVotes.isEmpty {
            Log.network.notice("голосов протухло в очереди: \(staleVotes.count, privacy: .public)")
            pendingVotes.removeAll { staleVotes.contains($0) }
            savePendingVotes()
        }
        guard !expired.isEmpty else { return }
        Log.network.notice("отметок протухло в очереди: \(expired.count, privacy: .public)")
        pending.removeAll { expired.contains($0) }
        savePending()
        noteUndelivered(expired.count, notify: notify)
    }

    private func noteUndelivered(_ count: Int, notify: Bool = true) {
        undeliveredCount += count
        Storage.set(undeliveredCount, for: .undeliveredReports)
        if notify { onReportsUndelivered?(count) }
    }

    /// Отметки протухли в очереди — сказать водителю (уведомлением, если не
    /// в поездке и экран не открыт). Решает вызывающий: голоса у сервиса нет.
    @ObservationIgnored var onReportsUndelivered: ((Int) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onReportsUndelivered,
                                               "MobileCameraService.onReportsUndelivered") }
    }

    /// Срок попутной службы очереди (планировщик сети): есть что досылать.
    var isQueueDue: Bool { isEnabled && (!pending.isEmpty || !pendingVotes.isEmpty) }

    /// Отправить накопленное. Дёргается на каждом опросе: отдельного таймера
    /// очередь не заслуживает — она пуста в подавляющем большинстве запусков.
    /// Отметка уходит из очереди только ПОСЛЕ ответа: раньше очередь
    /// очищалась до отправки, и убитый посреди неё процесс терял все (S25).
    func flushPending() async {
        guard isEnabled, !pending.isEmpty || !pendingVotes.isEmpty,
              network?.isOnline ?? true, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        dropExpiredPending()
        while let item = pending.first {
            flushingAt = item.at
            let result = await send(item, live: false)
            flushingAt = nil
            // Сеть или сервер снова подвели — отметка остаётся, попробуем позже.
            if case .failed(let why) = result {
                if why.isWorthRetrying { return }
                // Отказ сервера (429, 403…) — отметка не ушла и уже не уйдёт:
                // обещание «отправлю позже» не выполнено, и молча оно не
                // пропадает (ловец багов, 40a).
                noteUndelivered(1)
            }
            // Дошла позже — в воронке это такая же отметка, как живая.
            if result == .created || result == .confirmed { onReportSent?() }
            // Ушла или отвергнута навсегда — из очереди (по ней самой: пока
            // ждали ответа, очередь могла сдвинуться).
            if let index = pending.firstIndex(of: item) { pending.remove(at: index) }
            savePending()
        }
        while let vote = pendingVotes.first {
            if let why = await postVote(vote), why.isWorthRetrying { return }
            if let index = pendingVotes.firstIndex(of: vote) { pendingVotes.remove(at: index) }
            savePendingVotes()
        }
    }

    @ObservationIgnored private var isFlushing = false

    /// Сколько отметок ждёт связи — для честной подписи в интерфейсе.
    var pendingCount: Int { pending.count }

    // MARK: - Свои отметки и их судьба

    /// Своя отметка: что поставил и чем это кончилось. Раньше автору не
    /// возвращалось ничего — ни «подтвердили», ни счётчика, — и человек не мог
    /// узнать, работает ли его тап вообще. В краудсорсе это главный (и
    /// единственный бесплатный) мотиватор, и его не было.
    struct MyReport: Codable, Equatable, Identifiable {
        let id: Int
        /// var: уточнение «Что это было?» переписывает тип той же точки.
        var kind: String
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
        /// Независимых подтверждений по словам сервера — наибольшее из
        /// увиденных (31E, ReportImpact). nil — сервер ещё не спрашивали;
        /// опционал — ради записей, уже лежащих на телефонах.
        var confirmers: Int? = nil
    }

    @ObservationIgnored private(set) var mine: [MyReport] = Storage.decoded(
        [MyReport].self, for: .myReports) ?? []

    // MARK: - Польза отметок (31E)

    /// Растёт, когда сервер сообщил новые подтверждения: `mine` вне
    /// наблюдения (пишется на каждом опросе), а строке «Итогов» нужно знать,
    /// что число изменилось.
    private(set) var impactRevision = 0
    @ObservationIgnored private var impactFetchedAt: Date?
    @ObservationIgnored private var isFetchingImpact = false

    private struct MineResponse: Decodable {
        struct Item: Decodable { let id: Int; let confirmers: Int }
        let reports: [Item]
    }

    /// «Ваши N отметок · M подтверждений» за 30 дней.
    func impactSummary(now: Date = Date()) -> ReportImpact.Summary {
        ReportImpact.summary(mine.map { ReportImpact.Report(at: $0.at, confirmers: $0.confirmers,
                                                            confirmed: $0.confirmed) },
                             now: now)
    }

    /// Спросить сервер о подтверждениях своих отметок, если пора.
    /// `recentDays` — насколько свежая своя отметка нужна: из опроса (радио и
    /// так проснулось) — только пока сервер ещё помнит отметку (2 дня), с
    /// экрана «Итогов» — за всё окно.
    func refreshImpactIfDue(recentDays: Int = AppConfig.reportImpactDays, now: Date = Date()) async {
        guard isEnabled, network?.isOnline ?? true, !isFetchingImpact,
              ReportImpact.isDue(lastFetch: impactFetchedAt, now: now, newest: mine.map(\.at).max(),
                                 days: recentDays) else { return }
        isFetchingImpact = true
        defer { isFetchingImpact = false }
        impactFetchedAt = now   // попытка, а не успех: сервер без эндпоинта не долбим
        do {
            // Только UUID: сервер отвечает по отметкам, которые этот UUID и
            // поставил, — ни координат, ни времени в ответе нет (server/api.py).
            let answer = try await api.post("api/mine", json: ["device": deviceID], as: MineResponse.self)
            let fetched = Dictionary(answer.reports.map { ($0.id, $0.confirmers) },
                                     uniquingKeysWith: { a, b in max(a, b) })
            var changed = false
            for index in mine.indices {
                let merged = ReportImpact.merged(known: mine[index].confirmers, fetched: fetched[mine[index].id])
                if merged != mine[index].confirmers {
                    mine[index].confirmers = merged
                    changed = true
                }
            }
            if changed {
                saveMine()
                impactRevision &+= 1
            }
        } catch {
            // Старый сервер (404) или нет сети — счётчик остаётся прежним.
            Log.network.notice("свои отметки: подтверждения не получены — \(error.localizedDescription, privacy: .public)")
        }
    }

    #if DEBUG
    /// Снимки «Итогов» (`-itogiDemo`): три свои отметки за неделю, две из них
    /// подтверждены другими водителями — в памяти, сервер не трогаем.
    func seedImpactDemo() {
        let now = Date()
        mine = [MyReport(id: 900_001, kind: "radar", lat: 41.311, lon: 69.279, at: now.addingTimeInterval(-86_400),
                         confirmed: true, announced: true, gone: true, confirmers: 3),
                MyReport(id: 900_002, kind: "tripod", lat: 41.32, lon: 69.25, at: now.addingTimeInterval(-3 * 86_400),
                         confirmed: true, announced: true, gone: true, confirmers: 1),
                MyReport(id: 900_003, kind: "radar", lat: 41.30, lon: 69.24, at: now.addingTimeInterval(-5 * 86_400),
                         gone: true)]
        impactFetchedAt = now
        impactRevision &+= 1
    }

    /// «Мало данных» (`-itogiDemoFew`): своих отметок нет — и с прошлых демо тоже.
    func clearImpactDemo() {
        mine = []
        saveMine()
        impactFetchedAt = Date()
        impactRevision &+= 1
    }
    #endif

    private func noteMine(id: Int, item: PendingReport) {
        // Повтор уже принятой отметки сервер отвечает её же id — второй раз
        // в «свои» она не ложится.
        guard !mine.contains(where: { $0.id == id }) else { return }
        mine.append(MyReport(id: id, kind: item.kind, lat: item.lat,
                             lon: item.lon, at: item.at))
        trimMine()
        saveMine()
        refreshOwnFresh()
    }

    /// Свои живые отметки (id карты) — рисуются без «?» (спецификация 02.11):
    /// водитель только что видел треногу сам, а карта рисовала её сомнением,
    /// как чужой слух. Только картинка — голос и запись проездов не меняются.
    private(set) var ownFreshIDs: Set<Int> = []

    private func refreshOwnFresh() {
        let ids = Set(mine.filter { !$0.gone }.map { Self.idOffset + $0.id })
        if ids != ownFreshIDs { ownFreshIDs = ids }
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
        if changed {
            saveMine()
            // «Подтвердили» в живом списке — тоже повод перерисовать «Итоги».
            impactRevision &+= 1
        }
        refreshOwnFresh()
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
        /// Не ушла — ждёт в очереди, а не потеряна; причина — для фразы: при
        /// 5xx связь есть, «нет связи» было бы неправдой (S25).
        case queued(ReportResult.Failure)

        /// Фраза голосом. За рулём на экран не смотрят — ответ обязан звучать,
        /// иначе непонятно, ушло или нет, и человек жмёт ещё раз.
        var spoken: String {
            switch self {
            case .sent(.created):   return String(localized: "Принято, спасибо")
            case .sent(.confirmed): return String(localized: "Подтвердили, спасибо")
            case .sent(.amended):   return String(localized: "Тип уточнён")
            case .sent(.mine):      return String(localized: "Уже отметили здесь")
            case .sent(.failed(let why)): return why.spoken
            case .refused(.duplicate):  return String(localized: "Уже отметили здесь")
            case .refused(.noPosition): return String(localized: "Ждём спутники")
            case .refused(.notDriving): return String(localized: "Отметка ставится в движении")
            case .queued(.serverBroken): return String(localized: "Сервер не отвечает, отправлю позже")
            case .queued: return String(localized: "Нет связи, отправлю позже")
            }
        }

        /// Голос после отметки: новая точка называет тип («Тренога отмечена»),
        /// очередь и отказы — прежними фразами, там важнее, что делать дальше.
        func spoken(for kind: ReportKind) -> String {
            if case .sent(.created) = self { return ReportWords.marked(kind) }
            return spoken
        }

        var isSuccess: Bool {
            if case .queued = self { return true }   // тап принят, дело за сетью
            if case .sent(let result) = self { return !result.isFailure }
            return false
        }

        /// Точка на карте есть: отправлена, ждёт сети или уже стояла (повтор
        /// на том же месте) — для ✓ там, где ответ виден без голоса.
        var pointExists: Bool {
            if case .refused(.duplicate) = self { return true }
            return isSuccess
        }
    }

    /// Одна отметка: проверить, отправить, ответить. Дверь для всех входов —
    /// черновика (ReportFlow: кнопка, машина, часы, плашка, Siri) и точки,
    /// показанной пальцем на карте.
    ///
    /// ЕДИНСТВЕННАЯ дверь наружу: `report(at:kind:course:)` приватный. Раньше
    /// три пути из шести — долгое нажатие на карте, прицел в «Ещё» и Siri —
    /// звали его напрямую и теряли по дороге всё сразу: защиту от дублей
    /// (пять отметок на один пост), дневной счётчик воронки и курс (без него
    /// посадка на ось дороги кладёт отметку на встречную полосу).
    ///
    /// `fix` — качество своей точки (`LocationService.reportFix`) в момент
    /// касания: слепая отметка по грубой, потерянной или давней точке — «Ждём
    /// спутники», а не «Принято» с засадой в сотнях метров от настоящей.
    /// `coordinate` слепой отметки уже сдвинута на время реакции
    /// (ReportTrack); `touchedAt` — момент касания, а не отправки.
    func quickReport(kind: ReportKind,
                     coordinate: CLLocationCoordinate2D?,
                     speedKmh: Double,
                     isTripActive: Bool,
                     placement: ReportGuard.Placement = .blind,
                     fix: ReportGuard.Fix?,
                     course: Double = -1,
                     touchedAt: Date = Date()) async -> QuickOutcome {
        // Одна отметка в полёте на все входы: черновик держит свою, а точка с
        // карты и досылка не должны пройти мимо — защита от дублей узнаёт об
        // отметке только после ответа, и второе нажатие уходило второй точкой.
        guard !isReporting else { return .refused(.duplicate) }
        if let refusal = ReportGuard.check(kind: kind, coordinate: coordinate,
                                           speedKmh: speedKmh, isTripActive: isTripActive,
                                           placement: placement, fix: fix,
                                           lastSent: lastSent, now: Date()) {
            return .refused(refusal)
        }
        guard let coordinate else { return .refused(.noPosition) }
        isReporting = true
        defer { isReporting = false }
        let result = await report(at: coordinate, kind: kind, course: course, touchedAt: touchedAt)
        // Сеть подвела, но отметка не пропала: она легла в очередь и уйдёт, как
        // только связь вернётся, — если не протухнет раньше.
        // «Отправлю позже» говорим, только если отметка ДЕЙСТВИТЕЛЬНО легла в
        // очередь. Отказ сервера туда не кладётся — обещать доставку было бы
        // враньём, а водитель на него рассчитывает и второй раз не отметит.
        if case .failed(let why) = result, why.isWorthRetrying,
           pending.contains(where: { $0.at == touchedAt }) { return .queued(why) }
        // Считаем только дошедшую отметку: отказ — не отметка. Из очереди её
        // посчитает flushPending, когда дойдёт.
        if result == .created || result == .confirmed { onReportSent?() }
        return .sent(result)
    }

    @ObservationIgnored private var isReporting = false

    /// Водитель отметил — дневной счётчик воронки. Хук, а не прямая
    /// ссылка на статистику: сервис отметок о ней знать не должен.
    @ObservationIgnored var onReportSent: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onReportSent,
                                               "MobileCameraService.onReportSent") }
    }

    /// Время касания отметки, которую досылка шлёт прямо сейчас.
    @ObservationIgnored private var flushingAt: Date?

    /// «Отменить» отметки, отложенной без сети. Ключ — время касания
    /// (`touchedAt`). nil — отметки нет (снята из очереди или отозвана на
    /// сервере); иначе причина.
    ///
    /// Три случая, и честный ответ у каждого свой (ревью 40b, Н4):
    /// - ждёт связи — убрать из очереди, не отправляя;
    /// - досылка уже в полёте — дождаться ответа: удалить запись из очереди
    ///   сейчас значит сказать «убрана», а запрос долетит, и тренога встанет у
    ///   всех; после ответа — отзыв по id;
    /// - уже ушла — отзыв по id своей точки (окно сервера 10 мин), а не «уже
    ///   нельзя изменить». Влилась в чужую — своей точки нет: тогда честный отказ.
    func cancelQueued(touchedAt: Date) async -> ReportResult.Failure? {
        var waited: TimeInterval = 0
        while flushingAt == touchedAt, waited < AppConfig.reportQueuedCancelWaitSeconds {
            await Task.pause(seconds: 0.2)
            waited += 0.2
        }
        if flushingAt != touchedAt, pending.contains(where: { $0.at == touchedAt }) {
            pending.removeAll { $0.at == touchedAt }
            savePending()
            if lastSent?.at == touchedAt { lastSent = nil }
            return nil
        }
        guard let own = mine.last(where: { $0.at == touchedAt }) else { return .tooLate }
        return await cancelReport(id: own.id)
    }

    // MARK: - Отзыв своей отметки

    /// Можно ли ещё отозвать последнюю отметку. Окно то же, что у уточнения
    /// типа: это исправление промаха пальцем, а не право распоряжаться точкой.
    func cancellableReportID(now: Date = Date()) -> Int? {
        guard let id = lastSentID, let sent = lastSent,
              now.timeIntervalSince(sent.at) <= AppConfig.reportCancelWindow else { return nil }
        // Точку, которую уже подтвердил кто-то ещё, автор не снимает — сервер
        // откажет, и незачем показывать кнопку, которая не сработает.
        if let confirmation = liveConfirmations()[Self.idOffset + id], confirmation.upvotes > 0 {
            return nil
        }
        return id
    }

    /// Убрать свою отметку с карты. nil — её там больше нет; иначе причина.
    @discardableResult
    func cancelReport(id: Int) async -> ReportResult.Failure? {
        struct Response: Decodable { let ok: Bool? }
        guard isEnabled else { return .disabled }
        do {
            let payload = ["id": id, "device": deviceID] as [String: Any]
            let response = try await api.post("api/report/cancel", json: payload,
                                              as: Response.self)
            guard response.ok == true else { return .badAnswer }
            mine.removeAll { $0.id == id }
            saveMine()
            if lastSentID == id { lastSentID = nil; lastSent = nil }
            refreshOwnFresh()
            await refresh()
            return nil
        } catch {
            Log.network.error("отметку не удалось отозвать: \(error.localizedDescription, privacy: .public)")
            return Self.failure(for: error)
        }
    }

    // MARK: - «Радар ещё стоит?» после проезда

    /// Точка, о которой уместно спросить прямо сейчас. nil — спрашивать нечего.
    /// Ставится, только когда водитель прошёл вплотную и уже отъехал.
    private(set) var pendingConfirm: Camera?
    /// Когда вопрос задан. Таймер «двадцать секунд и уйти» живёт в плашке, а
    /// плашки с погашенным экраном нет — без своего срока вопрос всплыл бы
    /// через час, про радар, мимо которого давно проехали, и до ответа
    /// заслонял бы все следующие.
    @ObservationIgnored private var pendingConfirmAt: Date?

    @ObservationIgnored private var passTracks: [Int: MobilePassWatch.Track] = [:]
    /// Наш курс, когда задан вопрос: ответ уходит с ним (встречный / попутный).
    @ObservationIgnored private var pendingConfirmCourse: CLLocationDegrees = -1

    /// Id своих отметок в пространстве карты (со сдвигом) — вопросы «ещё
    /// стоит?» о них не задаются.
    private var ownReportIDs: Set<Int> { Set(mine.map { Self.idOffset + $0.id }) }
    /// Соль выборки вопроса «ещё стоит?» (TripodAskPolicy) — постоянная на устройство.
    private var askSalt: Int { TripodAskPolicy.salt(from: deviceID) }
    /// О какой отметке вопрос уже прозвучал голосом — телефон и машина не повторяют.
    @ObservationIgnored var spokenQuestionID: Int?

    /// Тик положения: обновить наблюдение за передвижными точками.
    ///
    /// Зовётся на каждом принятом фиксе из LocationService (AppEnvironment),
    /// а НЕ с карты. С карты (MobilePassDriver) наблюдение жило только при
    /// включённом экране: в поездке с телефоном в кармане или под CarPlay без
    /// карты на телефоне проезд мимо треноги не замечался вовсе, и вопрос
    /// «радар ещё стоял?» — то, что держит данные свежими, — не задавался.
    /// `course` — наш курс (−1 — недостоверен): и событию дороги, и треноге
    /// нужен проезд в ту же сторону, что у отметившего (MobilePassWatch).
    func trackPasses(from coordinate: CLLocationCoordinate2D, course: CLLocationDegrees = -1,
                     now: Date = Date()) {
        expireStaleConfirm(now: now)
        guard isEnabled else { return }
        // Проезды отслеживаются и пока висит вопрос: с погашенным экраном он
        // висит до пяти минут, и без этого все отметки, мимо которых проехали
        // за это время, пропадали из наблюдения.
        // Свои отметки не спрашиваем — как у событий дороги.
        // Пока висит прежний вопрос, о следующей точке не спрашиваем — но и
        // не помечаем её «спрошенной»: иначе она терялась навсегда.
        let askID = MobilePassWatch.update(tracks: &passTracks,
                                           mobileCameras: reports,
                                           from: coordinate,
                                           course: course,
                                           courses: reportCourses,
                                           excluded: ownReportIDs.union(
                                               TripodAskPolicy.skipped(reports, now: now, salt: askSalt)),
                                           canAsk: pendingConfirm == nil,
                                           now: now)
        if pendingConfirm == nil, let askID {
            pendingConfirm = reports.first { $0.id == askID }
            pendingConfirmAt = pendingConfirm == nil ? nil : now
            pendingConfirmCourse = course
        }
        trackRoadPasses(from: coordinate, course: course, now: now)
    }

    /// Снять вопрос, который никто не увидел за `mobileConfirmMaxAgeSeconds`.
    /// Зовётся на фиксе И там, где вопрос показывают (плашка, CarPlay):
    /// открыли приложение после поездки — фиксов ещё нет, а вопрос про радар,
    /// мимо которого проехали час назад, показываться уже не должен.
    /// Молчание ничего не отправляет — как и «Пропустить».
    func expireStaleConfirm(now: Date = Date()) {
        if pendingRoadConfirm != nil, let at = pendingRoadConfirmAt,
           now.timeIntervalSince(at) > AppConfig.mobileConfirmMaxAgeSeconds {
            pendingRoadConfirm = nil
            pendingRoadConfirmAt = nil
        }
        guard pendingConfirm != nil, let at = pendingConfirmAt,
              now.timeIntervalSince(at) > AppConfig.mobileConfirmMaxAgeSeconds else { return }
        pendingConfirm = nil
        pendingConfirmAt = nil
    }

    /// Ответили. `nil` — закрыли/промолчали: не шлём ничего, потому что
    /// «не знаю» испортит данные сильнее, чем их отсутствие.
    /// `id` — о какой отметке был вопрос. Ответ на устаревший вопрос (его уже
    /// сменил другой) игнорируется: иначе «Нет» про отметку A уходило бы
    /// голосом против отметки B, о которой водителя не спрашивали.
    func answerConfirm(stillThere: Bool?, for id: Int? = nil) {
        guard let camera = pendingConfirm, id == nil || id == camera.id else { return }
        // Возраст ответа — от проезда, а не от тапа: вопрос мог ждать занятого
        // слота, а старое «стоит» сервер не продлевает (тренога — «сейчас»).
        let passedAt = passTracks[camera.id]?.departedAt ?? pendingConfirmAt ?? Date()
        let course = pendingConfirmCourse
        pendingConfirm = nil
        pendingConfirmAt = nil
        guard let stillThere else { return }
        // origin="pass" — голос после реального проезда: сервер хранит пометку,
        // модератор в админке отличает его от тапа в карточке с дивана.
        Task { await vote(cameraID: camera.id, stillThere: stillThere, origin: "pass",
                          observedAt: passedAt, course: course) }
    }

    // MARK: - «Ещё перекрыто?» после проезда события дороги

    /// Событие дороги, о котором уместно спросить. Свой слот, отдельно от
    /// радара: вопросы не вытесняют друг друга, а показывается сначала радар
    /// (`passQuestion`) — засада важнее асфальта.
    private(set) var pendingRoadConfirm: RoadEvent?
    /// Когда задан — тот же срок `mobileConfirmMaxAgeSeconds`, что у радара.
    @ObservationIgnored private var pendingRoadConfirmAt: Date?
    @ObservationIgnored private var roadPassTracks: [Int: RoadEventPassWatch.Track] = [:]

    private func trackRoadPasses(from coordinate: CLLocationCoordinate2D, course: CLLocationDegrees,
                                 now: Date) {
        guard !roadEvents.isEmpty || !roadPassTracks.isEmpty else { return }
        // Свои отметки не спрашиваем: отметивший только что видел сам.
        let askID = RoadEventPassWatch.update(tracks: &roadPassTracks, events: roadEvents,
                                              from: coordinate, course: course,
                                              excluded: ownReportIDs, now: now)
        guard pendingRoadConfirm == nil, let askID else { return }
        pendingRoadConfirm = roadEvents.first { $0.id == askID }
        pendingRoadConfirmAt = pendingRoadConfirm == nil ? nil : now
    }

    /// Ответили. `nil` — закрыли или промолчали: не шлём ничего. «Да» —
    /// лайк (подтверждает по тому же правилу независимого водителя, что у
    /// радара), «нет» — дизлайк: с разных адресов срезает срок и скрывает.
    /// `id` — о каком событии был вопрос; ответ на сменившийся игнорируется.
    func answerRoadConfirm(stillThere: Bool?, for id: Int? = nil) {
        guard let event = pendingRoadConfirm, id == nil || id == event.id else { return }
        let askedAt = pendingRoadConfirmAt ?? Date()
        pendingRoadConfirm = nil
        pendingRoadConfirmAt = nil
        guard let stillThere else { return }
        Task { await vote(cameraID: event.id, stillThere: stillThere, origin: "pass", observedAt: askedAt) }
    }

    /// Вопрос после проезда, как его показывают телефон и CarPlay: один за
    /// раз, радар первым.
    enum PassQuestion {
        case camera(Camera)
        case road(RoadEvent)

        var id: Int {
            switch self {
            case .camera(let camera): return camera.id
            case .road(let event):    return event.id
            }
        }
    }

    var passQuestion: PassQuestion? {
        if let pendingConfirm { return .camera(pendingConfirm) }
        if let pendingRoadConfirm { return .road(pendingRoadConfirm) }
        return nil
    }

    /// Ответ на `passQuestion` по id — кому бы он ни принадлежал. Id радаров
    /// и событий дороги из одной таблицы сервера и не пересекаются.
    func answerPassQuestion(stillThere: Bool?, for id: Int) {
        if pendingConfirm?.id == id {
            answerConfirm(stillThere: stillThere, for: id)
        } else if pendingRoadConfirm?.id == id {
            answerRoadConfirm(stillThere: stillThere, for: id)
        }
    }

    /// value: true = «радар на месте» (продлевает жизнь), false = «радара нет».
    /// `origin` — происхождение голоса ("pass" — после проезда), уходит серверу.
    /// `observedAt` — когда водитель видел точку (проезд); уходит серверу
    /// возрастом. `course` — наш курс при проезде (< 0 — неизвестен): тренога
    /// снимает обе стороны, и «Убрали» встречного сервер срок не режет.
    func vote(cameraID: Int, stillThere: Bool, origin: String = "", observedAt: Date = Date(),
              course: CLLocationDegrees = -1) async {
        // Пульт погасил краудсорс — голос из открытой карточки не уходит.
        guard isEnabled else { return }
        let vote = PendingVote(reportID: cameraID - Self.idOffset, value: stillThere ? 1 : -1,
                               kind: origin, at: observedAt, course: course >= 0 ? course : nil)
        // Сеть подвела — голос ждёт её в очереди (как отметка): «Нет, радара
        // не было» в мёртвой зоне — то, что снимает пустышку раньше срока.
        if let why = await postVote(vote) {
            if why.isWorthRetrying {
                pendingVotes = VoteQueue.enqueued(vote, into: pendingVotes)
                savePendingVotes()
            }
            return
        }
        await refresh()
    }

    /// Один POST голоса. nil — дошёл (или отметки уже нет — 404, голосовать
    /// не за что); иначе причина.
    private func postVote(_ vote: PendingVote) async -> ReportResult.Failure? {
        struct Response: Decodable { let ok: Bool }
        var payload = ["id": vote.reportID, "device": deviceID, "value": vote.value] as [String: Any]
        if !vote.kind.isEmpty { payload["kind"] = vote.kind }
        // Сколько секунд назад видели: «стоит» старше 10 мин сервер учтёт без
        // продления. Старый сервер поле не читает.
        let age = Date().timeIntervalSince(vote.at)
        if age >= 1 { payload["age"] = Int(age) }
        if let course = vote.course { payload["course"] = (course * 10).rounded() / 10 }
        do {
            _ = try await api.post("api/vote", json: payload, as: Response.self)
            return nil
        } catch {
            Log.network.error("голос по отметке не ушёл: \(error.localizedDescription, privacy: .public)")
            if case .badStatus(404)? = error as? APIClient.Failure { return nil }
            return Self.failure(for: error)
        }
    }

    func isMobile(_ camera: Camera) -> Bool { camera.id >= Self.idOffset }

    /// Серверный id отметки в нумерации камер приложения — чтобы вью могла
    /// сравнить «моя ли это точка» без знания про смещение.
    func idOffsetApplied(_ serverID: Int) -> Int { Self.idOffset + serverID }

    #if DEBUG
    /// 29.C, этап 1 (`-studyCrowd`): по отметке каждого краудсорс-типа рядом —
    /// чтобы увидеть все значки на одной карте. Без сети и без POST.
    func seedIconStudy(near coordinate: CLLocationCoordinate2D) {
        let looks: [(Int, CameraType, Double, Double, Bool)] = [
            (900_011, .mobileRadar, 0.0011, 0.0004, true),
            (900_012, .tripod, -0.0006, 0.0012, true),
            (900_013, .dpsPost, 0.0004, -0.0013, true),
            (900_014, .accident, -0.0013, -0.0005, true),
            (900_015, .mobileRadar, 0.0019, -0.0010, false),
        ]
        reports = looks.map { id, kind, dLat, dLon, confirmed in
            Camera(id: Self.idOffset + id, region: kind.displayName, city: "", location: kind.displayName,
                   lat: coordinate.latitude + dLat, lon: coordinate.longitude + dLon,
                   type: kind.sourceString, violations: Camera.defaultViolations(forType: kind.sourceString),
                   needsReview: nil, mobileConfirmed: confirmed)
        }
        store?.setMobileCameras(reports)
    }

    /// Скриншот-хук `-demoMobileTrust`: подтверждённая отметка и призрак на
    /// испытательном сроке плюс своя свежая отметка — без сети и
    /// без настоящего POST в общую базу (фейк на проде увидят живые водители).
    func seedTrustDemo(near coordinate: CLLocationCoordinate2D) {
        // Свежесть (82): подтвердили 3 мин назад, не подтверждали 50 мин, «Уже нет».
        func demo(_ id: Int, dLat: Double, dLon: Double, confirmed: Bool,
                  fresh: TripodFreshness.Info) -> Camera {
            Camera(id: Self.idOffset + id,
                   region: CameraType.tripod.displayName, city: "",
                   location: String(format: String(localized: "Отмечен водителями, исчезнет ~%@"),
                                    Self.expiryText(Date().addingTimeInterval(3600).timeIntervalSince1970)),
                   lat: coordinate.latitude + dLat, lon: coordinate.longitude + dLon,
                   type: CameraType.tripod.sourceString,
                   violations: Camera.defaultViolations(forType: CameraType.tripod.sourceString),
                   needsReview: nil, mobileConfirmed: confirmed, mobileFresh: fresh)
        }
        let now = Date()
        reports = [demo(900_001, dLat: 0.004, dLon: 0.0015, confirmed: true,
                        fresh: .init(created: now.addingTimeInterval(-40 * 60),
                                     lastConfirmed: now.addingTimeInterval(-3 * 60), trust: 2, confirmed: true)),
                   demo(900_002, dLat: 0.004, dLon: -0.0035, confirmed: false,
                        fresh: .init(created: now.addingTimeInterval(-50 * 60), trust: 0, confirmed: false)),
                   demo(900_004, dLat: -0.003, dLon: 0.002, confirmed: true,
                        fresh: .init(created: now.addingTimeInterval(-70 * 60),
                                     lastConfirmed: now.addingTimeInterval(-25 * 60), trust: 0, doubted: 1,
                                     confirmed: true))]
        confirmations = [
            Self.idOffset + 900_001: Confirmation(upvotes: 3, created: now.addingTimeInterval(-40 * 60), confirmed: true),
            Self.idOffset + 900_002: Confirmation(upvotes: 0, created: now.addingTimeInterval(-50 * 60), confirmed: false),
            Self.idOffset + 900_004: Confirmation(upvotes: 1, created: now.addingTimeInterval(-70 * 60), confirmed: true),
        ]
        store?.setMobileCameras(reports)
        let sent = ReportGuard.Sent(kind: .radar, latitude: coordinate.latitude,
                                    longitude: coordinate.longitude, at: Date(), serverID: 900_003)
        lastSent = sent
        // Свежая своя отметка — иначе «Отменить» в панели не показать на
        // скриншотах, а именно её и надо смотреть глазами.
        lastSentID = 900_003
    }
    #endif

    // MARK: - Внутреннее

    /// На сколько часы телефона впереди сервера (секунды). Меньше 5 с —
    /// шум (заголовок с точностью до секунды, время в пути); больше суток —
    /// не верим ни тем, ни другим часам и не правим.
    nonisolated static func clockSkew(serverDate: Date?, localNow: Date) -> TimeInterval {
        guard let serverDate else { return 0 }
        let skew = localNow.timeIntervalSince(serverDate)
        guard abs(skew) >= 5, abs(skew) <= 86_400 else { return 0 }
        return skew
    }

    private static func expiryText(_ expires: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: expires)
        return Formatting.clock(date)
    }
}

/// Тип отметки водителя: у каждого свой вид на карте и время жизни на сервере
/// (радар/тренога — часы, пост стоит дольше, ДТП рассасывается за час).
nonisolated enum ReportKind: String, CaseIterable, Identifiable, Sendable {
    case radar, tripod, post, accident
    /// Перекрытие и ремонт (12б.5): события дороги, не камеры — свой список
    /// на сервере, свой вид, в оповещения о камерах не входят.
    case closure, roadwork
    var id: String { rawValue }

    var isRoadEvent: Bool { roadEventKind != nil }

    var roadEventKind: RoadEvent.Kind? {
        switch self {
        case .closure: return .closure
        case .roadwork: return .roadwork
        case .radar, .tripod, .post, .accident: return nil
        }
    }

    /// Типы дороги — предлагаются, только когда сервер их знает
    /// (`MobileCameraService.roadEventsSupported`).
    static var roadOffered: [ReportKind] { [.closure, .roadwork] }

    /// Что предлагаем ставить рукой.
    ///
    /// `post` вернулся в список по прямой просьбе водителя: пост ДПС — ровно
    /// та вещь, ради которой лезут к телефону, и «радаром» она не покрывается
    /// (у поста и время жизни другое — шесть часов против трёх).
    ///
    /// Риск при этом остаётся и записан здесь, чтобы решение принималось с
    /// открытыми глазами: App Review отдельно смотрит на приложения,
    /// показывающие посты контроля не из официальных источников
    /// (Guideline 1.4.4). Waze с этим живёт, но придирка возможна — и если
    /// она случится, отсюда убирается одна строка, а сам тип и все уже
    /// поставленные отметки продолжают работать.
    static var offered: [ReportKind] { [.radar, .tripod, .post, .accident] }

    /// Тип камеры отметки. У событий дороги его нет по смыслу — `.other`
    /// с названием только ради вида; камерой они не становятся никогда (см.
    /// разбор /api/mobile).
    var cameraType: CameraType {
        switch self {
        case .radar:    return .mobileRadar
        case .tripod:   return .tripod
        case .post:     return .dpsPost
        case .accident: return .accident
        case .closure, .roadwork: return .other(title)
        }
    }
    var title: String {
        switch self {
        case .closure:  return String(localized: "Перекрыто")
        case .roadwork: return String(localized: "Ремонт")
        default:        return cameraType.displayName
        }
    }
    var symbol: String {
        switch self {
        case .closure:  return "nosign"
        case .roadwork: return "cone.fill"
        default:        return cameraType.symbolName
        }
    }

}
