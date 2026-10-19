//
//  TripStats.swift
//  RadarMap
//
//  Статистика поездки: живые метрики + лог пройденных камер со скоростью,
//  трек поездки (упрощённый Дугласом-Пекером) и история.
//

import Foundation
import Observation
import CoreLocation
import os

@MainActor
@Observable
final class TripStats {

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
    private(set) var maxSpeedKmh: Double = 0
    private(set) var distanceMeters: CLLocationDistance = 0
    private(set) var startedAt: Date?
    /// Где началась поездка (первая точка трека; после склейки — исходной
    /// поездки): по нему призрак решает «на работу или домой».
    var startCoordinate: CLLocationCoordinate2D? {
        trackBuffer.first.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }
    private(set) var lastPointAt: Date?
    /// Пройденные камеры текущей/последней поездки (со скоростью прохождения).
    private(set) var passed: [PassedCamera] = []
    /// Заезды по пути, склеенные в эту поездку (см. resume и TripMerge).
    private(set) var stops: [TripStop] = []

    /// Заряд на старте поездки, %: живая дельта на приборке и запись в историю.
    /// nil — заряд не читался (симулятор) или начало склейки неизвестно.
    private(set) var startBatteryPercent: Int?

    private(set) var history: [TripRecord] = [] { didSet { dataRevision &+= 1 } }
    /// Растёт на каждое изменение истории или дневных сводок: ключ пересчёта
    /// экрана «Итогов» (ItogiScreen) — состав истории по id не замечал склейку
    /// и правку штрафа.
    private(set) var dataRevision = 0
    /// Когда последняя поездка легла в историю. Карточке «Поездка сохранена»
    /// нужен именно этот момент: `endedAt` записи — это время последнего
    /// фикса, а на стоянке фиксов нет, и минута у подъезда делала только что
    /// сохранённую поездку «несвежей» (см. TripEndPrompt).
    private(set) var lastSavedAt: Date?
    /// Дневные агрегаты — живут вечно, в отличие от записей (чистка режет треки
    /// через неделю и записи через 30 дней). По ним считается статистика за
    /// месяц и дальше, поэтому она не «худеет» вместе с историей.
    private(set) var days: [TripDay] = [] { didSet { dataRevision &+= 1 } }
    /// Пожизненные счётчики — живут отдельно от истории (она обрезается до 50 поездок).
    private(set) var lifetime = LifetimeStats()
    /// Охват предупреждений за всё время: сколько камер проехали и о скольких
    /// приложение успело сказать. Живёт рядом с lifetime и по той же причине —
    /// это цифра о работе конвейера, а не о конкретной поездке, и обрезка
    /// истории не должна её стирать.
    private(set) var alertRecall = AlertRecall.Tally()
    /// Вызывается после сохранения поездки (AppEnvironment вешает сюда счётчики
    /// использования и недельный дайджест — одним замыканием, см. Wiring).
    @ObservationIgnored var onTripFinished: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onTripFinished,
                                               "TripStats.onTripFinished") }
    }

    /// Одометр: опора, от которой считается пробег (S13). Она же — последняя
    /// точка поездки.
    @ObservationIgnored private var odometer = TripOdometer()
    private var lastCoordinate: CLLocationCoordinate2D? { odometer.anchor }
    /// Сырой трек текущей поездки: точка каждые ≥30 м, упрощается при финише.
    @ObservationIgnored private var trackBuffer: [TrackPoint] = []
    /// Время каждой точки `trackBuffer` (секунды Unix; NaN — неизвестно).
    /// Параллельным массивом, а не полем TrackPoint: в запись истории время
    /// не едет (трек там упрощён и живёт неделю), оно нужно только свёртке
    /// поездки в профиль дороги дом↔работа при финише (CommuteProfile).
    @ObservationIgnored private var trackTimes: [Double] = []
    /// Сырой трек последней сохранённой поездки — для склейки: продолженная
    /// поездка поднимает его вместо упрощённого, и время первой ноги не
    /// теряется (пока процесс жив).
    @ObservationIgnored private var lastFinishedRaw: (id: Double, track: [TrackPoint], times: [Double])?
    /// Поездка сохранена: запись и сырой трек со временем. Ставит
    /// AppEnvironment (профиль дороги на работу).
    @ObservationIgnored var onTrackFinished: ((TripRecord, [TrackPoint], [Double]) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onTrackFinished,
                                               "TripStats.onTrackFinished") }
    }
    /// Подробный трек со временем (TimedTrack) — только когда включено в
    /// настройках; ставит AppEnvironment. Пишется лишь в поездке.
    @ObservationIgnored var recordsTimedTrack = false
    @ObservationIgnored private var timedBuffer: [TimedPoint] = []

    // nonisolated: их читает и nonisolated-восстановление слепка (record(from:)).
    nonisolated private static let trackStepMeters = 30.0
    nonisolated private static let trackTolerance = 0.00022   // ~22 м — упрощение Дугласа-Пекера
    nonisolated private static let trackMaxPoints = 400

    /// История, дневные сводки и «за всё время» — с диска и вне main: это
    /// мегабайты JSON, и раньше их разбор стоял между запуском и первым кадром.
    init() {
        Task { await loadFromDisk() }
        // Старые посекундные треки — и без новых записей (S10, 20.10).
        Task.detached(priority: .utility) { TimedTrackStore.prune(now: Date()) }
    }

    /// История доехала с диска. AppEnvironment пересчитывает по этому сигналу
    /// то, что зависит от неё (выученные места, снимок виджета): к первому
    /// кадру истории в памяти ещё нет.
    @ObservationIgnored var onHistoryLoaded: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onHistoryLoaded,
                                               "TripStats.onHistoryLoaded") }
    }

    /// Пока история не приехала, писать её на диск нельзя: запись, сделанная
    /// в этом окне, затёрла бы файл огрызком.
    private(set) var isLoaded = false

    var camerasPassed: Int { passed.count }

    /// finish() обнуляет startedAt — длительность последней поездки храним отдельно,
    /// иначе «средняя км/ч» и «в пути» на экране Итогов превращаются в нули.
    private var finishedDuration: TimeInterval = 0

    /// Полное время поездки — со стоянками: столько она заняла по часам.
    var durationSeconds: TimeInterval {
        guard let startedAt, let lastPointAt else { return finishedDuration }
        return max(0, lastPointAt.timeIntervalSince(startedAt))
    }
    /// Время в движении: стоянки склеенной поездки не должны топить среднюю скорость.
    var movingSeconds: TimeInterval {
        max(0, durationSeconds - stops.reduce(0) { $0 + $1.duration })
    }
    var averageSpeedKmh: Double {
        movingSeconds > 0 ? distanceMeters / movingSeconds * 3.6 : 0
    }

    func begin(batteryPercent: Int? = nil) {
        maxSpeedKmh = 0
        distanceMeters = 0
        odometer = TripOdometer()
        passed = []
        stops = []
        trackBuffer = []
        trackTimes = []
        timedBuffer = []
        lastFinishedRaw = nil   // новая поездка, не склейка — прошлый трек не нужен
        resumedFrom = nil       // и не продолжение прошлой записи
        finishedDuration = 0
        startBatteryPercent = batteryPercent
        let now = Date()
        startedAt = now
        lastPointAt = now
        checkpointURL = Self.newCheckpointURL(for: now)
    }

    /// Продолжить прошлую поездку вместо новой: запись вынимается из истории
    /// обратно в живую сессию, а пауза между ними становится остановкой.
    /// Так заезд в магазин остаётся одной поездкой (решает TripMerge).
    /// Трек поднимаем уже упрощённым — сырых точек прошлой ноги нет, и это
    /// нормально: следующее упрощение при финише всё равно прошло бы по ним.
    /// Запись, которую продолжаем (склейка): по ней финиш вносит в «за всё
    /// время» только прибавку, а «я пассажир» возвращает её как была.
    @ObservationIgnored private var resumedFrom: TripRecord?
    /// Последний финиш продолжил прежнюю запись (склейка) — для счётчиков
    /// статистики: поездка та же, км — прибавка.
    @ObservationIgnored private(set) var lastFinishWasContinuation = false
    @ObservationIgnored private(set) var lastFinishDistanceDelta: Double = 0

    func resume(_ record: TripRecord, stoppedUntil resumedAt: Date = Date(),
                batteryPercent: Int? = nil) {
        resumedFrom = record
        // Склейка — самый частый ответ на «поездки нет»: она есть, но внутри
        // предыдущей записи. В журнале это должно быть видно.
        Log.trips.notice("поездка продолжена склейкой: запись от \(record.startedAt, privacy: .public), \(Int(record.distanceMeters), privacy: .public) м")
        noteDropped("merged")
        history.removeAll { $0.id == record.id }
        // Запись возвращается в живую сессию — вычитаем её из дневного агрегата,
        // иначе после финиша склеенной поездки день посчитает её дважды.
        days = TripDayBook.unfolded(record, from: days)
        // Эквивалентный «заряд на старте»: текущий плюс расход первой ноги —
        // тогда финальная дельта честно суммирует обе ноги склейки.
        startBatteryPercent = Self.resumedStartPercent(
            previousDrop: record.batteryDropPercent, currentPercent: batteryPercent)
        startedAt = record.startedAt
        checkpointURL = Self.newCheckpointURL(for: record.startedAt)
        lastPointAt = resumedAt
        finishedDuration = 0
        distanceMeters = record.distanceMeters
        maxSpeedKmh = record.maxSpeedKmh
        passed = record.passed
        if let raw = lastFinishedRaw, raw.id == record.id {
            trackBuffer = raw.track
            trackTimes = raw.times
        } else {
            trackBuffer = record.trackPoints
            trackTimes = Array(repeating: .nan, count: trackBuffer.count)
        }
        lastFinishedRaw = nil
        // Склейка: подробный трек первой ноги продолжается той же записью.
        timedBuffer = TimedTrackStore.load(tripID: record.id) ?? []
        odometer = TripOdometer(anchor: record.endCoordinate, at: record.endedAt)
        stops = (record.stops ?? []) + [
            TripStop(id: UUID(),
                     lat: record.endLat ?? record.trackPoints.last?.lat ?? 0,
                     lon: record.endLon ?? record.trackPoints.last?.lon ?? 0,
                     from: record.endedAt, to: resumedAt)
        ]
        persist()   // история уже без этой записи — не потерять её при вылете
        persistDays()
        let stopSeconds = Int(self.stops.last?.duration ?? 0)
        Log.trips.info("поездка продолжена: остановка \(stopSeconds, privacy: .public) с")
    }

    func update(coordinate: CLLocationCoordinate2D, speedKmh: Double, at time: Date = Date()) {
        // Вне поездки здесь делать нечего: хвост трека для схемы приборки
        // ушёл вместе со схемой (11.10), а дистанция, максимум и время точки
        // — наблюдаемые свойства, и их запись будила читателей каждый фикс
        // открытого приложения (аудит энергии 19.10).
        guard startedAt != nil else { return }
        // speedKmh == 0 — Standstill признал стоянку (на ходу сглаженная
        // скорость ровно нуля не даёт): опора стоит, дрожание не километры.
        let step = odometer.advance(to: coordinate, at: time, stopped: speedKmh == 0)
        if step > 0 { distanceMeters += step }
        maxSpeedKmh = max(maxSpeedKmh, speedKmh)
        lastPointAt = Date()
        if recordsTimedTrack {
            timedBuffer.append(TimedPoint(time: Date(), lat: coordinate.latitude,
                                          lon: coordinate.longitude, speedKmh: speedKmh))
        }

        // Трек: точка каждые ≥30 м (память копеечная, финальное сжатие при финише).
        let due = trackBuffer.last.map {
            GeoMath.fastDistance($0.lat, $0.lon, coordinate.latitude, coordinate.longitude)
                >= Self.trackStepMeters
        } ?? true
        if due {
            trackBuffer.append(TrackPoint(lat: coordinate.latitude,
                                          lon: coordinate.longitude, speedKmh: speedKmh))
            trackTimes.append(time.timeIntervalSince1970)
        }
        checkpointIfDue()
    }

    /// Зафиксировать прохождение камеры (скорость — в точке максимального сближения).
    func registerPass(camera: Camera, speedKmh: Double, limitKmh: Int?,
                      roadLimitKmh: Int? = nil, limitAssumed: Bool = false,
                      courseDegrees: Double? = nil, speedAfterKmh: Double? = nil,
                      silent: Bool = false, date: Date = Date()) {
        passed.append(PassedCamera(
            id: UUID(), cameraID: camera.id, typeRaw: camera.type,
            // Отметка водителей: её подпись — «исчезнет ~14:05», и в истории,
            // карточке «зона риска» и виджете она жила бы вечно (S6, 20.10).
            // Пусто, а не «тип»: «зона риска» группирует по месту, и одна
            // подпись на все отметки сложила бы город в одно «место» (ревью);
            // экраны без места показывают тип сами.
            location: camera.mobileConfirmed != nil ? "" : camera.displayTitle,
            speedKmh: speedKmh, date: date,
            lat: camera.lat, lon: camera.lon, limitKmh: limitKmh,
            // Сырой лимит храним, только если он отличается от итогового:
            // повторять одно и то же число в каждой записи истории незачем.
            roadLimitKmh: roadLimitKmh == limitKmh ? nil : roadLimitKmh,
            limitAssumed: limitAssumed ? true : nil,
            courseDegrees: courseDegrees, speedAfterKmh: speedAfterKmh,
            silent: silent ? true : nil
        ))
    }

    /// Сбросить поездку без записи в историю: пассажирский старт («я в такси»)
    /// не должен портить статистику и рейтинг.
    /// Вернуть запись, вынутую склейкой, на место — как была: в историю (по
    /// времени), в дневные итоги. «За всё время» её уже учитывает (финиш
    /// продолжения вносит только прибавку), трогать не надо.
    private func restoreResumedBase(_ base: TripRecord) {
        resumedFrom = nil
        let index = history.firstIndex { $0.startedAt < base.startedAt } ?? history.endIndex
        history.insert(base, at: index)
        days = TripDayBook.folded(base, into: days)
        persist()
        persistDays()
    }

    func cancel() {
        resumedFrom = nil
        startedAt = nil
        finishedDuration = 0
        distanceMeters = 0
        maxSpeedKmh = 0
        passed = []
        stops = []
        trackBuffer = []
        trackTimes = []
        startBatteryPercent = nil
        removeCheckpoint()
    }

    /// `endedManually` — нажали «Завершить» (а не автостоп по CoreMotion).
    /// Флаг едет в запись: он запрещает склейку следующей поездки (см. TripMerge).
    /// Поездки не стало, и вот почему. Строка едет в суточный отчёт счётчиком:
    /// `short`, `merged`, `notDriver`, `crashShort`.
    @ObservationIgnored var onTripDropped: ((String) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onTripDropped,
                                               "TripStats.onTripDropped") }
    }

    func noteDropped(_ reason: String) { onTripDropped?(reason) }

    func finish(endedManually: Bool = true, batteryPercent: Int? = nil) {
        finishedDuration = durationSeconds
        // Поездка завершена штатно — страховочный слепок больше не нужен.
        defer { startedAt = nil; startBatteryPercent = nil; resumedFrom = nil; removeCheckpoint() }
        // Молчаливых потерь не бывает.
        //
        // Порог в сто метров остаётся — иначе выезд из гаража станет записью и
        // испортит и средние, и дневные агрегаты. Но исчезать БЕЗ СЛЕДА
        // поездка не вправе: жалоба «одну поездку не засчитал» неразрешима,
        // пока в журнале нет ни строки (docs/plan_drive_complaints.md, Ж4).
        guard let startedAt else {
            Log.trips.notice("завершение без старта — записывать нечего")
            return
        }
        guard distanceMeters >= 100 else {
            Log.trips.notice("поездка не сохранена: \(Int(self.distanceMeters), privacy: .public) м, короче порога 100 м")
            noteDropped("short")
            // Продолжение, которое так и не стало поездкой, — прежняя запись
            // возвращается как была, а не пропадает (ревью S11).
            if let base = resumedFrom { restoreResumedBase(base) }
            return
        }
        // Рейтинг считаем по сырому треку (упрощённый теряет пики скорости).
        let scorePasses = passed.map { DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh) }
        let score = DrivingScore.tripScore(passes: scorePasses,
                                           trackSpeeds: trackBuffer.map(\.speedKmh))
        let record = TripRecord(
            id: startedAt.timeIntervalSince1970,
            startedAt: startedAt,
            endedAt: lastPointAt ?? Date(),
            distanceMeters: distanceMeters,
            maxSpeedKmh: maxSpeedKmh,
            passed: passed,
            endLat: lastCoordinate?.latitude,
            endLon: lastCoordinate?.longitude,
            track: Self.packTrack(Self.simplify(trackBuffer,
                                                tolerance: Self.trackTolerance,
                                                maxPoints: Self.trackMaxPoints)),
            score: score,
            stops: stops.isEmpty ? nil : stops,
            endedManually: endedManually,
            batteryDropPercent: Self.batteryDrop(startPercent: startBatteryPercent,
                                                 endPercent: batteryPercent),
            // Сырой буфер начинается со старта (после склейки — со старта
            // первой ноги): упрощённый трек вырежут через неделю, старт нет.
            startLat: trackBuffer.first?.lat,
            startLon: trackBuffer.first?.lon
        )
        history.insert(record, at: 0)
        history = TripHistory.pruned(history)
        // До чтения истории (старт до разблокировки): её вклад в «за всё
        // время» ляжет поверх прочитанного при загрузке.
        if !isLoaded { windowRecordIDs.insert(record.id) }
        lastSavedAt = Date()
        if trackTimes.count == trackBuffer.count {
            // Массивы уходят как есть (копия при записи — даром): склейку в
            // точки со временем делает получатель вне main и только для
            // поездки дом↔работа.
            lastFinishedRaw = (record.id, trackBuffer, trackTimes)
            onTrackFinished?(record, trackBuffer, trackTimes)
        } else {
            Log.trips.fault("время трека разошлось с треком: \(self.trackTimes.count, privacy: .public) против \(self.trackBuffer.count, privacy: .public)")
        }
        if !timedBuffer.isEmpty {
            let points = timedBuffer, id = record.id
            timedBuffer = []
            Task.detached(priority: .utility) { TimedTrackStore.save(points, tripID: id) }
        }
        // Дневной агрегат — до чистки истории по смыслу и после по коду:
        // запись может уехать из истории, день останется навсегда.
        days = TripDayBook.folded(record, into: days)
        if let base = resumedFrom {
            let basePasses = base.passed.map { DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh) }
            applyLifetime(.resumed(base: basePasses, all: scorePasses,
                                   distanceDelta: distanceMeters - base.distanceMeters))
            lastFinishWasContinuation = true
            lastFinishDistanceDelta = max(0, distanceMeters - base.distanceMeters)
        } else {
            applyLifetime(.trip(passes: scorePasses, distance: distanceMeters))
            lastFinishWasContinuation = false
            lastFinishDistanceDelta = distanceMeters
        }
        resumedFrom = nil
        persist()
        persistDays()
        persistLifetime()
        onTripFinished?()
    }

    /// «Я пассажир»: поездки за рулём не было — ни записи, ни проездов, ни
    /// баллов, при любой длине (сценарий S12, 20.10: после 500 м поездка такси
    /// сохранялась с превышениями таксиста в рейтинге и «штрафах»). Если это
    /// была склейка, прежняя нога — своя — возвращается как была, а не
    /// стирается вместе с чужой.
    func discardAsPassenger() {
        if let base = resumedFrom {
            cancel()
            restoreResumedBase(base)
            timedBuffer = []
            Log.trips.notice("пассажир: склейка отменена, прежняя поездка возвращена")
        } else {
            cancel()
            timedBuffer = []
        }
        noteDropped("passenger")
    }

    /// Разделить склеенную поездку по остановке («Разделить здесь» в деталке) —
    /// страховка, если автоматика склеила лишнее.
    func splitRecord(id: Double, at stop: TripStop) {
        guard editAllowed("разделение поездки"),
              let index = history.firstIndex(where: { $0.id == id }) else { return }
        let original = history[index]
        let legs = TripHistory.split(original, at: stop)
        guard legs.count == 2 else { return }
        history.replaceSubrange(index...index, with: legs)
        history = TripHistory.pruned(history)
        // В цифрах дня та же поездка, но двумя записями: снимаем исходную,
        // кладём обе ноги — иначе «поездок» в отчёте разойдётся со списком.
        days = TripDayBook.unfolded(original, from: days)
        for leg in legs { days = TripDayBook.folded(leg, into: days) }
        // Одна поездка стала двумя — и в «за всё время» (склейка вычитала).
        applyLifetime(.trips(max(0, legs.count - 1)))
        persist()
        persistDays()
        persistLifetime()
    }

    /// Можно ли объединить запись с предыдущей по времени (для меню и карточки-
    /// предложения в Итогах).
    func canMergeWithPrevious(id: Double) -> Bool {
        guard let index = history.firstIndex(where: { $0.id == id }),
              index + 1 < history.count else { return false }
        return TripMerge.manualMergeAllowed(previous: history[index + 1], next: history[index],
                                            maxMeters: AppConfig.tripManualMergeMaxMeters)
    }

    /// Объединить запись с предыдущей — ручная склейка там, где автоматика не
    /// имела права: ручное «Завершить» она не переигрывает никогда, а водитель
    /// жмёт стоп у магазина по привычке. Симметрия к splitRecord.
    func mergeWithPrevious(id: Double) {
        guard editAllowed("склейка поездок"),
              let index = history.firstIndex(where: { $0.id == id }),
              index + 1 < history.count else { return }
        let next = history[index], previous = history[index + 1]
        guard TripMerge.manualMergeAllowed(previous: previous, next: next,
                                           maxMeters: AppConfig.tripManualMergeMaxMeters) else { return }
        let merged = TripMerge.merged(previous: previous, next: next)
        // Дни: снять обе ноги, положить склейку — но только если строки обеих
        // на месте (смена пояса могла увести ключ; unfolded тогда промахнётся,
        // а folded добавит склейку целиком — день задвоится).
        let calendar = Calendar.current
        let keysPresent = [previous, next].allSatisfy { record in
            days.contains { $0.day == calendar.startOfDay(for: record.startedAt) }
        }
        if keysPresent {
            days = TripDayBook.unfolded(previous, from: days)
            days = TripDayBook.unfolded(next, from: days)
            days = TripDayBook.folded(merged, into: days)
            persistDays()
        }
        history.replaceSubrange(index...(index + 1), with: [merged])
        // Пожизненный счётчик: две записи стали одной поездкой. Серии чистых
        // поездок не пересчитываем — задним числом их уже не восстановить,
        // а километры и камеры от склейки не меняются.
        applyLifetime(.trips(-1))
        persist()
        persistLifetime()
        Log.trips.info("поездки объединены вручную: \(Int(merged.distanceMeters), privacy: .public) м")
    }

    /// Судьба штрафа проезда: ожидается / пришёл / не пришёл. Деньги
    /// переезжают между «возможными» и «пришедшими» во всех сводках — записи
    /// и дневном агрегате (хирургически, снять старую / положить новую).
    /// Рейтинг не трогается: он про езду, а не про почту.
    func setFineOutcome(_ outcome: PassedCamera.FineOutcome, passID: UUID, tripID: Double) {
        guard editAllowed("отметка штрафа"),
              let index = history.firstIndex(where: { $0.id == tripID }),
              let updated = TripHistory.settingFineOutcome(history[index], passID: passID,
                                                           outcome: outcome)
        else { return }
        let original = history[index]
        // Как в гео-чистке: день правим, только если его строка на месте —
        // смена часового пояса могла увести ключ, и folded без парного
        // unfolded задвоил бы поездку в агрегате.
        let key = Calendar.current.startOfDay(for: original.startedAt)
        if days.contains(where: { $0.day == key }) {
            days = TripDayBook.unfolded(original, from: days)
            days = TripDayBook.folded(updated, into: days)
            persistDays()
        }
        history[index] = updated
        persist()
    }

    /// Одноразовая чистка «мостовых» проездов: направление трека у камеры против
    /// оси её дороги (появилась в базе v8). Вызывается из onDatabaseLoaded
    /// CameraRepository — база декодируется асинхронно, и на момент сборки
    /// сервисов осей ещё нет (пустой словарь тут молча выключал миграцию).
    func axisCleanupIfNeeded(axisByID: [Int: Int]) {
        // isLoaded обязателен: чистка приходит из onDatabaseLoaded, а база
        // камер декодируется быстрее истории. На непрочитанной истории она
        // «ничего не нашла», ставила свой флаг — и больше не запускалась
        // никогда, оставив мостовые проезды в Итогах навсегда. Остальной файл
        // этот флаг уважает (persist, persistDays), а миграция — нет.
        guard isLoaded, isLifetimeTrusted, !Storage.bool(.passAxisCleanup1), !axisByID.isEmpty else { return }
        let before = history
        let (cleaned, changed) = TripHistory.axisSanitized(history, axisByID: axisByID)
        if changed {
            // Lifetime — хирургически, как в гео-чистке: rebuilt по обрезанной
            // истории стирал бы пожизненные счётчики.
            var removed: [DrivingScore.Pass] = []
            for (old, new) in zip(before, cleaned) where old.passed.count != new.passed.count {
                removed += old.passed
                    .filter { pass in !new.passed.contains { $0.id == pass.id } }
                    .map { DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh) }
            }
            history = cleaned
            lifetime = LifetimeStats.subtractingPasses(removed, from: lifetime)
            persist()
            persistLifetime()
            Log.trips.info("чистка мостовых проездов: история пересчитана")
        }
        Storage.set(true, for: .passAxisCleanup1)
    }

    /// Удаление записи убирает её и из дневных агрегатов: иначе поездка
    /// исчезает из списка, но продолжает жить в километрах и рейтинге отчёта.
    /// Правка истории до её чтения отклоняется: в памяти только поездки
    /// окна, и при загрузке диск лёг бы поверх правки (ревью S9, третий круг).
    /// Сбросить или заменить «за всё время» целиком — только когда ему
    /// верим: в недоверенном процессе в памяти лишь его вклад.
    private func lifetimeEditAllowed(_ what: String) -> Bool {
        guard isLifetimeTrusted else {
            Log.trips.error("\(what, privacy: .public): «за всё время» ещё не перенесено — отклонено")
            return false
        }
        return true
    }

    private func editAllowed(_ what: String) -> Bool {
        guard isLoaded else {
            Log.trips.error("\(what, privacy: .public): история ещё не прочитана — отклонено")
            return false
        }
        return true
    }

    func deleteRecord(id: Double) {
        guard editAllowed("удаление поездки") else { return }
        if let record = history.first(where: { $0.id == id }) {
            days = TripDayBook.unfolded(record, from: days)
            persistDays()
        }
        history.removeAll { $0.id == id }
        if lastFinishedRaw?.id == id { lastFinishedRaw = nil }
        persist()
        // Удалили поездку — и её посекундный трек (S10, 20.10).
        Task.detached(priority: .utility) { TimedTrackStore.remove(tripID: id) }
        onRecordsErased?([id])
    }

    /// Записи стёрты человеком (nil — вся история): производные данные —
    /// журнал и профиль дороги — обязаны забыть их тоже.
    @ObservationIgnored var onRecordsErased: ((Set<Double>?) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onRecordsErased,
                                               "TripStats.onRecordsErased") }
    }

    /// «Очистить историю» стирает и дневные агрегаты: пользователь просит
    /// убрать статистику, а не спрятать список при живых цифрах в отчёте. И
    /// «за всё время», охват предупреждений и посекундные треки: диалог
    /// обещает «итоги за все периоды сотрутся», а они оставались (S10, 20.10).
    func clearHistory() {
        // До чтения в памяти только поездки окна: «очистка» их и вернула бы
        // весь диск поверх при загрузке (ревью S9, третий круг).
        guard editAllowed("очистка истории"), lifetimeEditAllowed("очистка истории") else { return }
        history = []
        days = []
        lastFinishedRaw = nil
        lifetime = LifetimeStats()
        alertRecall = AlertRecall.Tally()
        persist()
        persistDays()
        persistLifetime()
        // Старые ключи — тоже: иначе стёртое вернулось бы через перенос.
        Storage.remove(.lifetimeStats)
        Storage.remove(.alertRecallTotal)
        Task.detached(priority: .utility) { TimedTrackStore.removeAll() }
        onRecordsErased?(nil)
    }

    // MARK: - Сводки
    //
    // Собственных агрегатов с зашитыми окнами здесь больше нет: рейтинг за
    // 30 дней, сводка за 7 и «месяц30» жили параллельно с PeriodSummary и
    // расходились с экраном (карточка показывала 85 за неделю, её же
    // расшифровка — 82 за 30 дней). Единственный способ посчитать —
    // TripHistory.summary(history, period:).

    /// Что показывать в шапке Итогов: живую сессию (nil) или последнюю поездку.
    func fallbackRecord(isTripActive: Bool) -> TripRecord? {
        TripHistory.fallbackRecord(history: history, isTripActive: isTripActive,
                                   liveDistance: distanceMeters)
    }

    #if DEBUG
    /// Демо-история для скриншотов и визуальной проверки отчёта на симуляторе:
    /// `simctl launch <app> -demoHistory -showStats -showReport`.
    /// ЗАМЕЩАЕТ историю — только под DEBUG и только по явному флагу запуска,
    /// в релизную сборку не попадает.
    /// `shiftDays` сдвигает всю демо-историю в прошлое — так проверяется состояние
    /// «поездки есть, но не в этом периоде» (открыл Итоги после недели без езды).
    /// `scale` — множитель километров для проверки вёрстки на НАСТОЯЩИХ числах.
    /// Обычное демо даёт 12,4 км и 130 км за всё время, и на таких цифрах экран
    /// выглядит компактнее, чем в жизни: четырёхзначные километры и разделитель
    /// разрядов вылезали из плиток уже у реальных водителей, а на демо — нет.
    func seedDemoHistory(shiftDays: Double = 0, scale: Double = 1) {
        let base = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
        let now = Date().addingTimeInterval(-shiftDays * 86400)

        /// Одна демо-поездка. `hour` задаёт время суток проезда камеры — от него
        /// зависит полоса «когда рискуете».
        func makeRecord(index: Int, daysAgo: Double, km: Double, seed: Int,
                        over: Bool, hour: Int, withStop: Bool = false) -> TripRecord {
            let day = Calendar.current.startOfDay(for: now.addingTimeInterval(-daysAgo * 86400))
            var start = day.addingTimeInterval(Double(hour) * 3600)
            // Заданный час мог оказаться позже «сейчас» (вечер ещё не наступил):
            // такая запись уезжает в будущее и в период не попадает — сдвигаем её
            // на сутки назад.
            if start > now { start.addTimeInterval(-86400) }
            let track = Self.demoTrack(from: base, seed: seed, km: km)
            // Камера стоит НА треке (примерно на 40% пути), а не в стороне от него.
            let camIndex = max(0, (track.count / 3) / 3 * 3)
            let cam = CLLocationCoordinate2D(latitude: track[camIndex],
                                             longitude: track[camIndex + 1])
            let pass = PassedCamera(id: UUID(), cameraID: 1000 + index,
                                    typeRaw: "Стационар радар",
                                    location: ["Юнусабад", "Чиланзар", "Мирзо-Улугбек"][index % 3],
                                    speedKmh: over ? 88 : 56,
                                    date: start.addingTimeInterval(400),
                                    lat: cam.latitude, lon: cam.longitude, limitKmh: 60)
            // Одна поездка с заездом по пути — проверить блок остановок.
            let stops: [TripStop]? = withStop ? [TripStop(
                id: UUID(), lat: base.latitude, lon: base.longitude,
                from: start.addingTimeInterval(900),
                to: start.addingTimeInterval(900 + 1500))] : nil
            // Балл считаем той же арифметикой, что у живых поездок: захардкоженный
            // рассыпался бы с разложением «из чего сложился балл» в деталке.
            let speeds = stride(from: 2, to: track.count, by: 3).map { track[$0] }
            let score = DrivingScore.tripScore(
                passes: [DrivingScore.Pass(speedKmh: pass.speedKmh, limitKmh: pass.limitKmh)],
                trackSpeeds: speeds)
            return TripRecord(
                id: start.timeIntervalSince1970, startedAt: start,
                endedAt: start.addingTimeInterval(km * 90 + (stops?.first?.duration ?? 0)),
                distanceMeters: km * 1000, maxSpeedKmh: over ? 104 : 82,
                passed: [pass], endLat: track[track.count - 3], endLon: track[track.count - 2],
                track: track, score: score, stops: stops, endedManually: true)
        }

        var seeded: [TripRecord] = []
        // Эта неделя: три поездки идут по одному «рабочему» коридору (общий seed) —
        // на карте видно градусы частоты, а не шесть равнозначных линий. Три
        // проезда с превышением дают зону риска и полосу часов.
        let week: [(daysAgo: Double, km: Double, seed: Int, over: Bool, hour: Int)] = [
            (0.2, 12.4, 1, true,  19), (1.1, 8.1,  1, false, 9),
            (2.3, 23.7, 2, false, 14), (3.0, 5.2,  3, true,  20),
            (4.5, 31.0, 1, false, 8),  (5.4, 14.8, 4, true,  18),
        ]
        for (index, item) in week.enumerated() {
            seeded.append(makeRecord(index: index, daysAgo: item.daysAgo,
                                     km: item.km * scale,
                                     seed: item.seed, over: item.over, hour: item.hour,
                                     withStop: index == 2))
        }
        // Прошлая неделя — база сравнения. Без неё «стало лучше/хуже», дельта
        // километров и движение рейтинга сравнивать не с чем, и половина разбора
        // периода на экране просто не появляется.
        let previous: [(daysAgo: Double, km: Double, seed: Int, over: Bool, hour: Int)] = [
            (8.3, 9.6, 1, true, 19), (9.6, 11.2, 1, true, 20),
            (11.2, 7.4, 2, true, 18), (12.7, 6.1, 3, false, 10),
        ]
        for (index, item) in previous.enumerated() {
            seeded.append(makeRecord(index: 6 + index, daysAgo: item.daysAgo,
                                     km: item.km * scale,
                                     seed: item.seed, over: item.over, hour: item.hour))
        }
        history = seeded
        #if DEBUG
        // Демо сеется раньше, чем дочитан диск: без флага загрузка складывала
        // его с прошлыми демо и копила дубли от запуска к запуску («Поездок:
        // 12», а в списке 13 — проверять цифры на таком демо нельзя).
        demoReplacesDisk = true
        #endif
        // Агрегаты пересобираем вместе с историей: иначе экран считает рейтинг
        // по дням от прошлого запуска, а разложение — по свежим записям.
        days = TripDayBook.rebuilt(from: history)
        lifetime = LifetimeStats.rebuilt(from: history)
        persist()
        persistDays()
        persistLifetime()
    }

    /// Дорога на работу и домой: четыре недели будней — утро с разным временем
    /// выезда (раньше выехал — быстрее доехал), вечер домой. Добавляется к
    /// истории, дом и работа выучиваются из неё же.
    /// `simctl launch <app> -demoHistory -demoCommutes -showStats`.
    /// Дом и работа демо-дороги — их же берёт демо-профиль пути (8.8.6).
    static let demoHome = CLLocationCoordinate2D(latitude: 41.2930, longitude: 69.2150)
    static let demoWork = CLLocationCoordinate2D(latitude: 41.3285, longitude: 69.3010)

    func seedDemoCommutes() {
        // Не там, где стартует остальная демо-история (41.3110, 69.2790): её
        // утренние выезды сделали бы «работу» домом, и дорога не выучилась бы.
        let home = Self.demoHome
        let work = Self.demoWork
        let calendar = Calendar.current
        let now = Date()
        func line(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> [Double] {
            (0...8).flatMap { k -> [Double] in
                let t = Double(k) / 8
                return [a.latitude + (b.latitude - a.latitude) * t,
                        a.longitude + (b.longitude - a.longitude) * t, 40]
            }
        }
        // (выезд ч, мин, минут в пути) — утро; вечер — свой список.
        let mornings: [(Int, Int, Double)] = [(8, 22, 55), (7, 46, 37), (8, 18, 49), (8, 31, 58),
                                              (7, 52, 39), (8, 20, 46), (8, 12, 44), (8, 25, 52),
                                              (7, 44, 36), (8, 19, 47), (8, 35, 57), (8, 21, 45),
                                              (7, 49, 38), (8, 16, 43), (8, 23, 50), (8, 27, 53)]
        let evenings: [(Int, Int, Double)] = [(18, 34, 41), (18, 12, 38), (19, 5, 33), (18, 40, 44),
                                              (18, 21, 40), (18, 55, 35), (18, 30, 42), (18, 48, 39)]
        var seeded: [TripRecord] = []
        var morning = 0, evening = 0
        for back in 0..<28 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now)),
                  !calendar.isDateInWeekend(day) else { continue }
            let m = mornings[morning % mornings.count]; morning += 1
            let start = day.addingTimeInterval(Double(m.0 * 3600 + m.1 * 60))
            if start.addingTimeInterval(m.2 * 60) < now {
                seeded.append(TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                                         endedAt: start.addingTimeInterval(m.2 * 60),
                                         distanceMeters: 11_800, maxSpeedKmh: 74, passed: [],
                                         endLat: work.latitude, endLon: work.longitude,
                                         track: line(home, work), score: 97, endedManually: true,
                                         startLat: home.latitude, startLon: home.longitude))
            }
            let e = evenings[evening % evenings.count]; evening += 1
            let back2 = day.addingTimeInterval(Double(e.0 * 3600 + e.1 * 60))
            if back2.addingTimeInterval(e.2 * 60) < now {
                seeded.append(TripRecord(id: back2.timeIntervalSince1970, startedAt: back2,
                                         endedAt: back2.addingTimeInterval(e.2 * 60),
                                         distanceMeters: 12_300, maxSpeedKmh: 70, passed: [],
                                         endLat: home.latitude, endLon: home.longitude,
                                         track: line(work, home), score: 99, endedManually: true,
                                         startLat: work.latitude, startLon: work.longitude))
            }
        }
        // Идемпотентно: экран может появиться не один раз, и каждый вызов
        // добавлял бы ещё четыре недели.
        let ids = Set(seeded.map(\.id))
        history = (history.filter { !ids.contains($0.id) } + seeded).sorted { $0.startedAt > $1.startedAt }
        days = TripDayBook.rebuilt(from: history)
        lifetime = LifetimeStats.rebuilt(from: history)
        persist()
        persistDays()
        persistLifetime()
    }

    /// Пара «разрезанная магазином поездка» для карточки «Объединить?» в Итогах:
    /// предыдущая завершена кнопкой, новая стартует там же через двадцать минут.
    /// `simctl launch <app> -demoHistory -demoMergePair -showStats`.
    func seedDemoMergePair() {
        let base = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
        let firstStart = Date().addingTimeInterval(-70 * 60)
        let firstTrack = Self.demoTrack(from: base, seed: 9, km: 6)
        let splitPoint = CLLocationCoordinate2D(latitude: firstTrack[firstTrack.count - 3],
                                                longitude: firstTrack[firstTrack.count - 2])
        let secondTrack = Self.demoTrack(from: splitPoint, seed: 4, km: 4)
        let first = TripRecord(id: firstStart.timeIntervalSince1970, startedAt: firstStart,
                               endedAt: firstStart.addingTimeInterval(25 * 60),
                               distanceMeters: 6000, maxSpeedKmh: 72, passed: [],
                               endLat: splitPoint.latitude, endLon: splitPoint.longitude,
                               track: firstTrack, score: 96, endedManually: true)
        let secondStart = firstStart.addingTimeInterval(45 * 60)
        let second = TripRecord(id: secondStart.timeIntervalSince1970, startedAt: secondStart,
                                endedAt: secondStart.addingTimeInterval(15 * 60),
                                distanceMeters: 4000, maxSpeedKmh: 64, passed: [],
                                endLat: secondTrack[secondTrack.count - 3],
                                endLon: secondTrack[secondTrack.count - 2],
                                track: secondTrack, score: 98, endedManually: false)
        history.insert(contentsOf: [second, first], at: 0)
        days = TripDayBook.rebuilt(from: history)
        lifetime = LifetimeStats.rebuilt(from: history)
        persist()
        persistDays()
        persistLifetime()
    }

    /// Демо-история для умной тишины: одна и та же камера у дома, пройденная
    /// спокойно много раз за месяц, — ровно тот случай, ради которого
    /// CameraFamiliarity и существует (проверка галочки на маркере и строки
    /// «своя камера» в панели без двух недель реальной езды).
    func seedDemoFamiliar(cameraID: Int, at coordinate: CLLocationCoordinate2D) {
        let base = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
        var seeded: [TripRecord] = []
        for index in 0..<(CameraFamiliarity.minPasses + 2) {
            let start = Date().addingTimeInterval(-Double(index + 1) * 86400)
            let pass = PassedCamera(id: UUID(), cameraID: cameraID,
                                    typeRaw: CameraType.stationaryRadar.sourceString,
                                    location: "", speedKmh: 52, date: start.addingTimeInterval(600),
                                    lat: coordinate.latitude, lon: coordinate.longitude,
                                    limitKmh: 60)
            seeded.append(TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                                     endedAt: start.addingTimeInterval(1500),
                                     distanceMeters: 8000, maxSpeedKmh: 58, passed: [pass],
                                     endLat: base.latitude, endLon: base.longitude,
                                     track: Self.demoTrack(from: base, seed: 1, km: 8),
                                     score: 100))
        }
        history = seeded
        days = TripDayBook.rebuilt(from: history)
        lifetime = LifetimeStats.rebuilt(from: history)
        persist()
        persistDays()
        persistLifetime()
    }

    /// Демо-трек: ломаная «по улицам» — мелкое петляние плюс поворот на каждом
    /// шестом шаге. Прямой луч из одной точки (как было раньше) на карте
    /// превращался в звезду, которой у живого пользователя не бывает.
    /// Одинаковый `seed` даёт одинаковую геометрию, поэтому короткая поездка —
    /// начало длинной: ровно так выглядит повторяющаяся дорога на работу.
    private static func demoTrack(from base: CLLocationCoordinate2D,
                                  seed: Int, km: Double) -> [Double] {
        let stepMeters = 500.0
        let steps = max(6, Int((km * 1000 / stepMeters).rounded()))
        var heading = Double(30 + seed * 47 % 300)
        var point = base
        var track: [Double] = [base.latitude, base.longitude, 30]
        for step in 1...steps {
            if step % 8 == 0 {
                heading += (step / 8) % 2 == 0 ? 70 : -76   // перекрёсток
            } else {
                heading += Double((step * 37 + seed * 13) % 7) - 3   // петляние
            }
            // Дальше 5 км от центра поездка разворачивается: 31 км по городу —
            // это много поворотов, а не прямая в область.
            if GeoMath.fastDistance(point.latitude, point.longitude,
                                    base.latitude, base.longitude) > 5000 {
                heading = GeoMath.bearing(from: point, to: base)
                    + Double((step * 17 + seed) % 40) - 20
            }
            point = GeoMath.destination(from: point, bearing: heading,
                                        distanceMeters: stepMeters)
            track += [point.latitude, point.longitude, 38 + Double(step % 7) * 9]
        }
        return track
    }
    #endif

    // MARK: - Заряд за поездку

    /// Дельта заряда поездки. Отрицательная (заряжались в пути) — nil: фиктивную
    /// «экономию» честнее не показывать вовсе. Ноль — валидный и лучший ответ:
    /// целая поездка не стоила ни процента.
    nonisolated static func batteryDrop(startPercent: Int?, endPercent: Int?) -> Int? {
        guard let startPercent, let endPercent, startPercent >= endPercent else { return nil }
        return startPercent - endPercent
    }

    /// Эквивалентный «заряд на старте» для склейки: текущий процент плюс расход
    /// первой ноги. Расход первой ноги неизвестен — вся дельта неизвестна:
    /// показать «−2 %» за поездку, стоившую пять, хуже, чем промолчать.
    nonisolated static func resumedStartPercent(previousDrop: Int?, currentPercent: Int?) -> Int? {
        guard let previousDrop, let currentPercent else { return nil }
        return currentPercent + previousDrop
    }

    // MARK: - Трек: упаковка и упрощение (Дуглас-Пекер)

    nonisolated static func packTrack(_ points: [TrackPoint]) -> [Double]? {
        guard points.count >= 2 else { return nil }
        var flat: [Double] = []
        flat.reserveCapacity(points.count * 3)
        for p in points {
            flat.append((p.lat * 1e5).rounded() / 1e5)
            flat.append((p.lon * 1e5).rounded() / 1e5)
            flat.append((p.speedKmh * 10).rounded() / 10)
        }
        return flat
    }

    /// Классический Дуглас-Пекер по (lat, lon); скорость сохраняется у оставленных точек.
    nonisolated static func simplify(_ points: [TrackPoint], tolerance: Double,
                                     maxPoints: Int) -> [TrackPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (lo, hi) = stack.popLast() {
            guard hi > lo + 1 else { continue }
            var worst = 0.0
            var worstIndex = lo
            for i in (lo + 1)..<hi {
                let d = perpendicular(points[i], points[lo], points[hi])
                if d > worst { worst = d; worstIndex = i }
            }
            if worst > tolerance {
                keep[worstIndex] = true
                stack.append((lo, worstIndex))
                stack.append((worstIndex, hi))
            }
        }
        var result = points.indices.filter { keep[$0] }.map { points[$0] }
        // Страховка от гигантских треков: равномерное прореживание до лимита.
        if result.count > maxPoints {
            let step = Double(result.count - 1) / Double(maxPoints - 1)
            result = (0..<maxPoints).map { result[Int((Double($0) * step).rounded())] }
        }
        return result
    }

    nonisolated private static func perpendicular(_ p: TrackPoint, _ a: TrackPoint, _ b: TrackPoint) -> Double {
        let dx = b.lon - a.lon, dy = b.lat - a.lat
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.lon - a.lon, p.lat - a.lat) }
        let t = max(0, min(1, ((p.lon - a.lon) * dx + (p.lat - a.lat) * dy) / len2))
        return hypot(p.lon - (a.lon + t * dx), p.lat - (a.lat + t * dy))
    }

    // MARK: - Хранение

    private var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("trips.json")
    }
    /// «За всё время» и охват — файлом рядом с историей (ревью S9, третий
    /// круг). До 20.10 они жили в UserDefaults, а процесс, поднятый до первой
    /// разблокировки, видит там пустоту, и кэш настроек, по сообщениям, может
    /// остаться пустым до конца процесса: запись поверх стёрла бы годы. У
    /// файла честное «не читается», и после разблокировки он читается в том
    /// же процессе. UserDefaults — только источник переноса.
    nonisolated struct LifetimeFile: Codable, Sendable {
        var lifetime: LifetimeStats
        var alertRecall: AlertRecall.Tally
        /// Метка журнала недоверенного процесса, уже слитого внутрь. Слияние и
        /// удаление файла журнала не атомарны вместе — по метке повторное
        /// чтение не кладёт тот же журнал второй раз (ревью S9).
        var mergedSession: String? = nil
    }

    /// Одна правка «за всё время» — строка журнала процесса, которому нельзя
    /// было верить UserDefaults. Журнал, а не «сумма с нуля»: проигранный
    /// поверх перенесённого теми же функциями, он даёт ровно то, что дала бы
    /// живая поездка, — серия через границу и рекорд не теряются (ревью S9).
    nonisolated enum LifetimeOp: Codable, Sendable {
        case trip(passes: [DrivingScore.Pass], distance: Double)
        case resumed(base: [DrivingScore.Pass], all: [DrivingScore.Pass], distanceDelta: Double)
        case trips(Int)
        case recall(AlertRecall.Tally)

        func applied(to file: LifetimeFile) -> LifetimeFile {
            var next = file
            switch self {
            case .trip(let passes, let distance):
                next.lifetime = LifetimeStats.updated(file.lifetime, passes: passes, distanceMeters: distance)
            case .resumed(let base, let all, let delta):
                next.lifetime = LifetimeStats.updatedResumed(file.lifetime, basePasses: base, allPasses: all,
                                                             distanceDelta: delta)
            case .trips(let change):
                next.lifetime.trips = max(0, file.lifetime.trips + change)
            case .recall(let tally):
                next.alertRecall = file.alertRecall + tally
            }
            return next
        }

        /// Правка поездок (их итог есть и в истории) — в отличие от охвата.
        var isTrip: Bool {
            if case .recall = self { return false }
            return true
        }
    }

    /// Журнал правок недоверенного процесса и его метка.
    nonisolated struct LifetimeSession: Codable, Sendable {
        var id: String
        var ops: [LifetimeOp]

        func replayed(onto file: LifetimeFile, tripsToo: Bool = true) -> LifetimeFile {
            var result = ops.filter { tripsToo || !$0.isTrip }.reduce(file) { $1.applied(to: $0) }
            result.mergedSession = id
            return result
        }
    }

    private var lifetimeURL: URL { Self.documents.appendingPathComponent("lifetime.json") }
    /// Вклад процесса, которому нельзя верить UserDefaults (старт до
    /// разблокировки, файла счётчиков ещё нет): копится отдельно и ложится
    /// поверх перенесённого из UserDefaults, когда они прочтутся (ревью S9).
    private var sessionURL: URL { Self.documents.appendingPathComponent("lifetime_session.json") }

    nonisolated private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Итог охвата за поездку. Копится, а не заменяется: одна поездка мимо
    /// трёх камер ничего не доказывает, вопрос «умно ли» решается на сотнях.
    func addAlertRecall(_ tally: AlertRecall.Tally) {
        // До чтения (старт до разблокировки) — отдельно: настоящий итог ещё
        // не прочитан, и при загрузке окно дольётся к нему один раз.
        guard isLoaded else {
            pendingRecall = pendingRecall + tally
            return
        }
        applyLifetime(.recall(tally))
        persistLifetime()
    }

    /// Охват, накопленный, пока хранилище не читалось (до первой разблокировки).
    @ObservationIgnored private var pendingRecall = AlertRecall.Tally()
    /// Первое чтение упёрлось в «не читается» — процесс подняли до первой
    /// разблокировки. Не сбрасывается: UserDefaults этого процесса не верим.
    @ObservationIgnored private var startedBlocked = false
    /// Поездки, закончившиеся до чтения истории: их вклад в «за всё время»
    /// ложится поверх прочитанного при загрузке.
    @ObservationIgnored private var windowRecordIDs: Set<Double> = []
    /// Счётчикам этого процесса можно верить. Нет (старт до разблокировки,
    /// файла ещё нет, UserDefaults пусты) — в памяти только вклад процесса:
    /// он пишется в lifetime_session.json, а «за всё время» не показывается.
    private(set) var isLifetimeTrusted = true
    /// Журнал правок, который копит этот недоверенный процесс.
    @ObservationIgnored private var session = LifetimeSession(id: UUID().uuidString, ops: [])
    /// Метка последнего слитого вклада — переписывается в каждый файл
    /// счётчиков, пока файл вклада может ещё лежать на диске.
    @ObservationIgnored private var lastMergedSession: String?
    /// Повтор чтения — с нарастающей паузой (30 с … 10 мин).
    @ObservationIgnored private var loadRetryDelay = AppConfig.storeRetrySeconds
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var isLoading = false
    /// Уже отложенные в этом процессе файлы: повтор чтения не копирует их снова.
    @ObservationIgnored private var asideDone: Set<URL> = []

    /// Хранилище пока не читается (до первой разблокировки после перезагрузки).
    var isLoadBlocked: Bool { startedBlocked && !isLoaded }

    /// Первое чтение не удалось — AppEnvironment не ждёт истории с автостартом.
    @ObservationIgnored var onLoadBlocked: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onLoadBlocked,
                                               "TripStats.onLoadBlocked") }
    }

    /// Разбор трёх файлов вне main — поэлементно, с честным ответом на «не
    /// читается» (сценарий S9, 20.10): см. JSONFile.LoadResult.
    @concurrent private nonisolated static func decodeStore(
        trips: URL, days: URL, lifetime: URL, session: URL
    ) async -> (trips: JSONFile.LoadResult<LossyArray<TripRecord>>, days: JSONFile.LoadResult<LossyArray<TripDay>>,
                lifetime: JSONFile.LoadResult<LifetimeFile>, session: JSONFile.LoadResult<LifetimeSession>) {
        (JSONFile.loadChecked(LossyArray<TripRecord>.self, from: trips, log: Log.trips),
         JSONFile.loadChecked(LossyArray<TripDay>.self, from: days, log: Log.trips),
         JSONFile.loadChecked(LifetimeFile.self, from: lifetime, log: Log.trips),
         JSONFile.loadChecked(LifetimeSession.self, from: session, log: Log.trips))
    }

    /// Разобрать ответ чтения: прочитанное, что сделать с файлом, и можно ли
    /// вообще считать файл загруженным (нечитаемый — нельзя: ни одной записи
    /// в него, пока не прочтём, иначе затрём).
    private enum Aside { case none, copy, move }

    private static func accept<T>(_ result: JSONFile.LoadResult<LossyArray<T>>)
        -> (values: [T], readable: Bool, aside: Aside) {
        switch result {
        case .missing:
            return ([], true, .none)
        case .loaded(let lossy):
            if lossy.dropped > 0 {
                Log.trips.fault("битых записей \(lossy.dropped, privacy: .public): \(lossy.firstError ?? "", privacy: .public)")
            }
            return (lossy.elements, true, lossy.dropped > 0 ? .copy : .none)
        case .corrupt:
            return ([], true, .move)
        case .unreadable:
            return ([], false, .none)
        }
    }

    /// Отложить файл; не вышло — считать нечитаемым: перезаписать битый
    /// оригинал, не сохранив копии, нельзя. Отложенный раз — не снова.
    private func setAside(_ aside: Aside, _ url: URL) -> Bool {
        guard aside != .none, !asideDone.contains(url) else { return true }
        let done = aside == .copy ? JSONFile.setAside(url, copy: true, log: Log.trips)
                                  : JSONFile.setAside(url, log: Log.trips)
        if done { asideDone.insert(url) }
        return done
    }

    #if DEBUG
    /// Демо замещает историю целиком — загрузка с диска её не трогает.
    @ObservationIgnored private var demoReplacesDisk = false
    #endif

    private func loadFromDisk() async {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let result = await Self.decodeStore(trips: storeURL, days: daysURL, lifetime: lifetimeURL,
                                            session: sessionURL)
        let tripsRead = Self.accept(result.trips)
        let daysRead = Self.accept(result.days)
        var lifetimeAside = Aside.none, sessionAside = Aside.none
        var lifetimeReadable = true
        switch result.lifetime {
        case .unreadable: lifetimeReadable = false
        case .corrupt: lifetimeAside = .move
        case .missing, .loaded: break
        }
        switch result.session {
        case .unreadable: lifetimeReadable = false
        case .corrupt: sessionAside = .move
        case .missing, .loaded: break
        }
        // Файл есть, но не читается (процесс подняли до первой разблокировки
        // после перезагрузки): загруженным не считаем — запись затёрла бы
        // историю пустым списком. Пробуем снова (пауза растёт до 10 мин, а
        // разблокировка зовёт retryLoadNow сразу); поездки, закончившиеся за
        // это время, встанут впереди прочитанного. Битое откладываем только
        // ПОСЛЕ этой проверки — и не вышло отложить — тоже «не читается».
        guard tripsRead.readable, daysRead.readable, lifetimeReadable,
              setAside(tripsRead.aside, storeURL), setAside(daysRead.aside, daysURL),
              setAside(lifetimeAside, lifetimeURL), setAside(sessionAside, sessionURL) else {
            scheduleRetry()
            return
        }
        retryTask?.cancel()
        retryTask = nil
        let decoded = (trips: tripsRead.values, days: daysRead.values)
        let rewrite = tripsRead.aside != .none || daysRead.aside != .none
        #if DEBUG
        // После чтения, а не до: демо сеется, пока файл читается.
        if demoReplacesDisk {
            isLoaded = true
            persist()
            persistDays()
            persistLifetime()
            finishLoading()
            onHistoryLoaded?()
            return
        }
        #endif
        // Всё, что в памяти до чтения, — поездки окна (правки истории до
        // чтения отклоняются): впереди прочитанного (история — от новых к
        // старым), и заново — в дневные сводки.
        let window = history
        history = window + decoded.trips
        if window.isEmpty {
            days = decoded.days
        } else {
            days = window.reduce(decoded.days) { TripDayBook.folded($1, into: $0) }
        }
        // «За всё время»: прочитанное (или перенесённое) плюс вклад поездок
        // окна — они легли на нули. Продолжение склейкой, идущее сейчас,
        // увезло свою первую ногу из истории: её вклад — тоже (ревью S9).
        var previousSession: LifetimeSession?
        if case .loaded(let value) = result.session { previousSession = value }
        var base = Self.lifetimeSource(result.lifetime, session: previousSession, legacy: Self.legacyLifetime(),
                                       decodedTrips: decoded.trips)
        if !base.trusted {
            isLifetimeTrusted = false
            // Журнал прошлого недоверенного процесса продолжается.
            if let previousSession { session = previousSession }
            Log.trips.fault("«за всё время»: старые счётчики неизвестны (до разблокировки) — копим журнал процесса")
        }
        // Вклад поездок окна (они легли на нули) и охвата окна — правками.
        var ops = Self.windowContributions(window: window, windowIDs: windowRecordIDs, resumed: resumedFrom)
            .map { LifetimeOp.trip(passes: $0.passed.map { DrivingScore.Pass(speedKmh: $0.speedKmh,
                                                                           limitKmh: $0.limitKmh) },
                                   distance: $0.distanceMeters) }
        if pendingRecall != AlertRecall.Tally() { ops.append(.recall(pendingRecall)) }
        base.file = ops.reduce(base.file) { $1.applied(to: $0) }
        if !base.trusted { session.ops += ops }
        lifetime = base.file.lifetime
        alertRecall = base.file.alertRecall
        lastMergedSession = base.file.mergedSession
        let lifetimeChanged = base.needsWrite || !ops.isEmpty
        pendingRecall = AlertRecall.Tally()
        windowRecordIDs = []
        isLoaded = true
        if !window.isEmpty || rewrite {
            // Битые записи отложены копией — переписать файл без них, иначе
            // копия откладывалась бы на каждом запуске.
            persist()
            persistDays()
        }
        if base.trusted, previousSession != nil {
            // Журнал прошлого недоверенного процесса уже внутри (или в
            // истории, если счётчики пересобраны): сначала файл счётчиков —
            // синхронно, с меткой, — потом удалить журнал (ревью S9).
            persistLifetime(wait: true)
            JSONFile.remove(at: sessionURL, log: Log.trips)
        } else if lifetimeChanged {
            persistLifetime()
        }
        // Файл счётчиков прочитан в процессе, которому верим: старые ключи
        // UserDefaults больше не источник — убрать, иначе стёртое («удалить
        // все поездки») вернулось бы через перенос (ревью S9).
        if case .loaded = result.lifetime, !startedBlocked {
            Storage.remove(.lifetimeStats)
            Storage.remove(.alertRecallTotal)
        }
        finishLoading()
        onHistoryLoaded?()
    }

    private func scheduleRetry() {
        if !startedBlocked {
            startedBlocked = true
            onLoadBlocked?()
        }
        let delay = loadRetryDelay
        loadRetryDelay = min(loadRetryDelay * 2, AppConfig.storeRetryMaxSeconds)
        Log.trips.notice("история не читается — повтор через \(Int(delay), privacy: .public) с")
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            await Task.pause(seconds: delay)
            guard !Task.isCancelled else { return }
            await self?.loadFromDisk()
        }
    }

    /// Данные стали доступны (разблокировка, возврат на экран) — читать
    /// сейчас, а не через паузу повтора: окно до 10 минут, в котором правки
    /// отклоняются, а итоги пусты (ревью S9, третий круг).
    func retryLoadNow() {
        guard startedBlocked, !isLoaded, !isLoading else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in await self?.loadFromDisk() }
    }

    /// Старые счётчики (до 20.10 они жили в UserDefaults) — для переноса.
    /// `known` — достоверно известно, есть ли запись: кэш настроек процесса,
    /// поднятого до разблокировки, может врать пустотой, поэтому при его
    /// «нет» читаем сам файл настроек с диска (он в нашей песочнице; новые
    /// версии эти ключи не пишут, только удаляют).
    nonisolated struct Legacy {
        var lifetime: LifetimeStats?
        var recall: AlertRecall.Tally?
        var known: Bool
    }

    private static func legacyLifetime() -> Legacy {
        let recall = Storage.decoded(AlertRecall.Tally.self, for: .alertRecallTotal)
        if let data = Storage.data(.lifetimeStats) {
            do {
                return Legacy(lifetime: try JSONDecoder().decode(LifetimeStats.self, from: data),
                              recall: recall, known: true)
            } catch {
                Log.trips.error("lifetimeStats не декодировались: \(error.localizedDescription, privacy: .public)")
                return Legacy(lifetime: nil, recall: recall, known: true)
            }
        }
        // Кэш говорит «нет» — проверить сам файл: он скажет правду или не
        // прочтётся (до разблокировки) — тогда «не знаем».
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let plist = library.appendingPathComponent("Preferences/\(Bundle.main.bundleIdentifier ?? "uz.radarmap.ios").plist")
        guard FileManager.default.fileExists(atPath: plist.path) else {
            return Legacy(lifetime: nil, recall: recall, known: true)
        }
        do {
            return legacyFromPlist(try Data(contentsOf: plist), recallFallback: recall)
        } catch {
            Log.trips.notice("файл настроек не читается — старые счётчики пока неизвестны")
            return Legacy(lifetime: nil, recall: recall, known: false)
        }
    }

    /// Разбор файла настроек. Чистая — покрыта тестами.
    nonisolated static func legacyFromPlist(_ data: Data, recallFallback: AlertRecall.Tally? = nil) -> Legacy {
        guard let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return Legacy(lifetime: nil, recall: recallFallback, known: false)
        }
        let lifetime = (dict[Storage.Key.lifetimeStats.rawValue] as? Data)
            .flatMap { try? JSONDecoder().decode(LifetimeStats.self, from: $0) }
        let recall = (dict[Storage.Key.alertRecallTotal.rawValue] as? Data)
            .flatMap { try? JSONDecoder().decode(AlertRecall.Tally.self, from: $0) } ?? recallFallback
        return Legacy(lifetime: lifetime, recall: recall, known: true)
    }

    /// Откуда «за всё время» при чтении (ревью S9). Чистая — покрыта
    /// тестами. `needsWrite` — записать взятое; `trusted == false` — старые
    /// счётчики неизвестны (старт до разблокировки, файла счётчиков нет, файл
    /// настроек не прочтён): в памяти и на диске тогда только журнал
    /// процесса, перенос — когда старые прочтутся. `session` — журнал
    /// прошлого такого процесса.
    nonisolated static func lifetimeSource(_ result: JSONFile.LoadResult<LifetimeFile>, session: LifetimeSession?,
                                           legacy: Legacy, decodedTrips: [TripRecord])
        -> (file: LifetimeFile, needsWrite: Bool, trusted: Bool) {
        let empty = LifetimeFile(lifetime: LifetimeStats(), alertRecall: AlertRecall.Tally())
        let recall = legacy.recall ?? AlertRecall.Tally()
        let untrusted = (file: session?.replayed(onto: empty) ?? empty, needsWrite: false, trusted: false)
        switch result {
        case .loaded(let file):
            guard let session, file.mergedSession != session.id else { return (file, false, true) }
            return (session.replayed(onto: file), true, true)
        case .corrupt:
            // Отложен; лучшее, что осталось, — максимум по полям из старой
            // записи (с журналом поверх) и пересборки по истории.
            guard legacy.lifetime != nil || legacy.known else { return untrusted }
            let rebuilt = LifetimeFile(lifetime: LifetimeStats.rebuilt(from: decodedTrips), alertRecall: recall)
            guard let old = legacy.lifetime else {
                let file = session?.replayed(onto: rebuilt, tripsToo: false) ?? rebuilt
                return (file, true, true)
            }
            let migrated = LifetimeFile(lifetime: old, alertRecall: recall)
            var file = session?.replayed(onto: migrated) ?? migrated
            file.lifetime = TripBackupMerge.maxed(file.lifetime, rebuilt.lifetime)
            return (file, true, true)
        case .missing, .unreadable:
            if let old = legacy.lifetime {
                let migrated = LifetimeFile(lifetime: old, alertRecall: recall)
                return (session?.replayed(onto: migrated) ?? migrated, true, true)
            }
            // Записи нет, но знаем ли мы это? Не знаем — ни нулей, ни
            // пересборки поверх (у человека, стёршего поездки, нули стёрли бы
            // годы).
            guard legacy.known else { return untrusted }
            // Свежая установка или версия без счётчиков — из истории (в ней и
            // поездки журнала; из журнала — только охват).
            let rebuilt = LifetimeFile(lifetime: decodedTrips.isEmpty ? LifetimeStats()
                                                                      : LifetimeStats.rebuilt(from: decodedTrips),
                                       alertRecall: recall)
            return (session?.replayed(onto: rebuilt, tripsToo: false) ?? rebuilt, true, true)
        }
    }

    /// Старые счётчики стали известны (разблокировка, возврат на экран) —
    /// перенести их и проиграть поверх журнал процесса.
    func retryLegacyLifetime() {
        guard isLoaded, !isLifetimeTrusted else { return }
        let legacy = Self.legacyLifetime()
        guard legacy.lifetime != nil || legacy.known else { return }
        let base = Self.lifetimeSource(.missing, session: session, legacy: legacy, decodedTrips: history)
        guard base.trusted else { return }
        lifetime = base.file.lifetime
        alertRecall = base.file.alertRecall
        lastMergedSession = base.file.mergedSession
        isLifetimeTrusted = true
        // Сначала файл счётчиков (синхронно, с меткой журнала), потом — убрать
        // журнал: упадём между ними — метка не даст проиграть его дважды.
        persistLifetime(wait: true)
        JSONFile.remove(at: sessionURL, log: Log.trips)
        Log.trips.notice("«за всё время»: старые счётчики прочлись — перенос с журналом процесса")
    }

    /// Поездки окна (закончились до чтения истории), чей вклад ложится
    /// поверх прочитанного, — по времени. Продолжение склейкой, идущее
    /// сейчас, увезло свою первую ногу из истории: её вклад — тоже, иначе
    /// финиш продолжения добавит только прибавку (ревью S9, третий круг).
    nonisolated static func windowContributions(window: [TripRecord], windowIDs: Set<Double>,
                                                resumed: TripRecord?) -> [TripRecord] {
        var result = window.filter { windowIDs.contains($0.id) }
        if let resumed, windowIDs.contains(resumed.id), !result.contains(where: { $0.id == resumed.id }) {
            result.append(resumed)
        }
        return result.sorted { $0.startedAt < $1.startedAt }
    }

    private func finishLoading() {
        // Обновились с версии без дневных агрегатов — собираем из того, что
        // ещё осталось в истории. Полнее уже не будет: удалённые записи не
        // воскресить, зато дальше история копится честно.
        if days.isEmpty && !history.isEmpty {
            days = TripDayBook.rebuilt(from: history)
            persistDays()
        }
        // Процесс умер в поездке (крэш/вотчдог/джетсэм)? Слепок → запись истории,
        // пока автозапуск не начал новую поездку. После lifetime: восстановление
        // добавляет к счётчикам, а не пересобирает их.
        restoreInflightIfAny()
        // Гео-чистка: старые версии засчитывали камеры с чужих улиц — выкидываем
        // их из истории и пересчитываем баллы и счётчики. Второй прогон нужен
        // из-за сужения порога (120 → 70 м): развязки первый прогон пропускал.
        // Чистки ставят флаги в UserDefaults — недоверенный процесс (кэш
        // настроек может быть пуст) их не трогает: пройдут в следующий раз.
        if isLifetimeTrusted, !Storage.bool(.passGeoCleanup2) {
            let before = history
            let (cleaned, changed) = TripHistory.sanitized(history)
            if changed {
                // Дневные агрегаты и lifetime правим ХИРУРГИЧЕСКИ, а не
                // пересборкой из истории: и то и другое переживает чистку
                // записей и хранит месяцы, для которых поездок уже нет.
                // rebuilt(from:) по обрезанной истории обнулял бы годовые
                // километры, экономию и достижения.
                var removed: [DrivingScore.Pass] = []
                for (old, new) in zip(before, cleaned) where old.passed.count != new.passed.count {
                    let gone = old.passed.filter { pass in
                        !new.passed.contains { $0.id == pass.id }
                    }
                    removed += gone.map {
                        DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh)
                    }
                    // Смена часового пояса могла увести день записи на другой
                    // ключ: unfolded тогда промахнётся и молча выйдет, а folded
                    // добавит день заново — поездка задвоится. Правим только
                    // если строка дня на месте.
                    let key = Calendar.current.startOfDay(for: old.startedAt)
                    if days.contains(where: { $0.day == key }) {
                        days = TripDayBook.unfolded(old, from: days)
                        days = TripDayBook.folded(new, into: days)
                    }
                }
                history = cleaned
                lifetime = LifetimeStats.subtractingPasses(removed, from: lifetime)
                persist()
                persistLifetime()
                persistDays()
            }
            Storage.set(true, for: .passGeoCleanup1)
            Storage.set(true, for: .passGeoCleanup2)
        }
        // Разовая чистка после S6 (S30): проезды мимо «Поста»/«ДТП» — долой
        // из истории, дней и «за всё время»; подписи отметок — пустые.
        if isLifetimeTrusted, !Storage.bool(.passCrowdCleanup1) {
            let before = history
            let (cleaned, removed, changed) = TripHistory.crowdCleaned(history)
            if changed {
                // Хирургически, как гео-чистка: агрегаты переживают обрезку
                // истории, пересборка из неё обнулила бы старые месяцы.
                for (old, new) in zip(before, cleaned) where old.passed.count != new.passed.count {
                    let key = Calendar.current.startOfDay(for: old.startedAt)
                    if days.contains(where: { $0.day == key }) {
                        days = TripDayBook.unfolded(old, from: days)
                        days = TripDayBook.folded(new, into: days)
                    }
                }
                history = cleaned
                lifetime = LifetimeStats.subtractingPasses(
                    removed.map { DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh) }, from: lifetime)
                persist()
                persistLifetime()
                persistDays()
                Log.trips.info("чистка отметок: снято проездов мимо поста/ДТП — \(removed.count, privacy: .public)")
            }
            Storage.set(true, for: .passCrowdCleanup1)
        }
        // Подъём лимитов до пола фиксации. Старые записи судились по тегу OSM
        // ниже 60 — в городе таких камер нет, и выставленные по ним штрафы и
        // снятые баллы были обвинением на пустом месте.
        if isLifetimeTrusted, !Storage.bool(.passLimitFloor1) {
            let before = history
            let (raised, changed) = TripHistory.limitFloored(history)
            if changed {
                // Всё хирургически, как в гео- и осевой чистках: агрегаты
                // переживают обрезку истории и хранят месяцы, для которых
                // поездок уже нет, — пересборка из истории их обнулила бы.
                for (old, new) in zip(before, raised) {
                    var lifetimeChanged = false
                    for (oldPass, newPass) in zip(old.passed, new.passed)
                    where oldPass.limitKmh != newPass.limitKmh {
                        lifetime = LifetimeStats.replacingPass(
                            DrivingScore.Pass(speedKmh: oldPass.speedKmh,
                                              limitKmh: oldPass.limitKmh),
                            with: DrivingScore.Pass(speedKmh: newPass.speedKmh,
                                                    limitKmh: newPass.limitKmh),
                            in: lifetime)
                        lifetimeChanged = true
                    }
                    guard lifetimeChanged else { continue }
                    // Строка дня могла уехать на другой ключ при смене
                    // часового пояса: unfolded тогда промахнётся, а folded
                    // добавит день заново и задвоит поездку.
                    let key = Calendar.current.startOfDay(for: old.startedAt)
                    if days.contains(where: { $0.day == key }) {
                        days = TripDayBook.unfolded(old, from: days)
                        days = TripDayBook.folded(new, into: days)
                    }
                }
                history = raised
                persist()
                persistLifetime()
                persistDays()
                Log.trips.info("подъём лимитов до пола фиксации: история пересчитана")
            }
            Storage.set(true, for: .passLimitFloor1)
        }
    }

    /// Влить восстановленное из копии. Слияние уже сделано чистым движком
    /// (TripBackupMerge) — здесь только присвоение и запись на диск.
    func applyRestored(history: [TripRecord], days: [TripDay], lifetime: LifetimeStats) {
        // Слияние шло с пустой памятью — при чтении диск лёг бы поверх ещё раз.
        guard editAllowed("восстановление из копии"),
              lifetimeEditAllowed("восстановление из копии") else { return }
        self.history = history
        self.days = days
        self.lifetime = lifetime
        persist()
        persistDays()
        persistLifetime()
    }

    // MARK: - Чекпоинт живой поездки

    /// Слепок незавершённой поездки на диске. Живая поездка держалась только в
    /// памяти — и любая смерть процесса (крэш, вотчдог, джетсэм фонового
    /// приложения) молча теряла весь накат: «проехал 30 км, зашёл — а там ноль».
    nonisolated struct InflightTrip: Codable {
        let startedAt: Date
        let lastPointAt: Date
        let distanceMeters: Double
        let maxSpeedKmh: Double
        let passed: [PassedCamera]
        let stops: [TripStop]
        /// Сырой трек плоским массивом [lat, lon, speed, …] — как в TripRecord.
        /// var: упрощается и пакуется уже вне главного потока (checkpointIfDue).
        var track: [Double]
        let endLat: Double?
        let endLon: Double?
        /// Продолжение склейкой: сколько было в первой ноге (её финиш уже
        /// внёс её в «за всё время»). Нет полей — старый слепок, не склейка.
        var baseDistance: Double? = nil
        var basePassCount: Int? = nil
    }

    /// Не чаще раза в checkpointInterval: слепок пишется на каждый интервал
    /// движения, а не на каждый GPS-тик.
    private static let checkpointInterval: TimeInterval = 20
    @ObservationIgnored private var lastCheckpointAt: Date = .distantPast

    /// Слепок этой поездки — свой файл на каждую (ревью S9, третий круг):
    /// поездка, начатая до разблокировки, не затирает и не удаляет слепок
    /// прошлого процесса, который ещё не прочитан. Хвост имени случайный:
    /// продолжение склейкой стартует с тем же временем начала.
    @ObservationIgnored private var checkpointURL: URL?

    private static func newCheckpointURL(for startedAt: Date) -> URL {
        documents.appendingPathComponent(
            "trip_inflight-\(Int(startedAt.timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json")
    }

    /// Имена слепков, которые этот процесс уже удалил: запоздавшая запись
    /// (упрощение трека идёт вне main) не воскрешает файл после финиша —
    /// иначе следующий запуск восстановил бы поездку второй раз (S14).
    nonisolated private static let finishedCheckpoints = OSAllocatedUnfairLock(initialState: Set<String>())

    private func checkpointIfDue() {
        guard let startedAt,
              Date().timeIntervalSince(lastCheckpointAt) >= Self.checkpointInterval else { return }
        lastCheckpointAt = Date()
        // В слепок — УПРОЩЁННЫЙ трек, как в finish(): сырой буфер за часовую
        // поездку — тысячи точек, и каждые 20 с паковались, кодировались и
        // писались ВСЕ (к концу часа ~90 КБ на запись, ~15 МБ во флеш за час,
        // синхронно в GPS-тике). После упрощения слепок снова «единицы
        // килобайт», а восстановлению большего и не нужно — finish() всё
        // равно упрощает.
        //
        // Упрощение, кодирование и запись — не в тике: буфер уходит значимой
        // копией, гонок нет, а потерянная запись не страшна — придёт
        // следующая. Дуглас—Пекер по всему сырому треку стоил на длинной
        // поездке 1–3 мс главного потока раз в 20 с (аудит 11.10).
        let raw = trackBuffer
        let head = InflightTrip(
            startedAt: startedAt, lastPointAt: lastPointAt ?? Date(),
            distanceMeters: distanceMeters, maxSpeedKmh: maxSpeedKmh,
            passed: passed, stops: stops, track: [],
            endLat: lastCoordinate?.latitude, endLon: lastCoordinate?.longitude,
            baseDistance: resumedFrom?.distanceMeters, basePassCount: resumedFrom?.passed.count)
        guard let url = checkpointURL else { return }
        Task.detached(priority: .utility) {
            var snapshot = head
            snapshot.track = Self.packTrack(Self.simplify(raw, tolerance: Self.trackTolerance,
                                                          maxPoints: Self.trackMaxPoints)) ?? []
            let ready = snapshot
            let name = url.lastPathComponent
            Self.finishedCheckpoints.withLock { finished in
                guard !finished.contains(name) else { return }
                _ = JSONFile.save(ready, to: url, log: Log.trips)
            }
        }
    }

    /// Удалить слепок ЭТОЙ поездки — чужие (прошлого процесса) не трогаем.
    private func removeCheckpoint() {
        lastCheckpointAt = .distantPast
        guard let url = checkpointURL else { return }
        checkpointURL = nil
        let name = url.lastPathComponent
        // Метка и удаление — сразу (файл крошечный): поездка, снятая «я
        // пассажир», не должна пережить смерть процесса слепком, а запоздавшая
        // запись слепка не воскресит его — она идёт под тем же замком.
        Self.finishedCheckpoints.withLock { finished in
            finished.insert(name)
            JSONFile.remove(at: url, log: Log.trips)
        }
    }

    /// Слепки на диске: по поездке и старый общий (до 20.10).
    private static func inflightFiles() -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("trip_inflight") && $0.pathExtension == "json"
                    // Отложенный битый — не слепок: иначе он откладывался бы
                    // снова на каждом чтении, а имя росло до предела.
                    && !$0.lastPathComponent.contains(".corrupt-") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            Log.trips.error("слепки поездок не перечислены: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Восстановление после смерти процесса: слепок превращается в обычную
    /// запись истории «поездка закончилась на последней точке». Следующий
    /// автозапуск пройдёт через TripMerge — короткая пауза склеится, и
    /// дистанция продолжится, как будто вылета не было.
    private func restoreInflightIfAny() {
        let finished = Self.finishedCheckpoints.withLock { $0 }
        for url in Self.inflightFiles() where url != checkpointURL && !finished.contains(url.lastPathComponent) {
            restoreInflight(at: url)
        }
    }

    private func restoreInflight(at url: URL) {
        let snapshot: InflightTrip
        switch JSONFile.loadChecked(InflightTrip.self, from: url, log: Log.trips) {
        case .loaded(let value):
            snapshot = value
        case .missing:
            return
        case .unreadable:
            Log.trips.notice("слепок поездки не читается — оставлен до следующего чтения")
            return
        case .corrupt:
            JSONFile.setAside(url, log: Log.trips)
            return
        }
        let id = snapshot.startedAt.timeIntervalSince1970
        let saved = history.first { $0.id == id }
        switch Self.inflightAction(snapshotStartedAt: snapshot.startedAt, snapshotLastPoint: snapshot.lastPointAt,
                                   isContinuation: snapshot.baseDistance != nil, liveStartedAt: startedAt,
                                   savedEndedAt: saved?.endedAt) {
        case .live:
            // Слепок ЖИВОЙ поездки (начатой, пока история ещё не читалась) —
            // не крэш: восстановить его значило бы получить её дважды.
            return
        case .duplicate:
            // Поездка уже в истории — слепок пережил штатный финиш (запись
            // после удаления, смерть процесса между ними): второй раз её не
            // вносить (S14).
            Log.trips.notice("слепок поездки уже в истории (слепок \(Int(snapshot.distanceMeters), privacy: .public) м) — не восстанавливаю")
            JSONFile.remove(at: url, log: Log.trips)
            return
        case .replace:
            // Продолжение склейкой, а в истории ещё её первая нога (запись
            // истории после склейки не успела лечь до смерти процесса): слепок
            // длиннее — он и есть поездка; первая нога в «за всё время» уже
            // внесена, ниже — только прибавка (updatedResumed). Только если
            // слепок сам годится в запись — иначе первая нога остаётся.
            guard let saved, Self.record(from: snapshot) != nil else {
                JSONFile.remove(at: url, log: Log.trips)
                return
            }
            if days.contains(where: { $0.day == Calendar.current.startOfDay(for: saved.startedAt) }) {
                days = TripDayBook.unfolded(saved, from: days)
            }
            history.removeAll { $0.id == id }
            Log.trips.notice("слепок продолжения длиннее записи — запись заменена")
        case .restore:
            break
        }
        defer { JSONFile.remove(at: url, log: Log.trips) }
        guard let record = Self.record(from: snapshot) else {
            Log.trips.notice("слепок незавершённой поездки короче 100 м — не восстановлен")
            noteDropped("crashShort")
            return
        }
        // По времени, а не первой: впереди могут быть поездки новее.
        let index = history.firstIndex { $0.startedAt < record.startedAt } ?? history.endIndex
        history.insert(record, at: index)
        history = TripHistory.pruned(history)
        days = TripDayBook.folded(record, into: days)
        let passes = record.passed.map { DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh) }
        if let baseDistance = snapshot.baseDistance, let basePassCount = snapshot.basePassCount {
            // Продолжение склейкой: первая нога уже внесена своим финишем —
            // только прибавка (S11 и на пути через крэш).
            applyLifetime(.resumed(base: Array(passes.prefix(basePassCount)), all: passes,
                                   distanceDelta: record.distanceMeters - baseDistance))
        } else {
            applyLifetime(.trip(passes: passes, distance: record.distanceMeters))
        }
        persist()
        persistDays()
        persistLifetime()
        Log.trips.info("восстановлена незавершённая поездка: \(Int(record.distanceMeters), privacy: .public) м")
    }

    nonisolated enum InflightAction: Equatable { case live, duplicate, replace, restore }

    /// Что делать со слепком при чтении. Чистая — покрыта тестами.
    /// `savedEndedAt` — конец записи с тем же id в истории (nil — нет такой).
    nonisolated static func inflightAction(snapshotStartedAt: Date, snapshotLastPoint: Date, isContinuation: Bool,
                                           liveStartedAt: Date?, savedEndedAt: Date?) -> InflightAction {
        if snapshotStartedAt == liveStartedAt { return .live }
        guard let savedEndedAt else { return .restore }
        // Слепок продолжения склейкой новее записи — запись это его первая нога.
        if isContinuation, snapshotLastPoint > savedEndedAt.addingTimeInterval(60) { return .replace }
        return .duplicate
    }

    /// Слепок → запись истории. Та же логика, что в finish(): порог 100 м,
    /// балл по сырому треку, упрощение Дугласом-Пекером. Чистая — покрыта тестами.
    nonisolated static func record(from snapshot: InflightTrip) -> TripRecord? {
        guard snapshot.distanceMeters >= 100 else { return nil }
        let raw = stride(from: 0, to: max(0, snapshot.track.count - 2), by: 3).map {
            TrackPoint(lat: snapshot.track[$0], lon: snapshot.track[$0 + 1],
                       speedKmh: snapshot.track[$0 + 2])
        }
        let score = DrivingScore.tripScore(
            passes: snapshot.passed.map { DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh) },
            trackSpeeds: raw.map(\.speedKmh))
        return TripRecord(
            id: snapshot.startedAt.timeIntervalSince1970,
            startedAt: snapshot.startedAt,
            endedAt: snapshot.lastPointAt,
            distanceMeters: snapshot.distanceMeters,
            maxSpeedKmh: snapshot.maxSpeedKmh,
            passed: snapshot.passed,
            endLat: snapshot.endLat, endLon: snapshot.endLon,
            track: packTrack(simplify(raw, tolerance: trackTolerance, maxPoints: trackMaxPoints)),
            score: score,
            stops: snapshot.stops.isEmpty ? nil : snapshot.stops,
            // Пользователь «Завершить» не нажимал — склейку не запрещаем.
            endedManually: false
        )
    }

    private var daysURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("trip_days.json")
    }

    private func persistDays() {
        guard isLoaded else {
            Log.trips.notice("дневные сводки не записаны: история ещё не прочитана")
            return
        }
        JSONFile.saveOrdered(days, to: daysURL, log: Log.trips, wait: mustWriteSynchronously())
    }

    /// `wait` — записать прямо сейчас: перед удалением журнала, который уже
    /// внутри файла счётчиков (иначе падение между ними его теряло).
    private func persistLifetime(wait: Bool = false) {
        // До загрузки «за всё время» в памяти — нули поверх нечитаемого: запись
        // затёрла бы годы километров (ревью S9).
        guard isLoaded else {
            Log.trips.notice("«за всё время» не записано: история ещё не прочитана")
            return
        }
        // Недоверенный процесс пишет только свой журнал — отдельным файлом.
        if isLifetimeTrusted {
            JSONFile.saveOrdered(LifetimeFile(lifetime: lifetime, alertRecall: alertRecall,
                                              mergedSession: lastMergedSession),
                                 to: lifetimeURL, log: Log.trips, wait: wait || mustWriteSynchronously())
        } else {
            JSONFile.saveOrdered(session, to: sessionURL, log: Log.trips, wait: wait || mustWriteSynchronously())
        }
    }

    /// Правка «за всё время» — одна дверь: в недоверенном процессе (старые
    /// счётчики неизвестны) она же ложится строкой в журнал.
    private func applyLifetime(_ op: LifetimeOp) {
        let next = op.applied(to: LifetimeFile(lifetime: lifetime, alertRecall: alertRecall))
        lifetime = next.lifetime
        alertRecall = next.alertRecall
        if isLoaded, !isLifetimeTrusted { session.ops.append(op) }
    }
    private func persist() {
        // См. isLoaded: пока история не приехала с диска, в файле лежит
        // правда, а в памяти — пусто; запись в этом окне была бы потерей.
        guard isLoaded else {
            Log.trips.notice("история не записана: ещё не прочитана")
            return
        }
        JSONFile.saveOrdered(history, to: storeURL, log: Log.trips, wait: mustWriteSynchronously())
    }

    /// Ждать ли записи на диск прямо в вызове. На переднем плане — нет:
    /// кодирование истории уходит с главного потока, и карточка конца поездки
    /// не дёргается. В фоне — да: приостановленное приложение не допишет
    /// очередь, а интерфейса там всё равно никто не видит. По умолчанию — да
    /// (безопасно); асинхронность включает AppEnvironment, знающий состояние
    /// приложения (модель UIKit не импортирует).
    @ObservationIgnored var mustWriteSynchronously: () -> Bool = { true }
}
