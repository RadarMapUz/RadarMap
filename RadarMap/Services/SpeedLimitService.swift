//
//  SpeedLimitService.swift
//  RadarMap
//
//  Лимиты скорости дорог (maxspeed из OpenStreetMap, готовит наш сервер).
//  Определяет лимит дороги, по которой едем (позиция + курс), и следит за превышением.
//  База ~3 МБ обновляется раз в неделю и не трогает главный поток при загрузке.
//  Доверие — как у базы камер (правило 19): подписанный индекс с sha файла,
//  проверка на каждой загрузке и храповик перехода (LimitsManifest.swift,
//  диск и проверка байтов — SpeedLimitCache.swift).
//  Матчинг на GPS-тике стоит ~0,1 мс в плотном центре (замерено
//  PerformanceBudgetTests на сети по статистике боевого файла) — это
//  по-прежнему самая дорогая арифметика тика, и трогать её надо с замером.
//  Прежний комментарий обещал здесь «микросекунды»; на деле их не было
//  никогда — до появления рамки сегмента цена была 0,7 мс.
//

import Foundation
import MapKit
import Observation
import os

@MainActor
@Observable
final class SpeedLimitService {

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
    /// Лимит дороги, по которой сейчас едем (nil — дорога без данных и
    /// предположить не из чего).
    private(set) var currentLimit: Int?

    /// Лимит не из OSM, а предположен по классу дороги
    /// (`RoadClass.assumedLimitKmh`). Показывается со знаком «≈» и НЕ
    /// превращается в конкретную сумму штрафа: деньги требуют уверенности,
    /// а предположение её не даёт.
    private(set) var isCurrentLimitAssumed = false

    /// Мгновенное превышение — только для подсветки цифры на HUD: флаг щёлкает
    /// на одном GPS-фиксе, а GPS шумит (68 → 71 → 66 при лимите 60).
    private(set) var isOverspeeding = false
    /// Превышаем УСТОЙЧИВО (дольше overspeedSustainSeconds). Именно этот флаг
    /// решает, кричать ли о камере: иначе один шумный фикс на «превысил на 1 км»
    /// поднимал спокойный анонс до сирены.
    private(set) var isOverspeedingSustained = false

    /// Голос «Превышение скорости» — подключается в AppEnvironment.
    @ObservationIgnored var onOverspeed: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onOverspeed,
                                               "SpeedLimitService.onOverspeed") }
    }

    /// Поколение индекса: растёт при загрузке/обновлении базы лимитов. Карта
    /// по нему пересобирает слой маркеров — индекс приезжает с диска и с сервера
    /// позже первого слоя, и без сигнала мини-знаки «60» не появились бы до
    /// первого движения карты.
    private(set) var indexRevision = 0
    /// Сеть для схемы приборки: индекс лимитов под кэшем окрестности.
    /// Пересоздаётся вместе с индексом — кэш не должен пережить свои данные.
    private(set) var sketchNetwork: any RoadNetworkSource = EmptyRoadNetwork()

    private let settings: AppSettings
    @ObservationIgnored private var index: LimitIndex? {
        didSet {
            indexRevision += 1
            sketchNetwork = index.map { CachedRoadNetwork($0) } ?? EmptyRoadNetwork()
            if isReady != (index != nil) { isReady = index != nil }
        }
    }
    @ObservationIgnored private var missCount = 0
    @ObservationIgnored private var overspeedSince: Date?
    @ObservationIgnored private var lastWarnAt: Date = .distantPast
    @ObservationIgnored private var started = false

    /// Откуда взят действующий индекс. Нужен храповику: увидев подписанный
    /// индекс, телефон обязан снять индекс из НЕподписанных данных, даже если
    /// новый файл скачать не удалось. И он же экономит 3,4 МБ: тот же sha,
    /// что уже работает, второй раз не качается.
    @ObservationIgnored private var indexSource: SpeedLimitCache.Source?

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("speed_limits.json")
    }
    /// Проверенный конверт индекса — рядом с файлом, который он описывает.
    /// Хранится КОНВЕРТОМ, а не разобранным: подпись и sha перепроверяются
    /// на каждой загрузке (Documents виден бэкапу и файловому менеджеру и
    /// ничем не надёжнее сети).
    private var manifestURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("speed_limits_index.json")
    }

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Лимит дороги у произвольной точки (карточка камеры). nil — данных нет.
    func limit(near coordinate: CLLocationCoordinate2D) -> Int? {
        index?.limit(near: coordinate)
    }

    /// То же, но с предположением по классу дороги, когда OSM молчит.
    /// Возвращает и признак «предположено» — его обязан показать вызывающий.
    func limit(for camera: Camera) -> (kmh: Int, isAssumed: Bool)? {
        if let known = index?.limit(near: camera.coordinate) { return (known, false) }
        guard let assumed = camera.roadClass.assumedLimitKmhOffline else { return nil }
        return (assumed, true)
    }

    /// Сам индекс — для пакетных запросов вне main (слой маркеров карты
    /// спрашивает лимиты двух сотен камер разом; LimitIndex — Sendable).
    var limitIndex: LimitIndex? { index }

    /// Лимит, за который можно ручаться: только из OSM, без догадок.
    ///
    /// Детектору город/трасса нужен именно такой. Предположенный лимит там,
    /// где его вес самый большой (два голоса из четырёх), замкнул бы петлю:
    /// контекст решал бы, какую догадку взять, а догадка — какой контекст.
    var certainLimit: Int? { isCurrentLimitAssumed ? nil : currentLimit }

    /// База лимитов есть. Без неё не считаются ни превышения, ни рейтинг, ни
    /// «возможные штрафы» — то есть половина Итогов пустая, и по экрану
    /// непонятно почему. Пользователю это надо сказать, а не оставить гадать.
    ///
    /// Хранимое и наблюдаемое, а не `index != nil`: сам индекс вне наблюдения
    /// (пишется редко, но читается каждый тик), и вычисляемое свойство поверх
    /// него не будило плашку — она застревала на «не загрузились», хотя база
    /// уже поднялась с диска через секунду после первого кадра.
    private(set) var isReady = false

    /// Скачивание идёт прямо сейчас (для честной плашки, а не спиннера-загадки).
    private(set) var isDownloading = false

    /// Дорога последнего матчинга: точка полотна и азимут — сырьё для снапа
    /// картинки (RoadSnapper в LocationService). @ObservationIgnored намеренно:
    /// пишется каждый тик, а читается синхронно из LocationService — будить
    /// SwiftUI-подписчиков этой записью было бы ежесекундной перерисовкой.
    @ObservationIgnored private(set) var currentRoadHit: LimitIndex.RoadHit?

    /// Один клиент на сервис: APIClient держит собственную URLSession, а та
    /// живёт до инвалидации — создавать её на вызов значит оставлять по сессии
    /// на каждую проверку.
    @ObservationIgnored private let api = APIClient(timeout: 30)

    // MARK: - Загрузка базы

    /// Вызывается при старте приложения: локальный файл сразу, сервер — раз в 7 дней.
    func start() {
        guard !started else { return }
        started = true
        Task {
            await loadLocal()
            await refreshFromServerIfNeeded()
        }
    }

    /// Кэш с диска — по тем же правилам доверия, что ответ сервера
    /// (SpeedLimitCache.load): подпись индекса и sha файла на каждом чтении.
    private func loadLocal() async {
        let dataURL = fileURL, manifestURL = self.manifestURL
        let ratchet = Storage.bool(.speedLimitsSignedSeen)
        let cached = await Task.detached(priority: .utility) {
            SpeedLimitCache.load(dataURL: dataURL, manifestURL: manifestURL, ratchetSet: ratchet)
        }.value
        if cached.sawSignedIndex { markSignedSeen() }
        if let built = cached.index {
            index = built
            indexSource = cached.source
        }
    }

    /// Повторить загрузку по кнопке из плашки: человек видит, что данных нет,
    /// и должен иметь возможность что-то с этим сделать, а не ждать неделю.
    func retryDownload() async {
        Storage.set(0, for: .speedLimitsLastCheck)
        await refreshFromServerIfNeeded()
    }

    private func refreshFromServerIfNeeded() async {
        let lastCheck = Storage.double(.speedLimitsLastCheck)
        let weekAgo = Date().timeIntervalSince1970 - 7 * 24 * 3600
        guard index == nil || lastCheck < weekAgo else { return }

        isDownloading = true
        defer { isDownloading = false }
        // Недельная фоновая проверка: сбой сети не критичен, попробуем в
        // следующий раз. Подписанный индекс — первым; что значит его
        // отсутствие, решает храповик (LimitsTrust.decide), а не этот вызов.
        let indexData = await fetch(AppConfig.speedLimitsIndexPath)
        let state = LimitsTrust.indexState(indexData)
        if case .invalid(let why) = state {
            Log.route.error("индекс лимитов отвергнут: \(why.logDescription, privacy: .public)")
        }
        switch LimitsTrust.decide(signedIndex: state,
                                  ratchetSet: Storage.bool(.speedLimitsSignedSeen)) {
        case .useSigned(let manifest):
            markSignedSeen()
            guard let indexData else { return }   // .valid без байтов не бывает
            await applySigned(manifest, envelope: indexData)
        case .useLegacy:
            await refreshLegacy()
        case .keepVerified:
            Log.route.notice("лимиты: подписанного индекса нет — держим проверенное")
            dropUnverifiedIfRatcheted()
        }
    }

    /// Подписанный путь: файл по имени из индекса, sha и размер против него,
    /// и только потом — в память и на диск.
    private func applySigned(_ manifest: LimitsManifest, envelope: Data) async {
        // schemaProblem() уже гарантировал, что файл понятного формата есть.
        guard let file = manifest.preferredFile() else { return }
        // Тот же файл уже проверен и работает — 3,4 МБ второй раз не качаем:
        // индекс спрашивается раз в неделю, а данные меняются раз в месяц.
        if index != nil, indexSource == .signed(sha256: file.sha256) {
            Storage.set(Date().timeIntervalSince1970, for: .speedLimitsLastCheck)
            return
        }
        guard let data = await fetch(file.name) else {
            // Сеть: попробуем при следующем запуске. Непроверенное не держим.
            dropUnverifiedIfRatcheted()
            return
        }
        let dataURL = fileURL, manifestURL = self.manifestURL
        let outcome = await Task.detached(priority: .utility) {
            SpeedLimitCache.acceptSigned(data, file: file, envelope: envelope,
                                         dataURL: dataURL, manifestURL: manifestURL)
        }.value
        switch outcome {
        case .success(let built):
            index = built
            indexSource = .signed(sha256: file.sha256)
            Storage.set(Date().timeIntervalSince1970, for: .speedLimitsLastCheck)
            Log.route.notice("лимиты: принят подписанный набор \(file.name, privacy: .public)")
        case .failure(let why):
            Log.route.error("файл лимитов \(file.name, privacy: .public) отвергнут: \(why.logDescription, privacy: .public)")
            dropUnverifiedIfRatcheted()
        }
    }

    /// Старый неподписанный путь — только на переход, до храповика.
    /// Формат 2 несёт класс дороги и потому предпочтителен. Формат 1 остаётся
    /// на сервере для уже установленных сборок, а нам служит запасным.
    private func refreshLegacy() async {
        var payload = await fetch("speed_limits_v2.json")
        if payload == nil { payload = await fetch("speed_limits.json") }
        guard let data = payload else { return }

        let url = fileURL
        let built = await Task.detached(priority: .utility) {
            SpeedLimitCache.acceptLegacy(data, dataURL: url)
        }.value
        // Пока качали, храповик мог встать (другой вызов увидел подпись):
        // тогда этот результат уже не вправе стать действующим.
        guard let built, LimitsTrust.allowsLegacy(ratchetSet: Storage.bool(.speedLimitsSignedSeen))
        else { return }
        index = built
        indexSource = .legacy
        Storage.set(Date().timeIntervalSince1970, for: .speedLimitsLastCheck)
    }

    /// Храповик: подписанный индекс увиден — неподписанный путь закрыт навсегда.
    private func markSignedSeen() {
        guard !Storage.bool(.speedLimitsSignedSeen) else { return }
        Storage.set(true, for: .speedLimitsSignedSeen)
        Log.route.notice("лимиты: увиден подписанный индекс — неподписанный путь закрыт навсегда")
    }

    /// Индекс из неподписанных данных после храповика не живёт: не удалось
    /// взять подписанный — лучше честная плашка «нет лимитов» с кнопкой
    /// повтора, чем голос и штрафы по непроверенным цифрам.
    private func dropUnverifiedIfRatcheted() {
        guard indexSource == .legacy,
              !LimitsTrust.allowsLegacy(ratchetSet: Storage.bool(.speedLimitsSignedSeen))
        else { return }
        index = nil
        indexSource = nil
        Log.route.error("лимиты: неподписанный индекс снят, подписанный не получен — живём без лимитов")
    }

    /// GET без кэша. nil — «нет»: сбой сети и статуса APIClient уже записал
    /// в журнал сам (transport/checkStatus), здесь важен только факт.
    private func fetch(_ path: String) async -> Data? {
        try? await api.getData(path, cachePolicy: .reloadIgnoringLocalCacheData)
    }

    // MARK: - Тик (вызывается LocationService на каждой GPS-точке)

    /// `fallbackClass` — класс дороги ближайшей камеры. Когда `maxspeed` в OSM
    /// нет, лимит предполагается по нему: см. `RoadClass.assumedLimitKmh`.
    /// Класс камеры — лучший доступный признак дороги, по которой мы едем:
    /// камера стоит НАД этой дорогой, и её `cls` проставлен снапом у 3455 из
    /// 3467 записей базы.
    /// `inSettlement` — «мы в населённом пункте»: от этого, а не от класса
    /// дороги, зависит догадка о лимите (ПДД РУз, пункт 10). Приходит из
    /// детектора город/трасса, который считается независимо — в том числе
    /// БЕЗ участия предположенных лимитов, иначе догадка кормила бы сама себя.
    func update(coordinate: CLLocationCoordinate2D, course: CLLocationDirection,
                speedKmh: Double, announce: Bool, fallbackClass: RoadClass = .unknown,
                inSettlement: Bool = true, cameraAhead: Bool = false) {
        guard settings.speedLimitsEnabled, let index else {
            currentLimit = nil; isCurrentLimitAssumed = false; clearOverspeed()
            currentRoadHit = nil
            return
        }

        // Матчим дорогу только в движении с достоверным курсом;
        // стоя (светофор) держим последний известный лимит — и последнюю
        // найденную дорогу: стоя мы с неё не съехали, и снап картинки не
        // должен отлипать на каждом светофоре.
        if speedKmh >= 8, course >= 0 {
            if let hit = index.matchHit(coordinate, courseDegrees: course) {
                currentRoadHit = hit
                if hit.limit != currentLimit { currentLimit = hit.limit }
                if isCurrentLimitAssumed { isCurrentLimitAssumed = false }
                missCount = 0
            } else {
                currentRoadHit = nil
                missCount += 1
                if missCount >= 4 {
                    // Данных по дороге нет — предполагаем по классу. Раньше
                    // здесь наступал nil, и вместе с ним пропадали превышение,
                    // рейтинг и голос о камере в режиме по умолчанию.
                    let assumed = fallbackClass.assumedLimitKmh(inSettlement: inSettlement)
                    if assumed != currentLimit { currentLimit = assumed }
                    if isCurrentLimitAssumed != (assumed != nil) {
                        isCurrentLimitAssumed = assumed != nil
                    }
                }
            }
        }

        guard let limit = currentLimit else {
            clearOverspeed()
            return
        }
        // Порог зависит от того, есть ли впереди камера.
        //
        // Вдали от камер это совет, и дёргать человека за километр в час
        // незачем — допуск из настроек. У камеры порог становится ЖЁСТЧЕ
        // штрафного: камера фиксирует с +5, и предупреждение, приходящее ровно
        // на +5, приходит ВМЕСТЕ со штрафом. Смысл предупреждения в том, чтобы
        // успеть отпустить газ, а не узнать о случившемся.
        let threshold = OverspeedThreshold.kmh(cameraAhead: cameraAhead,
                                               userTolerance: settings.overspeedTolerance)
        let over = speedKmh > Double(limit) + threshold
        if over != isOverspeeding { isOverspeeding = over }
        overspeedSince = over ? (overspeedSince ?? Date()) : nil

        // Устойчивость считаем один раз и здесь: и голос, и градус алерта о камере
        // должны опираться на одно и то же «превышаем по-настоящему».
        // Подтверждение у камеры короче: 2,5 секунды на подъезде — это до ста
        // метров пути, и совет «сбросьте» прозвучал бы уже за стойкой.
        let needed = cameraAhead ? AppConfig.overspeedSustainSecondsNearCamera
                                 : AppConfig.overspeedSustainSeconds
        let sustained = overspeedSince.map {
            Date().timeIntervalSince($0) >= needed
        } ?? false
        if sustained != isOverspeedingSustained { isOverspeedingSustained = sustained }

        // Голос про само превышение: не чаще раза в 30 с.
        if sustained, announce, Date().timeIntervalSince(lastWarnAt) > 30 {
            lastWarnAt = Date()
            onOverspeed?()
        }
    }

    // MARK: - Смена лимита впереди (LimitAhead)

    /// «Ограничение 40 через 200 м» — сказать заранее, а не «превышение»
    /// после знака.
    @ObservationIgnored var onLimitAhead: ((LimitAhead.Notice) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onLimitAhead,
                                               "SpeedLimitService.onLimitAhead") }
    }
    @ObservationIgnored private var limitAheadAnnouncer = LimitAhead.Announcer()
    @ObservationIgnored private var limitAheadCheckedAt: Date?

    /// - Parameter path: точки пути впереди от машины (маршрут); nil — по оси
    ///   текущей дороги прямо.
    func checkLimitAhead(coordinate: CLLocationCoordinate2D, course: CLLocationDirection,
                         speedKmh: Double, path: () -> [CLLocationCoordinate2D]?, announce: Bool,
                         now: Date = Date()) {
        // Предполагаемый лимит (по классу дороги) — не повод для фразы «через
        // 200 м»: это догадка, а не знак.
        guard announce, settings.speedLimitsEnabled, let index, course >= 0,
              speedKmh >= AppConfig.limitAheadMinSpeedKmh,
              let current = currentLimit, !isCurrentLimitAssumed else { return }
        if let at = limitAheadCheckedAt, now.timeIntervalSince(at) < AppConfig.limitAheadCheckSeconds { return }
        limitAheadCheckedAt = now
        let probes = Self.probes(index: index, from: coordinate, course: course, path: path())
        guard let notice = LimitAhead.notice(current: current, speedKmh: speedKmh,
                                             tolerance: settings.overspeedTolerance, probes: probes),
              limitAheadAnnouncer.shouldAnnounce(notice, at: now) else { return }
        Log.route.notice("лимит впереди: \(notice.limit, privacy: .public) через \(Int(notice.distance), privacy: .public) м")
        onLimitAhead?(notice)
    }

    /// Пробы лимита впереди через `limitAheadStepMeters`: по линии пути или
    /// прямо по курсу — и тогда только пока ось дороги рядом (дальше
    /// изгиба проба ушла бы на соседнюю улицу — там проб нет).
    nonisolated static func probes(index: LimitIndex, from start: CLLocationCoordinate2D,
                                   course: CLLocationDirection,
                                   path: [CLLocationCoordinate2D]?) -> [LimitAhead.Probe] {
        let step = AppConfig.limitAheadStepMeters
        let targets = Array(stride(from: step, through: AppConfig.limitAheadMaxMeters + step, by: step))
        var out: [LimitAhead.Probe] = []
        if let path, path.count >= 2 {
            var travelled: CLLocationDistance = 0
            var target = targets.makeIterator()
            var next = target.next()
            for (p, q) in zip(path, path.dropFirst()) {
                let length = GeoMath.fastDistance(p.latitude, p.longitude, q.latitude, q.longitude)
                guard length > 0 else { continue }
                let bearing = GeoMath.bearing(from: p, to: q)
                while let along = next, along <= travelled + length {
                    let t = (along - travelled) / length
                    let point = CLLocationCoordinate2D(latitude: p.latitude + (q.latitude - p.latitude) * t,
                                                       longitude: p.longitude + (q.longitude - p.longitude) * t)
                    out.append(LimitAhead.Probe(along: along,
                                                limit: index.matchHit(point, courseDegrees: bearing)?.limit,
                                                coordinate: point))
                    next = target.next()
                }
                travelled += length
            }
            return out
        }
        for along in targets {
            let point = GeoMath.destination(from: start, bearing: course, distanceMeters: along)
            guard let hit = index.matchHit(point, courseDegrees: course),
                  hit.distanceMeters <= AppConfig.limitAheadSnapMeters else { break }
            out.append(LimitAhead.Probe(along: along, limit: hit.limit, coordinate: point))
        }
        return out
    }

    private func clearOverspeed() {
        isOverspeeding = false
        isOverspeedingSustained = false
        overspeedSince = nil
    }
}

// MARK: - Индекс сегментов

/// Иммутабельный индекс: строится в фоне, читается с главного потока без блокировок.
struct LimitIndex: Sendable, RoadNetworkSource {
    struct Segment: Sendable {
        let limit: Int
        /// Класс дороги. `.unknown` у файла формата 1 — там его просто нет.
        let cls: RoadClass
        let pts: [MKMapPoint]
        /// Рамка сегмента в единицах MKMapPoint.
        ///
        /// Ячейка грида — 1,1 км, а совпадением считается 35 м: почти всё, что
        /// попало в кольцо ячеек, до дороги под колесом не дотягивается. Без
        /// рамки `match` обходил ВСЕ пары точек ВСЕХ сегментов кольца — в
        /// плотном центре это тысячи пар на каждом GPS-тике. Рамка отсекает
        /// сегмент четырьмя сравнениями, до того как начнётся геометрия.
        let minX, minY, maxX, maxY: Double

        init(limit: Int, cls: RoadClass = .unknown, pts: [MKMapPoint]) {
            self.limit = limit
            self.cls = cls
            self.pts = pts
            var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
            for point in pts {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            self.minX = minX; self.minY = minY
            self.maxX = maxX; self.maxY = maxY
        }

        /// Может ли эта дорога оказаться ближе `reach` (в единицах MKMapPoint).
        func mayReach(_ p: MKMapPoint, within reach: Double) -> Bool {
            p.x >= minX - reach && p.x <= maxX + reach
                && p.y >= minY - reach && p.y <= maxY + reach
        }
    }

    let segments: [Segment]
    let grid: [Int: [Int32]]   // ячейка 0.01° → индексы сегментов

    // MARK: - Дороги для схемы на приборке

    /// Индекс лимитов — по совместительству ЕДИНСТВЕННАЯ дорожная геометрия,
    /// которая уже лежит на телефоне: 21 558 сегментов, 183 483 точки, офлайн.
    /// Мы качали его ради матчинга лимита, а он несёт настоящие линии дорог —
    /// с перекрёстками и развязками. Первый источник для RoadSketch, пока не
    /// собран собственный roads.json (см. RoadNetwork.swift).
    ///
    /// Чего этот источник НЕ знает: класса дороги, моста, односторонности —
    /// в файле их нет. Поэтому все линии помечены как «без подробностей», и
    /// вью рисует их ровно, не выдавая догадку за измеренное.
    func roads(near coordinate: CLLocationCoordinate2D,
               radius: CLLocationDistance) -> [RoadLine] {
        // Ячейка грида 0.01° ≈ 1,1 км — берём кольцо ячеек по радиусу.
        let span = max(1, Int((radius / 1100).rounded(.up)))
        let centerLat = Int((coordinate.latitude + 90) * 100)
        let centerLon = Int((coordinate.longitude + 180) * 100)

        var seen = Set<Int32>()
        for latCell in (centerLat - span)...(centerLat + span) {
            for lonCell in (centerLon - span)...(centerLon + span) {
                if let found = grid[latCell * 40_000 + lonCell] { seen.formUnion(found) }
            }
        }
        guard !seen.isEmpty else { return [] }

        let origin = MKMapPoint(coordinate)
        // Радиус в единицах MKMapPoint, и сравниваем КВАДРАТЫ — в тех же
        // единицах, что и точки сегмента.
        //
        // Здесь была путаница в единицах: `MKMapPoint.distance` возвращает
        // МЕТРЫ, а сравнивали его с радиусом, уже переведённым в единицы карты.
        // На широте Ташкента это множитель ~8,8 — «дороги в радиусе 570 м»
        // отдавались в радиусе пяти километров. Схема потом всё равно обрезала
        // их своим масштабом, поэтому на экране это не проявлялось: просто
        // каждая пересборка тащила в несколько раз больше геометрии, чем
        // просила, и делала это на телефоне в держателе.
        let limitSquared = Self.points(radius, at: coordinate) * Self.points(radius, at: coordinate)
        func within(_ point: MKMapPoint) -> Bool {
            let dx = point.x - origin.x, dy = point.y - origin.y
            return dx * dx + dy * dy <= limitSquared
        }
        let reach = Self.points(radius, at: coordinate)
        return seen.compactMap { index -> RoadLine? in
            let segment = segments[Int(index)]
            guard segment.mayReach(origin, within: reach) else { return nil }
            // Точки за радиусом отбрасываем, но линию не рвём: берём кусок от
            // первой до последней попавшей — иначе дорога рассыпалась бы на
            // обрывки там, где она просто длинная.
            guard let first = segment.pts.firstIndex(where: within),
                  let last = segment.pts.lastIndex(where: within),
                  last > first else { return nil }
            return RoadLine(points: segment.pts[first...last].map(\.coordinate))
        }
    }

    nonisolated private static func cellKey(lat: Double, lon: Double) -> Int {
        let latCell = Int((lat + 90) * 100)
        let lonCell = Int((lon + 180) * 100)
        return latCell * 40_000 + lonCell
    }

    nonisolated static func build(from data: Data) -> LimitIndex? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["segments"] as? [[Any]] else {
            Log.route.error("speed_limits.json: неожиданный формат")
            return nil
        }

        var segments: [Segment] = []
        segments.reserveCapacity(raw.count)
        var grid: [Int: [Int32]] = [:]

        for entry in raw {
            // Границы значения — второй забор после подписи. Подписанный
            // индекс (LimitsTrust, server/publish_limits.sh) гарантирует, что
            // файл собрал владелец, но не что OSM прав; а на переходный путь,
            // пока подписанного индекса телефон не видел, этот забор — вообще
            // единственная защита: файл приходит по HTTPS, но без подписи.
            // Явно отвергаем невозможные лимиты: в Узбекистане минимум 20
            // (дворы), максимум 110–130, и «5» с «300» означают испорченные
            // данные, а не дорогу. Отвергаем СЕГМЕНТ, а не файл: один битый
            // лимит не должен выключить двадцать тысяч честных.
            // Форматов ДВА. Первый — [limit, geometry], он остаётся на бою для
            // уже установленных приложений. Второй — [limit, cls, geometry]:
            // без класса дороги лимит это половина ответа, потому что отличить
            // проспект от идущего вдоль него дублёра больше нечем.
            guard let limit = (entry.first as? NSNumber)?.intValue,
                  AppConfig.plausibleSpeedLimits.contains(limit),
                  let flat = entry.last as? [NSNumber], flat.count >= 4,
                  entry.count == 2 || entry.count == 3 else { continue }
            let cls: RoadClass = entry.count == 3
                ? RoadClass(code: (entry[1] as? NSNumber)?.intValue ?? 0)
                : .unknown

            var pts: [MKMapPoint] = []
            pts.reserveCapacity(flat.count / 2)
            let segmentIndex = Int32(segments.count)
            var cells = Set<Int>()

            var previous: (lat: Double, lon: Double)?
            for i in stride(from: 0, to: flat.count - 1, by: 2) {
                let lat = flat[i].doubleValue, lon = flat[i + 1].doubleValue
                pts.append(MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: lon)))
                cells.insert(cellKey(lat: lat, lon: lon))
                // Длинные прямые перегоны: отмечаем и промежуточные ячейки (шаг ~0.005°).
                if let p = previous {
                    let steps = Int(max(abs(lat - p.lat), abs(lon - p.lon)) / 0.005)
                    if steps > 1 {
                        for s in 1..<steps {
                            let f = Double(s) / Double(steps)
                            cells.insert(cellKey(lat: p.lat + (lat - p.lat) * f,
                                                 lon: p.lon + (lon - p.lon) * f))
                        }
                    }
                }
                previous = (lat, lon)
            }
            segments.append(Segment(limit: limit, cls: cls, pts: pts))
            for cell in cells { grid[cell, default: []].append(segmentIndex) }
        }
        return segments.isEmpty ? nil : LimitIndex(segments: segments, grid: grid)
    }

    /// Кандидаты кольца 3×3 ячеек вокруг точки. Один сегмент лежит в нескольких
    /// ячейках, поэтому Set: без него длинный проспект перебирался бы девять раз.
    nonisolated private func candidates(around coordinate: CLLocationCoordinate2D) -> Set<Int32> {
        var found = Set<Int32>()
        for dLat in -1...1 {
            for dLon in -1...1 {
                let key = Self.cellKey(lat: coordinate.latitude + Double(dLat) * 0.01,
                                       lon: coordinate.longitude + Double(dLon) * 0.01)
                if let list = grid[key] { found.formUnion(list) }
            }
        }
        return found
    }

    /// Найденная дорога: лимит, ближайшая точка ПОЛОТНА и его направление.
    ///
    /// Точка и азимут нужны снапу картинки к дороге (RoadSnapper): тот же
    /// проход, что ищет лимит, отдаёт их бесплатно — второй запрос по кольцу
    /// на каждом тике стоил бы столько же, сколько сам матчинг.
    struct RoadHit: Sendable {
        let limit: Int
        /// Класс дороги, чей лимит взят. `.unknown` — файл формата 1 (класса в
        /// нём нет ни у кого) либо вызов, которому класс не нужен вовсе.
        var cls: RoadClass = .unknown
        /// Ближайшая точка оси дороги.
        let coordinate: CLLocationCoordinate2D
        /// Направление сегмента в этой точке (0–360°, куда «идёт» линия;
        /// дорога двусторонняя — потребитель сам выбирает ближнюю из двух).
        let bearingDegrees: Double
        /// Насколько мы в стороне от оси, метры.
        let distanceMeters: Double
    }

    /// Ближайшая дорога кольца.
    ///
    /// Общее тело для `match` и `limit(near:)` — они обязаны сходиться в том,
    /// какую дорогу считают ближайшей, а раньше это были две копии одного
    /// цикла, расходившиеся при каждой правке.
    ///
    /// Считаем в КВАДРАТАХ единиц карты, а не в метрах: `MKMapPoint.distance`
    /// на каждую пару точек — это корень и пересчёт масштаба по широте, а нам
    /// нужно только сравнить, что ближе. Порядок сравнений от этого не меняется
    /// (масштаб внутри кольца постоянен), а метры остаются только на границе.
    /// `prefersMajorRoads` — победитель выбирается не по одной близости.
    ///
    /// Вдоль ташкентского проспекта идёт дублёр: он параллелен, значит
    /// проходит проверку направления, и при сносе GPS на пару метров он ближе.
    /// Лимит при этом берётся ЕГО — а у проспекта тега maxspeed может не быть
    /// вовсе. Поэтому к расстоянию прибавляется цена класса: проспект в
    /// двадцати метрах перебивает дублёр в пятнадцати, но служебный проезд ПОД
    /// колесом перебивает проспект в двадцати — иначе получим зеркальную
    /// ошибку и будем считать лимит проспекта во дворе.
    ///
    /// Корень берётся один раз на СЕГМЕНТ, а не на пару точек: внутренний цикл
    /// остаётся на квадратах, как и был (бюджет тика ~0,11 мс).
    nonisolated private func nearestRoad(
        to p: MKMapPoint, within reach: Double, candidates: Set<Int32>,
        prefersMajorRoads: Bool = false,
        accepts: (_ dx: Double, _ dy: Double) -> Bool
    ) -> RoadHit? {
        let reachSquared = reach * reach
        let unit = Self.points(1, at: p.coordinate)
        var bestScore = Double.greatestFiniteMagnitude
        var best: (limit: Int, cls: RoadClass, point: MKMapPoint,
                   dx: Double, dy: Double, distance: Double)?
        for candidate in candidates {
            let segment = segments[Int(candidate)]
            // Рамка: четыре сравнения вместо обхода всех точек сегмента.
            guard segment.mayReach(p, within: reach) else { continue }
            // Тротуар и переход — не проезжая часть, и их maxspeed не про нас.
            if prefersMajorRoads, segment.cls == .pedestrian { continue }
            var localSquared = reachSquared
            var local: (point: MKMapPoint, dx: Double, dy: Double)?
            let pts = segment.pts
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                // Ближайшая точка на отрезке AB.
                let dx = b.x - a.x, dy = b.y - a.y
                let len2 = dx * dx + dy * dy
                guard len2 > 0 else { continue }
                let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
                let closest = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
                let ox = closest.x - p.x, oy = closest.y - p.y
                let squared = ox * ox + oy * oy
                guard squared < localSquared else { continue }
                guard accepts(dx, dy) else { continue }
                localSquared = squared
                local = (closest, dx, dy)
            }
            guard let local else { continue }
            let distance = localSquared.squareRoot()
            let score = distance + (prefersMajorRoads ? Self.classPenalty(segment.cls) * unit : 0)
            guard score < bestScore else { continue }
            bestScore = score
            best = (segment.limit, segment.cls, local.point, local.dx, local.dy, distance)
        }
        guard let best else { return nil }
        let coordinate = best.point.coordinate
        // Меркатор конформен: азимут корректен прямо из map-точек (y растёт на юг).
        let bearing = (atan2(best.dx, -best.dy) * 180 / .pi + 360)
            .truncatingRemainder(dividingBy: 360)
        return RoadHit(limit: best.limit, cls: best.cls, coordinate: coordinate,
                       bearingDegrees: bearing,
                       distanceMeters: best.distance
                           * MKMetersPerMapPointAtLatitude(coordinate.latitude))
    }

    /// Цена класса в метрах: насколько дальше может лежать дорога, чтобы всё
    /// равно победить. Ноль у магистральных — они и есть предпочтительный
    /// ответ; дороже всего служебный проезд, который чаще всего и оказывался
    /// ближайшим вдоль проспекта.
    nonisolated private static func classPenalty(_ cls: RoadClass) -> Double {
        switch cls {
        case .motorway, .trunk, .primary, .secondary: return 0
        case .tertiary, .residential:                 return AppConfig.limitMinorRoadPenaltyMeters
        case .service, .pedestrian:                   return AppConfig.limitServiceRoadPenaltyMeters
        // Формат 1: класса нет ни у кого, значит штраф одинаковый и порядок
        // прежний — правка не меняет поведение, пока сервер не выложит формат 2.
        case .unknown:                                return 0
        }
    }

    /// Метры в единицы MKMapPoint на этой широте.
    nonisolated private static func points(_ meters: Double,
                                           at coordinate: CLLocationCoordinate2D) -> Double {
        meters / MKMetersPerMapPointAtLatitude(coordinate.latitude)
    }

    /// Лимит дороги в точке: ближе 35 м к линии и направление совпадает с курсом (±40°, обе стороны).
    nonisolated func match(_ coordinate: CLLocationCoordinate2D, courseDegrees: Double) -> Int? {
        matchHit(coordinate, courseDegrees: courseDegrees)?.limit
    }

    /// То же, но с точкой полотна и азимутом — для снапа картинки к дороге.
    nonisolated func matchHit(_ coordinate: CLLocationCoordinate2D,
                              courseDegrees: Double) -> RoadHit? {
        nearestRoad(to: MKMapPoint(coordinate),
                    within: Self.points(35, at: coordinate),
                    candidates: candidates(around: coordinate),
                    prefersMajorRoads: true) { dx, dy in
            // Совпадение направления (дорогу считаем двусторонней).
            // Меркатор конформен: азимут корректно берётся прямо из map-точек (y растёт на юг).
            let segmentBearing = (atan2(dx, -dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            var diff = abs(segmentBearing - courseDegrees).truncatingRemainder(dividingBy: 360)
            if diff > 180 { diff = 360 - diff }
            return min(diff, 180 - diff) <= 40
        }
    }

    /// Лимит ближайшей дороги без учёта курса — для карточки камеры
    /// (камера стоит, курса нет; берём просто ближайшую дорогу до 45 м).
    nonisolated func limit(near coordinate: CLLocationCoordinate2D) -> Int? {
        nearestRoad(to: MKMapPoint(coordinate),
                    within: Self.points(45, at: coordinate),
                    candidates: candidates(around: coordinate)) { _, _ in true }?.limit
    }
}
