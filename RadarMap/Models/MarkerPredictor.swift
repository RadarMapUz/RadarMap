//
//  MarkerPredictor.swift
//  RadarMap
//
//  Где значок «я» СЕЙЧАС, а не где был последний фикс. Только картинка.
//
//  До 21.10 стрелка за интервал между фиксами плыла к ПОСЛЕДНЕМУ фиксу и
//  приходила в него ровно тогда, когда приходил следующий: значок всегда был
//  на фикс позади машины — 12 м на 50 км/ч в симуляторной поездке, плюс
//  задержка самого фикса на телефоне («машина опаздывает», CarPlay, 21.10).
//  Навигаторы рисуют машину там, где она есть: от последнего фикса вперёд по
//  скорости и курсу, по линии маршрута, если она есть.
//
//  Правила:
//  - вперёд не дальше markerMaxLeadSeconds от времени фикса — пропал сигнал,
//    значок встаёт, а не уезжает по прямой в никуда;
//  - по линии маршрута — до излома круче markerPathTurnDegrees или до конца
//    линии: за поворот значок не проскакивает, ждёт фикса у угла;
//  - без линии в повороте (курс крутится) — только markerTurnLeadSeconds;
//  - стоим (скорость ниже markerMovingMps) — значок не едет;
//  - новый фикс — плавная поправка без рывков (27.A, 22.10, владелец: «не
//    должен дёргаться, туда-сюда»): смещение значка от новой оценки гасится
//    критически демпфированной кривой x(t) = (x₀ + (v₀ + x₀/τ)·t)·e^(−t/τ),
//    где v₀ — разница скоростей значка и оценки в момент фикса: скорость
//    значка не скачет на фиксе, ускорение ограничено (markerMaxAccel), а τ
//    выбирается так, чтобы в движении значок впереди оценки только
//    замедлялся (не медленнее markerMinSpeedShare скорости — назад никогда),
//    а позади — ускорялся не больше чем на markerMaxBoost; на стоянке
//    допускается плавный доезд назад к точке остановки;
//    скачок дальше markerJumpMeters — ставим сразу.
//
//  ГРАНИЦА ПРИМЕНЕНИЯ — та же, что у RoadSnapper, и жёстче: предсказание
//  живёт только в EngineMapView (стрелка и точка следящей камеры). Оповещения,
//  гейты, запись проездов, трек и спидометр работают ТОЛЬКО по принятым
//  фиксам: угаданная точка там была бы предположением вместо измерения.
//  LocationService отдаёт сюда фикс и не читает отсюда ничего
//  (MarkerPredictorTests.testPipelineNeverReadsPrediction).
//
//  Чистая структура: время приходит параметром — покрыта MarkerPredictorTests.
//

import CoreLocation
import Foundation

nonisolated struct MarkerPredictor {

    /// Фикс для картинки: точка и курс уже прижаты к дороге/маршруту
    /// (RoadSnapper, RouteService.displaySnap), скорость — 0 на стоянке.
    struct Fix: Equatable {
        var coordinate: CLLocationCoordinate2D
        /// Градусы 0…360; < 0 — неизвестен (тогда значок вперёд не едет).
        var courseDegrees: Double
        /// м/с, ≥ 0.
        var speedMps: Double
        /// Время фикса, секунды (`timeIntervalSinceReferenceDate`).
        var time: TimeInterval
        /// Линия маршрута вперёд от точки (первая точка — сама точка или
        /// рядом); пусто — маршрута нет, едем по курсу.
        var path: [CLLocationCoordinate2D] = []

        /// Линия не сравнивается: у одного фикса она одна.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.courseDegrees == rhs.courseDegrees && lhs.speedMps == rhs.speedMps
                && lhs.time == rhs.time
        }
    }

    /// Что рисовать. `courseDegrees` < 0 — курс берём у фикса (оценка шла не по линии).
    struct Pose: Equatable {
        var coordinate: CLLocationCoordinate2D
        var courseDegrees: Double

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.courseDegrees == rhs.courseDegrees
        }
    }

    /// Как гасится продольная часть поправки (для журнала и тестов).
    enum Settle: Equatable {
        /// Значок позади оценки — догоняет, чуть быстрее машины.
        case catchUp
        /// Впереди, едем — значок замедляется, пока оценка не догонит; назад не едет.
        case absorb
        /// Впереди, а машина встала — плавный доезд назад к точке остановки.
        case glideBack
    }

    /// Одна ось поправки: x(t) = (x₀ + (v₀ + x₀/τ)·t)·e^(−t/τ). Критическое
    /// демпфирование: без колебаний, x′(0) = v₀ (скорость значка непрерывна).
    struct Ease: Equatable {
        var x0: Double = 0
        var v0: Double = 0
        var tau: Double = AppConfig.markerCatchUpSeconds

        func value(_ t: Double) -> Double {
            (x0 + (v0 + x0 / tau) * t) * exp(-t / tau)
        }

        func rate(_ t: Double) -> Double {
            (v0 - (v0 + x0 / tau) * t / tau) * exp(-t / tau)
        }

        func acceleration(_ t: Double) -> Double {
            let c = v0 + x0 / tau
            return (-(c + v0) + c * t / tau) / tau * exp(-t / tau)
        }

        var isZero: Bool { x0 == 0 && v0 == 0 }

        /// Самая короткая τ (быстрее догоняет), при которой ускорение не
        /// больше `maxAccel`, а при `speed` > 0 значок не медленнее
        /// `minShare` скорости и не быстрее её на `maxBoost`.
        static func choose(x0: Double, v0: Double, speed: Double?,
                           minTau: Double = AppConfig.markerCatchUpSeconds,
                           maxTau: Double = AppConfig.markerMaxEaseSeconds,
                           maxAccel: Double = AppConfig.markerMaxAccel,
                           minShare: Double = AppConfig.markerMinSpeedShare,
                           maxBoost: Double? = nil) -> Ease {
            guard x0 != 0 || v0 != 0 else { return Ease() }
            let boost = maxBoost ?? (AppConfig.markerMaxBoostShare * (speed ?? 0) + AppConfig.markerMaxBoostMps)
            // Значок, уже едущий назад или слишком быстро относительно
            // оценки (разворот, догон после провала фиксов), — сразу в
            // допустимую скорость: непрерывность там уже ничего не значит.
            var start = v0
            if let speed { start = min(max(v0, (minShare - 1) * speed), boost) }
            // Сначала главное — назад не едем и не рвёмся вперёд; затем —
            // без рывка по ускорению. Самая быстрая τ, где выполнено всё;
            // нет такой — самая быстрая, где выполнено главное.
            var fallback: Ease?
            var tau = minTau
            while tau <= maxTau + 1e-9 {
                let ease = Ease(x0: x0, v0: start, tau: tau)
                if ease.keepsSpeed(speed, minShare: minShare, maxBoost: boost) {
                    if ease.maxAcceleration <= maxAccel { return ease }
                    if fallback == nil { fallback = ease }
                }
                tau *= 1.15
            }
            return fallback ?? Ease(x0: x0, v0: start, tau: maxTau)
        }

        /// Наибольшее по модулю ускорение кривой (выборка по 5τ).
        var maxAcceleration: Double {
            (0...40).map { abs(acceleration(Double($0) / 40 * 5 * tau)) }.max() ?? 0
        }

        private func keepsSpeed(_ speed: Double?, minShare: Double, maxBoost: Double) -> Bool {
            guard let speed else { return true }
            for k in 0...40 {
                let r = rate(Double(k) / 40 * 5 * tau)
                if speed + r < minShare * speed - 1e-9 || r > maxBoost + 1e-9 { return false }
            }
            return true
        }
    }

    private(set) var fix: Fix?
    /// В повороте без линии — короткий горизонт.
    private(set) var turning = false
    /// Как гасится продольная поправка (по знаку смещения и стоянке).
    private(set) var settle: Settle = .catchUp
    /// Поправка: смещение значка от оценки в момент `correctionStart` вдоль
    /// (`along`, плюс — впереди) и поперёк (`lateral`) курса оценки.
    private(set) var along = Ease()
    private(set) var lateral = Ease()
    /// Единичные векторы (восток, север) «вдоль» и «поперёк» на момент поправки.
    private var axis = (east: 0.0, north: 1.0)
    private var correctionStart: TimeInterval = 0

    /// Новый фикс. `now` — текущее время в той же шкале, что `Fix.time`;
    /// `immediate` — без поправки (первая точка, «Уменьшение движения»).
    mutating func update(_ new: Fix, now: TimeInterval, immediate: Bool = false) {
        // Где значок сейчас и с какой скоростью едет — до смены фикса.
        let step = 1.0 / 60
        let shown = immediate ? nil : pose(at: now)?.coordinate
        let before = immediate ? nil : pose(at: now - step)?.coordinate
        if let old = fix, new.courseDegrees >= 0, old.courseDegrees >= 0, new.path.count < 2 {
            let dt = max(0.2, new.time - old.time)
            turning = GeoMath.angleDifference(new.courseDegrees, old.courseDegrees) / dt
                > AppConfig.markerTurnRateDegrees
        } else {
            turning = false
        }
        fix = new
        along = Ease()
        lateral = Ease()
        settle = .catchUp
        correctionStart = now
        guard let shown, let target = target(at: now) else { return }
        let error = Self.offset(from: target.coordinate, to: shown)
        guard (error.east * error.east + error.north * error.north).squareRoot()
                <= AppConfig.markerJumpMeters else { return }
        let course = target.courseDegrees >= 0 ? target.courseDegrees : new.courseDegrees
        if course >= 0 {
            let θ = course * .pi / 180
            axis = (east: sin(θ), north: cos(θ))
        } else {
            axis = (east: 0, north: 1)
        }
        // Скорость значка относительно новой оценки: её гасим так же плавно,
        // как и смещение, — на фиксе скорость значка не меняется.
        var relative = (east: 0.0, north: 0.0)
        if let before, let ahead = self.target(at: now + step) {
            let moved = Self.offset(from: before, to: shown)
            let drift = Self.offset(from: target.coordinate, to: ahead.coordinate)
            relative = ((moved.east - drift.east) / step, (moved.north - drift.north) / step)
        }
        let a0 = error.east * axis.east + error.north * axis.north
        let l0 = error.east * axis.north - error.north * axis.east
        let va = relative.east * axis.east + relative.north * axis.north
        let vl = relative.east * axis.north - relative.north * axis.east
        let moving = new.speedMps >= AppConfig.markerMovingMps && course >= 0
        along = Ease.choose(x0: a0, v0: va, speed: moving ? new.speedMps : nil)
        lateral = Ease.choose(x0: l0, v0: vl, speed: nil)
        settle = a0 <= 0 ? .catchUp : (moving ? .absorb : .glideBack)
    }

    /// Где значок сейчас; nil — фиксов ещё не было.
    func pose(at now: TimeInterval) -> Pose? {
        guard fix != nil, let target = target(at: now) else { return nil }
        let t = max(0, now - correctionStart)
        let a = along.isZero ? 0 : along.value(t)
        let l = lateral.isZero ? 0 : lateral.value(t)
        guard a != 0 || l != 0 else { return target }
        let east = a * axis.east + l * axis.north
        let north = a * axis.north - l * axis.east
        return Pose(coordinate: Self.moved(target.coordinate, east: east, north: north),
                    courseDegrees: target.courseDegrees)
    }

    /// Значок ещё движется: оценка растёт (едем и горизонт не исчерпан) или
    /// не догашена поправка. false — такт кадров можно остановить до фикса.
    func isMoving(at now: TimeInterval) -> Bool {
        guard let fix else { return false }
        let t = max(0, now - correctionStart)
        let leadGrows = fix.speedMps >= AppConfig.markerMovingMps
            && now - fix.time < leadLimit(fix)
        if leadGrows { return true }
        for ease in [along, lateral] where !ease.isZero {
            if abs(ease.value(t)) > 0.05 || abs(ease.rate(t)) > 0.05 { return true }
        }
        return false
    }

    // MARK: - Оценка без поправки

    /// Положение по последнему фиксу на момент `now`.
    func target(at now: TimeInterval) -> Pose? {
        guard let fix else { return nil }
        let start = Pose(coordinate: fix.coordinate, courseDegrees: -1)
        guard fix.speedMps >= AppConfig.markerMovingMps else { return start }
        let lead = min(max(0, now - fix.time), leadLimit(fix))
        let distance = fix.speedMps * lead
        guard distance > 0 else { return start }
        if usesPath(fix) {
            return Self.walk(fix.path, meters: distance)
        }
        guard fix.courseDegrees >= 0 else { return start }
        return Pose(coordinate: GeoMath.destination(from: fix.coordinate, bearing: fix.courseDegrees,
                                                    distanceMeters: distance),
                    courseDegrees: -1)
    }

    private func leadLimit(_ fix: Fix) -> Double {
        turning && !usesPath(fix) ? AppConfig.markerTurnLeadSeconds : AppConfig.markerMaxLeadSeconds
    }

    /// Линия годится, если идёт в нашу сторону: сразу после разворота
    /// маршрут ещё смотрит назад, и вести значок по нему — значит назад.
    private func usesPath(_ fix: Fix) -> Bool {
        guard fix.path.count >= 2 else { return false }
        guard fix.courseDegrees >= 0 else { return true }
        guard let first = Self.firstBearing(fix.path) else { return false }
        return GeoMath.angleDifference(first, fix.courseDegrees) <= 90
    }

    // MARK: - Геометрия

    /// Отрезки короче метра — шум линии (дубли точек), их направлению не верим.
    private static let minSegmentMeters = 1.0

    private static func firstBearing(_ path: [CLLocationCoordinate2D]) -> Double? {
        for i in 1..<path.count where distance(path[i - 1], path[i]) >= minSegmentMeters {
            return GeoMath.bearing(from: path[i - 1], to: path[i])
        }
        return nil
    }

    /// Пройти по линии `meters`, остановившись у излома круче порога или в конце.
    static func walk(_ path: [CLLocationCoordinate2D], meters: Double) -> Pose {
        var left = meters
        var previousBearing: Double?
        var point = path[0]
        for i in 1..<path.count {
            let a = path[i - 1], b = path[i]
            let length = distance(a, b)
            guard length >= minSegmentMeters else { continue }
            let bearing = GeoMath.bearing(from: a, to: b)
            if let previousBearing,
               GeoMath.angleDifference(previousBearing, bearing) > AppConfig.markerPathTurnDegrees {
                return Pose(coordinate: a, courseDegrees: previousBearing)
            }
            if left <= length {
                let s = left / length
                return Pose(coordinate: CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * s,
                    longitude: a.longitude + (b.longitude - a.longitude) * s), courseDegrees: bearing)
            }
            left -= length
            previousBearing = bearing
            point = b
        }
        return Pose(coordinate: point, courseDegrees: previousBearing ?? -1)
    }

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    /// Смещение `b` от `a`, метры на восток и север.
    static func offset(from a: CLLocationCoordinate2D,
                       to b: CLLocationCoordinate2D) -> (east: Double, north: Double) {
        ((b.longitude - a.longitude) * 111_320 * cos(a.latitude * .pi / 180),
         (b.latitude - a.latitude) * 111_320)
    }

    static func moved(_ c: CLLocationCoordinate2D, east: Double, north: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: c.latitude + north / 111_320,
                               longitude: c.longitude + east / (111_320 * cos(c.latitude * .pi / 180)))
    }
}

#if DEBUG
/// Замер лага значка (25.B): `-logMarker` пишет в журнал фиксы и нарисованную
/// точку, разбор — `tools/marker_lag.py`.
nonisolated enum MarkerLagLog {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-logMarker")
}
#endif
