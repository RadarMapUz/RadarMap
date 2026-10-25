//
//  StopView.swift
//  RadarMap
//
//  «Вид на остановке» (29.D, владелец 25.10: «при остановке показать нужные
//  детали… умный»). На ходу карта показывает дорогу по скорости
//  (DriveCamera), а встали — водитель может посмотреть, и карта показывает
//  то, ради чего стоим:
//    * развилка маршрута ближе `stopViewManeuverMeters` — целиком в кадре.
//      Стоя окно подъезда было 150 м, телефон видел 134 м (SE — 92, машина —
//      105): поворот в 200 м от светофора был за краем экрана;
//    * иначе — пробка на маршруте до её конца (машина в ней или она вот-вот);
//    * иначе — перекрёсток, светофор и переход впереди (обзор 180/140 м),
//      не мельче полос;
//    * значки заведений (в поездке они скрыты всегда) — телефон, вне тревоги.
//
//  Гистерезис: встали — это `stopViewEnterSeconds` подряд не быстрее
//  `stopViewEnterKmh` (пауза в 2 с ничего не меняет); тронулись — проехали
//  `stopViewExitMeters` без новой остановки или разогнались до
//  `stopViewExitKmh` (рывки пробки по 10–20 м — всё ещё «стоим»); снова
//  встать — не раньше `stopViewReenterSeconds` после старта. Развилка, взятая в кадр
//  стоя, держится и после старта, пока едем к ней же: кадр продолжает
//  подъезд в ту же сторону, а не отъезжает назад к «я», чтобы через пару
//  секунд снова потянуться к повороту.
//
//  Только картинка: ни оповещения, ни гейты, ни маршрут отсюда не читают.
//  Чистая логика, время — параметром; покрыто StopViewTests.
//

import CoreLocation
import Foundation

nonisolated enum StopView {

    /// Что знает кадр о состоянии «стоим».
    struct State: Equatable, Sendable {
        /// Стоим (с гистерезисом).
        var standing = false
        /// Окно развилки остановки, м: стоим или едем к развилке, взятой стоя.
        var maneuverWindow: Double?

        static let moving = State()
    }

    /// Гистерезис «стоим» и удержание развилки.
    struct Tracker: Equatable, Sendable {
        private(set) var standing = false
        private var slowSince: Date?
        private var leftAt: Date?
        private var lastAt: Date?
        /// Сколько проехали с последней настоящей остановки, м.
        private var moved = 0.0
        /// Расстояние до развилки, взятой в кадр стоя (наименьшее за подъезд).
        private var held: Double?

        /// - Parameters:
        ///   - maneuverDistance: метров по маршруту до ближайшей развилки, nil — нет.
        ///   - active: поездка идёт (вне поездки — обзор города, вид не нужен).
        @discardableResult
        mutating func update(speedKmh: Double, maneuverDistance: Double?, active: Bool,
                             at now: Date) -> State {
            guard active else {
                self = Tracker()
                return .moving
            }
            let speed = speedKmh.isFinite ? max(0, speedKmh) : 0
            let dt = lastAt.map { min(AppConfig.stopViewMaxStepSeconds, max(0, now.timeIntervalSince($0))) } ?? 0
            lastAt = now
            if standing {
                // Стоим снова (≤ порога входа) — счёт пути сначала: рывки
                // пробки по 10–20 м не складываются в «тронулись».
                moved = speed <= AppConfig.stopViewEnterKmh ? 0 : moved + speed / 3.6 * dt
                if speed >= AppConfig.stopViewExitKmh || moved >= AppConfig.stopViewExitMeters {
                    standing = false
                    leftAt = now
                    slowSince = nil
                    moved = 0
                }
            } else if speed <= AppConfig.stopViewEnterKmh {
                let since = slowSince ?? now
                slowSince = since
                let rested = leftAt.map { now.timeIntervalSince($0) >= AppConfig.stopViewReenterSeconds } ?? true
                if now.timeIntervalSince(since) >= AppConfig.stopViewEnterSeconds, rested {
                    standing = true
                }
            } else {
                slowSince = nil
            }

            // Развилка: стоя ближе окна — взять; дальше держать, пока
            // расстояние до неё убывает (рост — значит, это уже следующая).
            let d = maneuverDistance.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            if let d, let last = held, d <= last + AppConfig.stopViewManeuverRiseMeters {
                held = min(last, d)
            } else {
                held = nil
            }
            if standing, let d, d <= AppConfig.stopViewManeuverMeters {
                held = min(held ?? d, d)
            }
            let window = standing || held != nil ? AppConfig.stopViewManeuverMeters : nil
            return State(standing: standing, maneuverWindow: window)
        }
    }

    // MARK: - Пробка

    /// Где кончается пробка на пути вперёд, м — если машина в ней или она
    /// начинается не дальше `stopViewJamStartMeters` и тянется не меньше
    /// `stopViewJamMinMeters`. Путь проходится шагом `RouteTraffic.stepMeters`
    /// (как у линии маршрута), `level(точка, курс)` — уровень ребра пробок
    /// (2 — медленно, 3 — стоим), nil — данных нет. Разрыв короче
    /// `stopViewJamGapMeters` пробку не делит. Пробка до конца пути — длина пути.
    static func jamEnd(path: [CLLocationCoordinate2D],
                       level: (CLLocationCoordinate2D, Double) -> Int?) -> Double? {
        guard path.count >= 2 else { return nil }
        let step = RouteTraffic.stepMeters
        var walked = 0.0
        var start: Double?
        var end = 0.0
        for (p, q) in zip(path, path.dropFirst()) {
            let length = GeoMath.fastDistance(p.latitude, p.longitude, q.latitude, q.longitude)
            guard length > 0.5 else { continue }
            let course = GeoMath.bearing(from: p, to: q)
            let steps = max(1, Int((length / step).rounded(.up)))
            for s in 0..<steps {
                let t0 = Double(s) / Double(steps), t1 = Double(s + 1) / Double(steps)
                let mid = CLLocationCoordinate2D(latitude: p.latitude + (q.latitude - p.latitude) * (t0 + t1) / 2,
                                                 longitude: p.longitude + (q.longitude - p.longitude) * (t0 + t1) / 2)
                let from = walked + length * t0, to = walked + length * t1
                let slow = (level(mid, course) ?? 0) >= 2
                if slow {
                    if start == nil {
                        guard from <= AppConfig.stopViewJamStartMeters else { return nil }
                        start = from
                    }
                    end = to
                } else if let start {
                    if from - end >= AppConfig.stopViewJamGapMeters {
                        return end - start >= AppConfig.stopViewJamMinMeters ? end : nil
                    }
                } else if from > AppConfig.stopViewJamStartMeters {
                    return nil
                }
            }
            walked += length
        }
        guard let start, end - start >= AppConfig.stopViewJamMinMeters else { return nil }
        return end
    }

    // MARK: - Детали

    /// Единственное решение «что из заведений показать стоя» — одна точка
    /// для карты телефона (MapBaseLayers) и для будущей общей политики
    /// видимости слоёв: пусто — как на ходу.
    static func shownLayers(state: State, tripActive: Bool, places: Bool, covered: Bool,
                            performance: PerformanceMode) -> [String] {
        showsDetail(state: state, tripActive: tripActive, places: places, covered: covered,
                    performance: performance) ? detailLayers : []
    }

    /// Значки заведений, которые стоя возвращаются на карту телефона: в
    /// поездке они скрыты всегда (EngineModernStyle.hiddenWhileDriving).
    /// Только самые заметные (`poi-level-1`: ранг ≤ 14, с именем): со вторым
    /// рядом на снимке остановки у развилки было десять подписей — «нужные
    /// детали» превращались в справочник, на SE — в кашу.
    static let detailLayers = ["poi-level-1"]

    /// Круг у машины, в котором значков нет: «я» и кольцо компаса — виды
    /// поверх карты, и движок положил бы подпись прямо под них.
    static func carClearRing(center: CLLocationCoordinate2D, radius: Double,
                             sides: Int = 16) -> [CLLocationCoordinate2D] {
        let k = cos(center.latitude * .pi / 180) * 111_320
        let n = max(3, sides)
        let ring = (0..<n).map { i -> CLLocationCoordinate2D in
            let a = Double(i) / Double(n) * 2 * .pi
            return CLLocationCoordinate2D(latitude: center.latitude + radius * cos(a) / 111_320,
                                          longitude: center.longitude + radius * sin(a) / k)
        }
        return ring + [ring[0]]
    }

    /// Переписать фильтр круга: появился, пропал или машина сдвинулась
    /// дальше `stopViewCarClearRewriteMeters` (шум позиции стоя — нет).
    static func carClearNeedsRewrite(_ old: CLLocationCoordinate2D?, _ new: CLLocationCoordinate2D?) -> Bool {
        switch (old, new) {
        case (nil, nil): return false
        case let (a?, b?):
            return GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude)
                > AppConfig.stopViewCarClearRewriteMeters
        default: return true
        }
    }

    /// Показывать ли значки стоя: в поездке, стоим, слой заведений включён
    /// настройкой, карта не накрыта тревогой, телефон не горячий.
    static func showsDetail(state: State, tripActive: Bool, places: Bool, covered: Bool,
                            performance: PerformanceMode) -> Bool {
        tripActive && state.standing && places && !covered && performance == .full
    }
}
