//
//  Perf.swift
//  RadarMap
//
//  Замер горячих путей: signpost'ы для Instruments.
//
//  До этого файла в проекте не было НИ ОДНОГО измерения на устройстве.
//  `PerformanceBudgetTests` меряет чистые функции на симуляторе — это ловит
//  регресс в разы, но не отвечает ни на один вопрос про настоящую поездку:
//  сколько миллисекунд главный поток занят на GPS-тике, что именно пересобирает
//  экран, откуда берётся нагрев в держателе под солнцем. Всё это решалось
//  рассуждением, и рассуждение уже ошибалось: сортировка кандидатов в
//  `recomputeNearest` выглядела главным подозреваемым, а померили — 6 мкс.
//
//  Как пользоваться
//  ----------------
//  1. Xcode → Product → Profile (⌘I) → **Time Profiler** (или **SwiftUI**).
//  2. В окне Instruments добавить дорожку **os_signpost** и выбрать подсистему
//     `uz.radarmap.ios`, категорию `perf`.
//  3. Проехать маршрут в симуляторе (Features → Location → City Run) или
//     записать реальную поездку на устройстве.
//  4. Интервалы `handleLocation`, `cameraLayer`,
//     `ratingScreen`, `mapBody` покажут длительность каждого и их частоту.
//
//  Стоимость самого замера
//  -----------------------
//  `OSSignposter` при выключенном логировании стоит одну проверку флага, и
//  `signpostsEnabled` отсекает даже её. Тем не менее всё это включено ТОЛЬКО
//  в DEBUG: приборы нужны на стенде, а в кармане у водителя не нужен ни один
//  лишний вызов на пути, который ведёт к голосу о камере.
//

import Foundation
import os

nonisolated enum Perf {

    #if DEBUG
    /// Отдельная категория, чтобы дорожка приборов не тонула в прикладных логах.
    static let signposter = OSSignposter(subsystem: "uz.radarmap.ios", category: "perf")
    #endif

    /// Имена интервалов. Строки-литералы, а не вычисляемые: `OSSignposter`
    /// требует `StaticString`, и это же не даёт развести имена по опечатке.
    enum Name {
        static let handleLocation: StaticString = "handleLocation"
        static let cameraLayer: StaticString = "cameraLayer"
        static let ratingScreen: StaticString = "ratingScreen"
        static let mapBody: StaticString = "mapBody"
    }

    /// Замерить участок. В релизе — прямой вызов `body` без единой обёртки.
    ///
    /// `rethrows` и `@inline(__always)`, чтобы обёртка не меняла ни поведение
    /// вызывающего кода, ни его стек в том самом Time Profiler, ради которого
    /// она и написана.
    @inline(__always)
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        #if DEBUG
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
        #else
        return try body()
        #endif
    }

    /// То же для асинхронного участка (сборка слоя карты, разбор рейтинга).
    @inline(__always)
    static func measure<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        #if DEBUG
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try await body()
        #else
        return try await body()
        #endif
    }

    /// Замер функции, которую неудобно завернуть в замыкание: длинное тело с
    /// ранними возвратами, переписывать отступы у которого — шум в диффе там,
    /// где меняется только измерение.
    ///
    ///     let token = Perf.begin(Perf.Name.cameraLayer)
    ///     defer { token.end() }
    ///
    /// В релизе `Token` пуст, а `end()` не делает ничего.
    struct Token {
        #if DEBUG
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
        #endif

        @inline(__always)
        func end() {
            #if DEBUG
            Perf.signposter.endInterval(name, state)
            #endif
        }
    }

    @inline(__always)
    static func begin(_ name: StaticString) -> Token {
        #if DEBUG
        return Token(name: name, state: signposter.beginInterval(name))
        #else
        return Token()
        #endif
    }

    /// Мгновенное событие без длительности — «здесь пересобралось тело вью».
    /// У пересборки нет продолжительности, которую мы могли бы измерить
    /// изнутри; ценно её КОЛИЧЕСТВО, и оно на дорожке приборов видно сразу.
    @inline(__always)
    static func event(_ name: StaticString) {
        #if DEBUG
        signposter.emitEvent(name)
        #endif
    }
}

/// Что главный поток делал последним.
///
/// Сторож ниже умеет сказать «main стоял 3.2 секунды». Этого мало: он называет
/// болезнь, но не орган, и жалоба «экран машины стоит» уже пережила из-за этого
/// два билда. Метка превращает замер в «main стоял 3.2 секунды НА ГЕОЗОНАХ».
///
/// Цена — два взятия ненагруженного unfair-замка на участок, десятки
/// наносекунд. Это меньше, чем стоит одно чтение свойства CLLocationManager,
/// ради которого метка и ставится.
nonisolated enum MainWork {
    /// Главный поток не внутри наших горячих участков. Если фриз пойман здесь —
    /// он не в прикладном коде, а в системе (раскладка, MapKit, IPC шаблонов),
    /// и это тоже ответ.
    static let idle: StaticString = "вне горячего пути"

    private static let state = OSAllocatedUnfairLock(initialState: idle)

    @inline(__always)
    static func note(_ name: StaticString) {
        state.withLock { $0 = name }
    }

    /// Пометить участок на время его работы.
    ///
    /// `rethrows` и `@inline(__always)` — по той же причине, что у Perf.measure:
    /// обёртка не имеет права менять ни поведение вызывающего, ни его стек.
    @inline(__always)
    static func during<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        note(name)
        defer { note(idle) }
        return try body()
    }

    static var last: StaticString { state.withLock { $0 } }

    /// Имена участков — литералами, чтобы опечатка не развела их на два.
    enum Name {
        static let gpsTick: StaticString = "GPS-тик"
        static let geofences: StaticString = "геозоны"
        static let carButtons: StaticString = "кнопки CarPlay"
        static let carMap: StaticString = "карта CarPlay"
        static let carMarkers: StaticString = "маркеры CarPlay"
        static let voice: StaticString = "голос"
        static let beep: StaticString = "сигнал"
        static let haptic: StaticString = "хаптика"
    }
}

/// Сторож подвисаний главного потока — ответ прибором на вопрос «не тормозит
/// ли»: фоновый поток раз в полсекунды просит main откликнуться, и отклик
/// дольше порога попадает в лог фолтом с длительностью и последней меткой
/// MainWork. Кадр — 16 мс, порог 250 мс — это уже видимый глазу фриз, а не
/// дрожание планировщика.
///
/// Раньше сторож существовал только в DEBUG, и это была ошибка: экран машины
/// видит только TestFlight, то есть релиз, — под единственную жалобу, которую
/// нельзя воспроизвести за столом, прибора не было вовсе. Теперь в DEBUG он
/// стоит всегда, а в релизе его поднимает сцена CarPlay на время сессии.
/// Цена — один dispatch_async в полсекунды, пока водитель в машине.
///
/// Смотреть: log show --predicate 'subsystem == "uz.radarmap.ios"' | grep фриз
nonisolated enum HitchWatch {
    private static let pingEvery: TimeInterval = 0.5
    /// Пока экран машины не наш (музыка, чужой навигатор) фризы не считаются
    /// — и будить main дважды в секунду незачем: шаг реже, лог остаётся
    /// (аудит энергии 19.10: 7 200 пробуждений в час на всю сессию машины).
    private static let idlePingEvery: TimeInterval = 3
    private static let threshold: TimeInterval = 0.25
    /// Ждём отклика долго: обрывать ожидание на пяти секундах значило бы
    /// записывать любой длинный фриз пятисекундным и потерять его настоящий
    /// размер — а размер здесь и есть главная улика.
    private static let giveUpAfter: TimeInterval = 30

    /// Поколение сторожа: `start` заводит новое, `stop` его гасит. Поток
    /// живёт, пока его поколение текущее, — так быстрые «стоп-старт» при
    /// моргании провода не оставляют двух потоков.
    private nonisolated struct State: Sendable { var running = false; var generation = 0 }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Сколько фризов было с последнего `drain()`: всего (> 250 мс), длинных
    /// (> 1 с — экран машины «стоит») и самый долгий. Лог читается только с
    /// телефона в руках, а жалоба «км/ч не работает» приходит из машины —
    /// эти три числа уходят в суточную статистику (поле `carPlay`).
    nonisolated struct Tally: Equatable, Sendable {
        var count = 0
        var long = 0
        var maxMilliseconds = 0
    }

    private static let tally = OSAllocatedUnfairLock(initialState: Tally())
    /// Считать ли фризы в итог сессии. Сторож тикает и в фоне, но приложение
    /// там могут приостановить, и пауза процесса по настенным часам выглядела
    /// бы фризом до 30 с. Считаем только пока экран машины наш.
    private static let counting = OSAllocatedUnfairLock(initialState: false)

    static func setCounting(_ on: Bool) {
        counting.withLock { $0 = on }
        // Экран машины стал нашим — разбудить сторож из редкого шага сразу:
        // фриз пересборки карты на входе — ровно то, что считаем.
        if on { wake.signal() }
    }
    /// Будильник сна между пингами (вместо Thread.sleep).
    private static let wake = DispatchSemaphore(value: 0)

    /// Забрать накопленное и обнулить.
    static func drain() -> Tally {
        tally.withLock { current in
            defer { current = Tally() }
            return current
        }
    }

    static func record(lagMilliseconds: Int) {
        tally.withLock { current in
            current.count += 1
            if lagMilliseconds >= 1000 { current.long += 1 }
            current.maxMilliseconds = max(current.maxMilliseconds, lagMilliseconds)
        }
    }

    /// Идемпотентен: сцена CarPlay может подключиться дважды за процесс
    /// (штатное «моргание» провода при запуске двигателя), а второй сторож
    /// удвоил бы пинги и не сказал ничего нового.
    static func start() {
        let generation: Int? = state.withLock { current in
            guard !current.running else { return nil }
            current.running = true
            current.generation += 1
            return current.generation
        }
        guard let generation else { return }

        Thread.detachNewThread {
            Thread.current.name = "HitchWatch"
            while state.withLock({ $0.running && $0.generation == generation }) {
                let sem = DispatchSemaphore(value: 0)
                let sentAt = CFAbsoluteTimeGetCurrent()
                DispatchQueue.main.async { sem.signal() }
                _ = sem.wait(timeout: .now() + giveUpAfter)
                let lag = CFAbsoluteTimeGetCurrent() - sentAt
                if lag > threshold {
                    if counting.withLock({ $0 }) { record(lagMilliseconds: Int(lag * 1000)) }
                    let stage = MainWork.last.description
                    Log.app.fault("фриз main \(Int(lag * 1000), privacy: .public) мс на «\(stage, privacy: .public)»")
                }
                _ = wake.wait(timeout: .now() + (counting.withLock({ $0 }) ? pingEvery : idlePingEvery))
            }
        }
    }

    /// Погасить сторож. Раньше он жил до смерти процесса: подключили машину
    /// один раз — и пинг главного потока раз в полсекунды шёл часами, в том
    /// числе в фоновых поездках без машины (~7 200 пробуждений в час, аудит
    /// 11.10). Поток выходит на следующем витке.
    static func stop() {
        state.withLock { $0.running = false }
    }
}
