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
    private(set) var maxSpeedKmh: Double = 0
    private(set) var distanceMeters: CLLocationDistance = 0
    private(set) var startedAt: Date?
    private(set) var lastPointAt: Date?
    /// Пройденные камеры текущей/последней поездки (со скоростью прохождения).
    private(set) var passed: [PassedCamera] = []
    /// Заезды по пути, склеенные в эту поездку (см. resume и TripMerge).
    private(set) var stops: [TripStop] = []

    /// Заряд на старте поездки, %: живая дельта на приборке и запись в историю.
    /// nil — заряд не читался (симулятор) или начало склейки неизвестно.
    private(set) var startBatteryPercent: Int?

    private(set) var history: [TripRecord] = []
    /// Дневные агрегаты — живут вечно, в отличие от записей (чистка режет треки
    /// через неделю и записи через 30 дней). По ним считается статистика за
    /// месяц и дальше, поэтому она не «худеет» вместе с историей.
    private(set) var days: [TripDay] = []
    /// Пожизненные счётчики — живут отдельно от истории (она обрезается до 50 поездок).
    private(set) var lifetime = LifetimeStats()
    /// Вызывается после сохранения поездки (AppEnvironment вешает сюда счётчики
    /// использования и недельный дайджест — одним замыканием, см. Wiring).
    @ObservationIgnored var onTripFinished: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onTripFinished,
                                               "TripStats.onTripFinished") }
    }

    @ObservationIgnored private var lastCoordinate: CLLocationCoordinate2D?
    /// Сырой трек текущей поездки: точка каждые ≥30 м, упрощается при финише.
    @ObservationIgnored private var trackBuffer: [TrackPoint] = []

    /// Хвост живого трека для схемы на приборке: откуда я приехал.
    /// Отдаём последние N точек, а не весь буфер: чертим двести метров вокруг
    /// себя, а поездка бывает на сотню километров.
    func recentTrack(limit: Int = 60) -> [CLLocationCoordinate2D] {
        trackBuffer.suffix(limit).map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }
    }
    // nonisolated: их читает и nonisolated-восстановление слепка (record(from:)).
    nonisolated private static let trackStepMeters = 30.0
    nonisolated private static let trackTolerance = 0.00022   // ~22 м — упрощение Дугласа-Пекера
    nonisolated private static let trackMaxPoints = 400

    init() { loadHistory() }

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
        lastCoordinate = nil
        passed = []
        stops = []
        trackBuffer = []
        finishedDuration = 0
        startBatteryPercent = batteryPercent
        startedAt = Date()
        lastPointAt = startedAt
    }

    /// Продолжить прошлую поездку вместо новой: запись вынимается из истории
    /// обратно в живую сессию, а пауза между ними становится остановкой.
    /// Так заезд в магазин остаётся одной поездкой (решает TripMerge).
    /// Трек поднимаем уже упрощённым — сырых точек прошлой ноги нет, и это
    /// нормально: следующее упрощение при финише всё равно прошло бы по ним.
    func resume(_ record: TripRecord, stoppedUntil resumedAt: Date = Date(),
                batteryPercent: Int? = nil) {
        history.removeAll { $0.id == record.id }
        // Запись возвращается в живую сессию — вычитаем её из дневного агрегата,
        // иначе после финиша склеенной поездки день посчитает её дважды.
        days = TripDayBook.unfolded(record, from: days)
        // Эквивалентный «заряд на старте»: текущий плюс расход первой ноги —
        // тогда финальная дельта честно суммирует обе ноги склейки.
        startBatteryPercent = Self.resumedStartPercent(
            previousDrop: record.batteryDropPercent, currentPercent: batteryPercent)
        startedAt = record.startedAt
        lastPointAt = resumedAt
        finishedDuration = 0
        distanceMeters = record.distanceMeters
        maxSpeedKmh = record.maxSpeedKmh
        passed = record.passed
        trackBuffer = record.trackPoints
        lastCoordinate = record.endCoordinate
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

    func update(coordinate: CLLocationCoordinate2D, speedKmh: Double) {
        if let last = lastCoordinate {
            // Тем же способом, что и весь пайплайн: HUD, гейты и запись проезда
            // обязаны сходиться в цифрах, а на масштабе одного тика (десятки
            // метров) разница с точной формулой — доли процента.
            let step = GeoMath.fastDistance(last.latitude, last.longitude,
                                            coordinate.latitude, coordinate.longitude)
            if step < 500 { distanceMeters += step }
        }
        lastCoordinate = coordinate
        maxSpeedKmh = max(maxSpeedKmh, speedKmh)
        lastPointAt = Date()

        // Трек: точка каждые ≥30 м (память копеечная, финальное сжатие при финише).
        if let last = trackBuffer.last {
            if GeoMath.fastDistance(last.lat, last.lon,
                                    coordinate.latitude, coordinate.longitude) >= Self.trackStepMeters {
                trackBuffer.append(TrackPoint(lat: coordinate.latitude,
                                              lon: coordinate.longitude, speedKmh: speedKmh))
            }
        } else {
            trackBuffer.append(TrackPoint(lat: coordinate.latitude,
                                          lon: coordinate.longitude, speedKmh: speedKmh))
        }
        // Вне поездки буфер нужен только схеме приборки (хвост «откуда
        // приехал», recentTrack ≤ 60 точек) — а рос он неограниченно: долгая
        // пассажирская сессия с открытым приложением надувала массив, который
        // никто не читал дальше хвоста.
        if startedAt == nil, trackBuffer.count > 120 {
            trackBuffer.removeFirst(trackBuffer.count - 120)
        }

        checkpointIfDue()
    }

    /// Зафиксировать прохождение камеры (скорость — в точке максимального сближения).
    func registerPass(camera: Camera, speedKmh: Double, limitKmh: Int?,
                      limitAssumed: Bool = false) {
        passed.append(PassedCamera(
            id: UUID(), cameraID: camera.id, typeRaw: camera.type,
            location: camera.displayTitle, speedKmh: speedKmh, date: Date(),
            lat: camera.lat, lon: camera.lon, limitKmh: limitKmh,
            limitAssumed: limitAssumed ? true : nil
        ))
    }

    /// Сбросить поездку без записи в историю: пассажирский старт («я в такси»)
    /// не должен портить статистику и рейтинг.
    func cancel() {
        startedAt = nil
        finishedDuration = 0
        distanceMeters = 0
        maxSpeedKmh = 0
        passed = []
        stops = []
        trackBuffer = []
        startBatteryPercent = nil
        removeCheckpoint()
    }

    /// `endedManually` — нажали «Завершить» (а не автостоп по CoreMotion).
    /// Флаг едет в запись: он запрещает склейку следующей поездки (см. TripMerge).
    func finish(endedManually: Bool = true, batteryPercent: Int? = nil) {
        finishedDuration = durationSeconds
        // Поездка завершена штатно — страховочный слепок больше не нужен.
        defer { startedAt = nil; startBatteryPercent = nil; removeCheckpoint() }
        guard let startedAt, distanceMeters >= 100 else { return }
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
                                                 endPercent: batteryPercent)
        )
        history.insert(record, at: 0)
        history = TripHistory.pruned(history)
        // Дневной агрегат — до чистки истории по смыслу и после по коду:
        // запись может уехать из истории, день останется навсегда.
        days = TripDayBook.folded(record, into: days)
        lifetime = LifetimeStats.updated(lifetime, passes: scorePasses, distanceMeters: distanceMeters)
        persist()
        persistDays()
        persistLifetime()
        onTripFinished?()
    }

    /// Разделить склеенную поездку по остановке («Разделить здесь» в деталке) —
    /// страховка, если автоматика склеила лишнее.
    func splitRecord(id: Double, at stop: TripStop) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        let original = history[index]
        let legs = TripHistory.split(original, at: stop)
        guard legs.count == 2 else { return }
        history.replaceSubrange(index...index, with: legs)
        history = TripHistory.pruned(history)
        // В цифрах дня та же поездка, но двумя записями: снимаем исходную,
        // кладём обе ноги — иначе «поездок» в отчёте разойдётся со списком.
        days = TripDayBook.unfolded(original, from: days)
        for leg in legs { days = TripDayBook.folded(leg, into: days) }
        persist()
        persistDays()
    }

    /// Можно ли объединить запись с предыдущей по времени (для меню и карточки-
    /// предложения в Итогах).
    func canMergeWithPrevious(id: Double) -> Bool {
        guard let index = history.firstIndex(where: { $0.id == id }),
              index + 1 < history.count else { return false }
        return TripMerge.manualMergeAllowed(previous: history[index + 1],
                                            next: history[index])
    }

    /// Объединить запись с предыдущей — ручная склейка там, где автоматика не
    /// имела права: ручное «Завершить» она не переигрывает никогда, а водитель
    /// жмёт стоп у магазина по привычке. Симметрия к splitRecord.
    func mergeWithPrevious(id: Double) {
        guard let index = history.firstIndex(where: { $0.id == id }),
              index + 1 < history.count else { return }
        let next = history[index], previous = history[index + 1]
        guard TripMerge.manualMergeAllowed(previous: previous, next: next) else { return }
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
        lifetime.trips = max(0, lifetime.trips - 1)
        persist()
        persistLifetime()
        Log.trips.info("поездки объединены вручную: \(Int(merged.distanceMeters), privacy: .public) м")
    }

    /// «Штраф не пришёл» (или передумал — вернуть): пометка на проезде камеры.
    /// Деньги уходят из всех сводок — записи и дневного агрегата (хирургически,
    /// снять старую / положить новую). Рейтинг не трогается: он про езду,
    /// а не про то, дошло ли постановление.
    func setFineDismissed(_ dismissed: Bool, passID: UUID, tripID: Double) {
        guard let index = history.firstIndex(where: { $0.id == tripID }),
              let updated = TripHistory.settingFineDismissed(history[index], passID: passID,
                                                             dismissed: dismissed)
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
        guard !Storage.bool(.passAxisCleanup1), !axisByID.isEmpty else { return }
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
    func deleteRecord(id: Double) {
        if let record = history.first(where: { $0.id == id }) {
            days = TripDayBook.unfolded(record, from: days)
            persistDays()
        }
        history.removeAll { $0.id == id }
        persist()
    }

    /// «Очистить историю» стирает и дневные агрегаты: пользователь просит
    /// убрать статистику, а не спрятать список при живых цифрах в отчёте.
    func clearHistory() {
        history = []
        days = []
        persist()
        persistDays()
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
    func seedDemoHistory(shiftDays: Double = 0) {
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
            seeded.append(makeRecord(index: index, daysAgo: item.daysAgo, km: item.km,
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
            seeded.append(makeRecord(index: 6 + index, daysAgo: item.daysAgo, km: item.km,
                                     seed: item.seed, over: item.over, hour: item.hour))
        }
        history = seeded
        // Агрегаты пересобираем вместе с историей: иначе экран считает рейтинг
        // по дням от прошлого запуска, а разложение — по свежим записям.
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
    private func loadHistory() {
        if let decoded = JSONFile.load([TripRecord].self, from: storeURL, log: Log.trips) {
            history = decoded
        }
        if let data = Storage.data(.lifetimeStats) {
            do {
                lifetime = try JSONDecoder().decode(LifetimeStats.self, from: data)
            } catch {
                // Не читается — ниже восстановим из истории (backfill).
                Log.trips.error("lifetimeStats не декодировались: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let decoded = JSONFile.load([TripDay].self, from: daysURL, log: Log.trips) {
            days = decoded
        }
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
        if !Storage.bool(.passGeoCleanup2) {
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
        // Обновились с версии без счётчиков, а поездки уже есть — восстанавливаем
        // из истории, чтобы экономия и достижения не начинались с нуля.
        if lifetime.trips == 0 && !history.isEmpty {
            lifetime = LifetimeStats.rebuilt(from: history)
            persistLifetime()
        }
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
        let track: [Double]
        let endLat: Double?
        let endLon: Double?
    }

    /// Не чаще раза в checkpointInterval: слепок пишется на каждый интервал
    /// движения, а не на каждый GPS-тик.
    private static let checkpointInterval: TimeInterval = 20
    @ObservationIgnored private var lastCheckpointAt: Date = .distantPast

    private var inflightURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("trip_inflight.json")
    }

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
        let snapshot = InflightTrip(
            startedAt: startedAt, lastPointAt: lastPointAt ?? Date(),
            distanceMeters: distanceMeters, maxSpeedKmh: maxSpeedKmh,
            passed: passed, stops: stops,
            track: Self.packTrack(Self.simplify(trackBuffer,
                                                tolerance: Self.trackTolerance,
                                                maxPoints: Self.trackMaxPoints)) ?? [],
            endLat: lastCoordinate?.latitude, endLon: lastCoordinate?.longitude)
        // Кодирование и атомарная запись — не в тике: слепок — значимая копия,
        // гонок с буфером нет, а потерянная запись не страшна — придёт следующая.
        let url = inflightURL
        Task.detached(priority: .utility) {
            JSONFile.save(snapshot, to: url, log: Log.trips)
        }
    }

    private func removeCheckpoint() {
        lastCheckpointAt = .distantPast
        // Отсутствие файла — норма (поездка без чекпоинта короче интервала).
        try? FileManager.default.removeItem(at: inflightURL)
    }

    /// Восстановление после смерти процесса: слепок превращается в обычную
    /// запись истории «поездка закончилась на последней точке». Следующий
    /// автозапуск пройдёт через TripMerge — короткая пауза склеится, и
    /// дистанция продолжится, как будто вылета не было.
    private func restoreInflightIfAny() {
        guard let snapshot = JSONFile.load(InflightTrip.self, from: inflightURL, log: Log.trips)
        else { return }
        defer { removeCheckpoint() }
        guard let record = Self.record(from: snapshot) else { return }
        history.insert(record, at: 0)
        history = TripHistory.pruned(history)
        days = TripDayBook.folded(record, into: days)
        lifetime = LifetimeStats.updated(
            lifetime,
            passes: record.passed.map { DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh) },
            distanceMeters: record.distanceMeters)
        persist()
        persistDays()
        persistLifetime()
        Log.trips.info("восстановлена незавершённая поездка: \(Int(record.distanceMeters), privacy: .public) м")
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
        JSONFile.save(days, to: daysURL, log: Log.trips)
    }

    private func persistLifetime() {
        do {
            Storage.set(try JSONEncoder().encode(lifetime), for: .lifetimeStats)
        } catch {
            Log.trips.error("lifetimeStats не сохранились: \(error.localizedDescription, privacy: .public)")
        }
    }
    private func persist() {
        JSONFile.save(history, to: storeURL, log: Log.trips)
    }
}
