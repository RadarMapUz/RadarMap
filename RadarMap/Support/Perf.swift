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
//  4. Интервалы `handleLocation`, `cameraLayer`, `sketchRefresh`,
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
        static let sketchRefresh: StaticString = "sketchRefresh"
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

#if DEBUG
/// Сторож подвисаний главного потока — ответ прибором на вопрос «не тормозит
/// ли»: фоновый поток раз в полсекунды просит main откликнуться, и отклик
/// дольше порога попадает в лог фолтом с длительностью. Кадр — 16 мс, порог
/// 250 мс — это уже видимый глазу фриз, а не дрожание планировщика.
///
/// Только DEBUG: в релизной сборке ни потока, ни пингов не существует.
/// Смотреть: log show --predicate 'subsystem == "uz.radarmap.ios"' | grep фриз
nonisolated enum HitchWatch {
    private static let pingEvery: TimeInterval = 0.5
    private static let threshold: TimeInterval = 0.25

    static func start() {
        Thread.detachNewThread {
            Thread.current.name = "HitchWatch"
            while true {
                let sem = DispatchSemaphore(value: 0)
                let sentAt = CFAbsoluteTimeGetCurrent()
                DispatchQueue.main.async { sem.signal() }
                _ = sem.wait(timeout: .now() + 5)
                let lag = CFAbsoluteTimeGetCurrent() - sentAt
                if lag > threshold {
                    Log.app.fault("фриз main \(Int(lag * 1000), privacy: .public) мс")
                }
                Thread.sleep(forTimeInterval: pingEvery)
            }
        }
    }
}
#endif
