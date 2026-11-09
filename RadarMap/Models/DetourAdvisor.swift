//
//  DetourAdvisor.swift
//  RadarMap
//
//  Объезд пробки — когда искать, когда предлагать, что сказать.
//
//  Владелец, 12.10: «долго стою в пробке — должен предлагать другой
//  маршрут». Главная причина, по которой в Ташкенте держат Яндекс Навигатор.
//
//  Честность здесь важнее частоты. Набор пробок (TrafficSnapshot) несёт
//  только МЕДЛЕННЫЕ рёбра: «свободно» и «никто там не ехал» в нём неотличимы.
//  Поэтому:
//    * предлагать — только когда вариант быстрее на max(3 мин, 15 %
//      оставшегося времени по текущему пути) с учётом цены перестроения
//      (60 с), а время варианта посчитано по тем же пробкам: вариант через
//      ту же пробку выигрыша не даст и предложен не будет;
//    * искать — только когда такое предложение ДОСТИЖИМО: подтверждённая
//      данными задержка на НАШЕМ пути не меньше порога выигрыша + цены
//      перестроения. Текущий путь обычно быстрейший по графу, и объезд не
//      может выиграть больше, чем «задержка − цена»; поиск ниже этого —
//      три альтернативы OSRM каждые 3 минуты всей пробки впустую (симуляция
//      27.10, решение 28.10). Своя ползучая скорость порога не снижает: без
//      данных она не говорит, далеко ли тянется пробка, а с данными
//      достижимость та же — счёт «ползём» остался только в журнале;
//    * вариант, который почти повторяет текущий путь, — не объезд;
//    * после отказа — 10 минут тишины, не больше трёх предложений за маршрут.
//  Маршрут без нажатия водителя не меняется никогда.
//
//  Чистая логика, время — параметром; покрыто DetourAdvisorTests.
//

import CoreLocation
import Foundation

nonisolated enum DetourAdvisor {

    struct Candidate: Sendable {
        let points: [CLLocationCoordinate2D]
        /// Время до цели по варианту с пробками.
        let expectedTime: TimeInterval
        let steps: [RouteStep]
    }

    struct Offer: Equatable, Sendable {
        /// Сколько секунд выигрывает объезд (за вычетом цены перестроения).
        let saving: TimeInterval
        /// Индекс варианта в списке кандидатов.
        let index: Int
        /// Улица, которой объезд уходит от текущего пути; nil — не назвать.
        let via: String?
    }

    // MARK: - Когда искать

    /// Почему спрашиваем сейчас.
    enum Trigger: Equatable, Sendable {
        /// Очередной фикс поездки.
        case fix
        /// Приехал новый файл пробок: стоя фиксов может не быть минутами.
        case traffic
        /// Водитель открыл приложение или экран машины.
        case opened
    }

    /// Файл пробок, приехавший сразу после открытия, — то же открытие: приложение
    /// только что запросило его, а прежний мог быть несвежим.
    static func effective(_ trigger: Trigger, sinceOpened: TimeInterval?) -> Trigger {
        guard trigger == .traffic, let sinceOpened, sinceOpened < AppConfig.detourOpenedWindowSeconds else {
            return trigger
        }
        return .opened
    }

    /// - Parameters:
    ///   - delayAhead: подтверждённая живыми данными задержка на нашем пути впереди.
    ///   - currentRemaining: время до цели по текущему пути той же меркой, что
    ///     в `decide` (движок + живые пробки).
    ///   - sinceDecline: «Остаться» или показанное без ответа — тишина для всех.
    ///   - sinceUnseen: предложение так и не дошло до экрана. Голос десять минут
    ///     молчит, но открывший приложение водитель вправе увидеть выгоду.
    static func shouldSearch(remainingDistance: CLLocationDistance,
                             delayAhead: TimeInterval,
                             currentRemaining: TimeInterval,
                             sinceLastSearch: TimeInterval?,
                             sinceDecline: TimeInterval?,
                             offersOnRoute: Int,
                             sinceUnseen: TimeInterval? = nil,
                             trigger: Trigger = .fix) -> Bool {
        guard remainingDistance >= AppConfig.detourMinRemainingMeters,
              offersOnRoute < AppConfig.detourMaxOffersPerRoute else { return false }
        let interval = trigger == .opened ? AppConfig.detourOpenSearchIntervalSeconds
                                          : AppConfig.detourSearchIntervalSeconds
        if let sinceLastSearch, sinceLastSearch < interval { return false }
        if let sinceDecline, sinceDecline < AppConfig.detourDeclineQuietSeconds { return false }
        if trigger != .opened, let sinceUnseen, sinceUnseen < AppConfig.detourDeclineQuietSeconds { return false }
        return delayAhead >= searchTrigger(currentRemaining: currentRemaining)
    }

    /// Порог выигрыша объезда после цены перестроения: max(3 мин, 15 %
    /// оставшегося времени по текущему пути).
    static func neededSaving(currentRemaining: TimeInterval) -> TimeInterval {
        max(AppConfig.detourMinSavingSeconds, max(0, currentRemaining) * AppConfig.detourMinSavingShare)
    }

    /// С какой задержки впереди предложение вообще достижимо: объезд не
    /// выиграет больше задержки, а из выигрыша ещё вычтется цена перестроения.
    static func searchTrigger(currentRemaining: TimeInterval) -> TimeInterval {
        neededSaving(currentRemaining: currentRemaining) + AppConfig.detourSwitchCostSeconds
    }

    // MARK: - Что предлагать

    /// Лучший объезд или nil.
    /// - Parameters:
    ///   - currentRemaining: время до цели по текущему пути с пробками.
    ///   - current: точки текущего пути от машины до цели.
    static func decide(currentRemaining: TimeInterval, current: [CLLocationCoordinate2D],
                       candidates: [Candidate]) -> Offer? {
        let needed = neededSaving(currentRemaining: currentRemaining)
        var best: Offer?
        for (index, candidate) in candidates.enumerated() {
            guard candidate.points.count >= 2,
                  overlap(candidate.points, with: current) <= AppConfig.detourMaxOverlap else { continue }
            let saving = currentRemaining - candidate.expectedTime - AppConfig.detourSwitchCostSeconds
            guard saving >= needed, saving > (best?.saving ?? 0) else { continue }
            best = Offer(saving: saving, index: index,
                         via: street(leaving: current, along: candidate))
        }
        return best
    }

    /// Доля варианта (по точкам через ~`detourSampleMeters`), лежащая в
    /// `detourOverlapMeters` от текущего пути.
    static func overlap(_ path: [CLLocationCoordinate2D], with base: [CLLocationCoordinate2D]) -> Double {
        let samples = sample(path, every: AppConfig.detourSampleMeters)
        guard !samples.isEmpty, base.count >= 2 else { return 0 }
        let near = samples.filter { distance($0, to: base) <= AppConfig.detourOverlapMeters }.count
        return Double(near) / Double(samples.count)
    }

    /// Улица первого манёвра варианта после того места, где он ушёл с
    /// текущего пути: «Поверните направо на Шота Руставели» → «Шота Руставели».
    static func street(leaving base: [CLLocationCoordinate2D], along candidate: Candidate) -> String? {
        // Где вариант ушёл: первая точка дальше допуска от текущего пути.
        var travelled: CLLocationDistance = 0
        var divergence: CLLocationDistance?
        for (p, q) in zip(candidate.points, candidate.points.dropFirst()) {
            if distance(q, to: base) > AppConfig.detourOverlapMeters {
                divergence = travelled
                break
            }
            travelled += GeoMath.fastDistance(p.latitude, p.longitude, q.latitude, q.longitude)
        }
        guard let divergence else { return nil }
        let step = candidate.steps.first { $0.distanceAlong >= divergence - AppConfig.detourOverlapMeters * 2 }
        return step.flatMap(streetName(of:))
    }

    /// Улица из фразы манёвра: разница между полной фразой и фразой без улицы.
    static func streetName(of step: RouteStep) -> String? {
        guard let short = step.shortText, step.text.count > short.count else { return nil }
        var rest = step.text.dropFirst(short.count).trimmingCharacters(in: .whitespaces)
        for prefix in ["на ", "в ", "по ", "onto ", "on "] where rest.lowercased().hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
            break
        }
        return rest.isEmpty ? nil : rest
    }

    // MARK: - Стоим ли в пробке

    /// Сколько секунд машина ползёт (ниже `detourCrawlKmh`). Короткий рывок
    /// между стоянками (до `detourCrawlBurstSeconds` быстрее `detourFreeKmh`)
    /// ползание не прерывает — так и выглядит пробка. С 28.10 — только
    /// журнал поиска («ползём N с»): порог поиска от него не зависит.
    struct CrawlWatch: Equatable, Sendable {
        private var since: Date?
        private var fastSince: Date?

        mutating func update(speedKmh: Double, at now: Date) -> TimeInterval {
            let v = speedKmh.isFinite ? max(0, speedKmh) : 0
            if v < AppConfig.detourCrawlKmh {
                fastSince = nil
                if since == nil { since = now }
            } else if v >= AppConfig.detourFreeKmh {
                let fast = fastSince ?? now
                fastSince = fast
                if now.timeIntervalSince(fast) >= AppConfig.detourCrawlBurstSeconds { since = nil }
            }
            return since.map { now.timeIntervalSince($0) } ?? 0
        }

        mutating func reset() { self = CrawlWatch() }
    }

    // MARK: - Геометрия

    private static func sample(_ path: [CLLocationCoordinate2D], every step: Double) -> [CLLocationCoordinate2D] {
        guard let first = path.first else { return [] }
        var out = [first]
        var carry: Double = 0
        for (p, q) in zip(path, path.dropFirst()) {
            let length = GeoMath.fastDistance(p.latitude, p.longitude, q.latitude, q.longitude)
            guard length > 0 else { continue }
            var at = step - carry
            while at <= length {
                let t = at / length
                out.append(CLLocationCoordinate2D(latitude: p.latitude + (q.latitude - p.latitude) * t,
                                                  longitude: p.longitude + (q.longitude - p.longitude) * t))
                at += step
            }
            carry = length - (at - step)
        }
        return out
    }

    private static func distance(_ p: CLLocationCoordinate2D, to path: [CLLocationCoordinate2D]) -> Double {
        var best = Double.infinity
        for (a, b) in zip(path, path.dropFirst()) {
            best = min(best, TrafficSnapshot.distance(p, toSegment: a, b))
        }
        return best
    }
}
