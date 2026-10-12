//
//  DriveCamera.swift
//  RadarMap
//
//  Камера карты в поездке — одна для телефона и машины.
//
//  До 12.10 камера задавала ОХВАТ — сколько метров уложить по высоте экрана:
//  в машине 200–1100 м, на телефоне 420–1600 м. На экране машины высотой
//  382 точки это масштаб 14,3–16,8, на телефоне 15,3–16,7, а разметка полос
//  и стрелки полос в стиле начинаются с 17 (на 16-м пунктиры многополосной
//  улицы сливались в рябь). Итог: полосы, ради которых строили свои тайлы, в
//  поездке не были видны НИКОГДА («полосы не видны», владелец, 12.10). И чем
//  ниже экран, тем мельче всё на нём — широкий низкий экран машины показывал
//  ту же картинку, только меньше.
//
//  Теперь камера задаёт МАСШТАБ, как у больших навигаторов: полоса — одного
//  размера на любом экране, а большой экран показывает больше дороги, а не
//  ту же дорогу крупнее. Правило одно: самый крупный масштаб, при котором
//  впереди видно `lookahead` секунд пути, — но не мельче порога полос там,
//  где полосы решают (город, подъезд к развилке). Обзор на скорости даёт
//  прежде всего наклон (до 45° — см. AppConfig.engineMapPitchDegrees), и
//  только потом отдаление: так у Amap и Baidu, где водитель видит свою полосу.
//
//  Перед манёвром камера подтягивается к развилке: наклон уменьшается, порог
//  масштаба поднимается до стрелок полос, а требуемый обзор — ровно «до
//  развилки и чуть дальше», так что поворот остаётся в кадре, пока камера
//  приближается (прежняя стягивала охват, пока развилка была ЗА краем экрана).
//
//  Геометрия — та же, что у движка: вертикальный угол обзора MapLibre
//  (`fieldOfView`), камера смотрит в точку центра экрана. Отсюда и точное
//  место машины на наклонной карте (`centreAhead`): прежняя формула для вида
//  сверху на наклоне ставила машину на 5 % высоты выше задуманного.
//
//  Чистая логика, время — параметром; покрыто DriveCameraTests.
//

import Foundation

nonisolated enum DriveCamera {

    /// Что задаёт скорость: наклон, нужный обзор и пределы масштаба.
    struct Profile: Equatable, Sendable {
        let pitchDegrees: Double
        /// Секунд пути, которые обязаны быть видны впереди машины.
        let lookaheadSeconds: Double
        let minZoom: Double
        let maxZoom: Double
        /// Где машина по высоте свободной полосы экрана (0 — верх, 1 — низ).
        let carShare: Double
    }

    /// Итог для движка.
    struct Frame: Equatable, Sendable {
        var zoom: Double
        var pitchDegrees: Double
        var carShare: Double
    }

    /// Вертикальный угол обзора MapLibre Native (util::DEFAULT_FOV).
    static let fieldOfView = 0.6435011087932844
    /// Масштаб, с которого стиль рисует разметку и стрелки полос
    /// (make_style.LANE_MARKINGS_FROM).
    static let laneZoom = 17.0

    private struct Knot {
        let kmh, pitch, seconds, minZoom, maxZoom, share: Double
    }

    /// С наклоном. До 15 км/ч — строго сверху (стоянка, светофор, ползком в
    /// пробке: полосы и перекрёсток сверху — владелец, 12.10); дальше наклон
    /// растёт со скоростью. Здесь — желаемый наклон, как у Amap; в движок он
    /// идёт не круче `maxPitch` (AppConfig.engineMapPitchDegrees, 45°: выше —
    /// открытая беда движка с перегревом, maplibre-native #3029, пока нет
    /// замера на живом телефоне). Обзор при меньшем наклоне добирает масштаб.
    /// В городе порог масштаба — полосы; на трассе ниже: на прямой важнее
    /// видеть дальше, а у съезда камера и так вернётся к полосам (манёвр).
    private static let pitched: [Knot] = [
        Knot(kmh: 0, pitch: 0, seconds: 0, minZoom: 17.0, maxZoom: 18.0, share: 0.62),
        Knot(kmh: 15, pitch: 0, seconds: 8, minZoom: 17.0, maxZoom: 18.0, share: 0.62),
        Knot(kmh: 30, pitch: 22, seconds: 9, minZoom: 17.0, maxZoom: 17.9, share: 0.66),
        Knot(kmh: 50, pitch: 36, seconds: 10, minZoom: 17.0, maxZoom: 17.7, share: 0.70),
        Knot(kmh: 70, pitch: 45, seconds: 11, minZoom: 17.0, maxZoom: 17.5, share: 0.72),
        Knot(kmh: 90, pitch: 52, seconds: 13, minZoom: 16.4, maxZoom: 17.4, share: 0.74),
        Knot(kmh: 110, pitch: 56, seconds: 14, minZoom: 16.1, maxZoom: 17.3, share: 0.75),
        Knot(kmh: 130, pitch: 58, seconds: 15, minZoom: 15.9, maxZoom: 17.2, share: 0.75),
    ]

    /// Плоско (горячий телефон, «3D» выключено): без наклона обзор даёт
    /// только отдаление, и порог полос на скорости уступает обзору.
    private static let flat: [Knot] = [
        Knot(kmh: 0, pitch: 0, seconds: 0, minZoom: 17.0, maxZoom: 18.0, share: 0.62),
        Knot(kmh: 15, pitch: 0, seconds: 8, minZoom: 17.0, maxZoom: 18.0, share: 0.62),
        Knot(kmh: 40, pitch: 0, seconds: 9, minZoom: 16.4, maxZoom: 17.8, share: 0.68),
        Knot(kmh: 70, pitch: 0, seconds: 10, minZoom: 15.8, maxZoom: 17.4, share: 0.72),
        Knot(kmh: 100, pitch: 0, seconds: 11, minZoom: 15.3, maxZoom: 17.0, share: 0.74),
        Knot(kmh: 130, pitch: 0, seconds: 12, minZoom: 15.0, maxZoom: 16.8, share: 0.75),
    ]

    /// Обзор впереди не короче этого и стоя.
    static let minLookaheadMeters = 60.0
    /// Развилка: с какого времени до неё камера начинает подтягиваться, и
    /// не дальше/не ближе каких расстояний.
    static let maneuverLeadSeconds = 15.0
    static let maneuverWindowMin = 150.0
    static let maneuverWindowMax = 450.0
    /// У самой развилки (ближе этого — вид развилки целиком).
    static let maneuverCloseMeters = 80.0
    /// Вид развилки: наклон, порог масштаба (стрелки полос) и запас обзора за ней.
    static let maneuverPitch = 20.0
    /// Наклон уходит к виду развилки только на этой доле окна подъезда:
    /// раньше он съедал обзор, пока развилка ещё далеко.
    static let maneuverPitchShare = 0.6
    /// Дальше этого «держать в кадре» не действует: плитка не отъезжает до
    /// масштаба района ради камеры в километре.
    static let keepAheadMaxMeters = 500.0
    static let maneuverMinZoom = 17.3
    static let maneuverMarginMeters = 40.0

    static func profile(speedKmh: Double, pitchAllowed: Bool,
                        maxPitch: Double = AppConfig.engineMapPitchDegrees) -> Profile {
        let knots = pitchAllowed ? pitched : flat
        let v = max(0, speedKmh.isFinite ? speedKmh : 0)
        func value(_ key: (Knot) -> Double) -> Double {
            guard let first = knots.first, let last = knots.last else { return 0 }
            if v <= first.kmh { return key(first) }
            if v >= last.kmh { return key(last) }
            for (a, b) in zip(knots, knots.dropFirst()) where v <= b.kmh {
                let t = b.kmh > a.kmh ? (v - a.kmh) / (b.kmh - a.kmh) : 0
                return key(a) + (key(b) - key(a)) * t
            }
            return key(last)
        }
        return Profile(pitchDegrees: min(max(0, maxPitch), value(\.pitch)), lookaheadSeconds: value(\.seconds),
                       minZoom: value(\.minZoom), maxZoom: value(\.maxZoom), carShare: value(\.share))
    }

    /// Целевой кадр.
    /// - Parameters:
    ///   - maneuverDistance: метров по маршруту до следующего манёвра, nil — нет.
    ///   - viewHeight: высота вида карты, точки.
    ///   - carY: где машина по высоте вида (0 — верх, 1 — низ) при данной
    ///     `Profile.carShare` — раскладку экрана знает только вид.
    ///   - keepAhead: метров до того, что обязано быть в кадре (камера на
    ///     плитке главного экрана машины), nil — ничего; дальше
    ///     `keepAheadMaxMeters` не учитывается.
    static func target(speedKmh: Double, maneuverDistance: Double?, pitchAllowed: Bool,
                       maxPitch: Double = AppConfig.engineMapPitchDegrees,
                       keepAhead: Double? = nil,
                       viewHeight: Double, latitude: Double,
                       carY: (Double) -> Double) -> Frame {
        let profile = profile(speedKmh: speedKmh, pitchAllowed: pitchAllowed, maxPitch: maxPitch)
        let mps = max(0, speedKmh.isFinite ? speedKmh : 0) / 3.6
        var pitch = profile.pitchDegrees
        var minZoom = profile.minZoom
        var lookahead = max(minLookaheadMeters, mps * profile.lookaheadSeconds)

        // Развилка в окне подъезда: обзор — ровно до неё с запасом (поворот
        // обязан быть в кадре, пока камера приближается), наклон уходит к
        // виду развилки во второй половине подъезда, порог масштаба растёт
        // к стрелкам полос — но никогда не выталкивает развилку за край.
        var visibilityCap = Double.infinity
        if let d = maneuverDistance, d.isFinite, d >= 0 {
            let window = min(maneuverWindowMax, max(maneuverWindowMin, mps * maneuverLeadSeconds))
            if d < window {
                let w = ramp(d, from: window, to: maneuverCloseMeters)
                let late = ramp(d, from: window * maneuverPitchShare, to: maneuverCloseMeters)
                pitch += (min(pitch, maneuverPitch) - pitch) * late
                minZoom += (max(minZoom, maneuverMinZoom) - minZoom) * w
                lookahead = max(minLookaheadMeters, d + maneuverMarginMeters)
                visibilityCap = lookahead
            }
        }

        // Объект впереди, который обязан быть виден (камера на плитке): обзор
        // не короче, а порог полос ему уступает — плитка маленькая, и камера
        // в ней важнее разметки.
        if let k = keepAhead, k.isFinite, k >= 0, k <= keepAheadMaxMeters {
            lookahead = max(lookahead, k + maneuverMarginMeters)
            visibilityCap = lookahead   // и развилка, и камера — обе в кадре
        }

        let y = carY(profile.carShare)
        let zoom = zoomShowing(lookahead, pitchDegrees: pitch, viewHeight: viewHeight,
                               carY: y, latitude: latitude)
        // Порог полос не крупнее масштаба, при котором развилка ещё в кадре.
        if visibilityCap.isFinite {
            minZoom = min(minZoom, zoomShowing(visibilityCap, pitchDegrees: pitch,
                                               viewHeight: viewHeight, carY: y, latitude: latitude))
        }
        // Порог развилки (стрелки полос) старше потолка скорости.
        let maxZoom = max(profile.maxZoom, minZoom)
        return Frame(zoom: min(maxZoom, max(minZoom, zoom)),
                     pitchDegrees: pitch, carShare: profile.carShare)
    }

    /// 0 на `from`, 1 на `to` и ближе (from > to), линейно между.
    private static func ramp(_ d: Double, from: Double, to: Double) -> Double {
        guard from > to else { return d <= to ? 1 : 0 }
        return min(1, max(0, (from - d) / (from - to)))
    }

    // MARK: - Геометрия движка

    /// Метров на точку в центре экрана при масштабе `zoom` (тайл MapLibre —
    /// 512 точек).
    static func metersPerPoint(zoom: Double, latitude: Double) -> Double {
        40_075_016.686 * cos(latitude * .pi / 180) / (512 * pow(2, zoom))
    }

    /// Охват по высоте вида для движка (EngineMapView считает масштаб из
    /// охвата той же формулой — круг замкнут).
    static func span(zoom: Double, viewHeight: Double, latitude: Double) -> Double {
        metersPerPoint(zoom: zoom, latitude: latitude) * max(1, viewHeight)
    }

    /// Сколько метров земли от точки центра экрана до точки, лежащей на
    /// `share` высоты вида ниже центра (share > 0 — к зрителю), при наклоне.
    /// На наклоне 0 это `span · share` — прежняя формула вида сверху.
    static func groundOffset(spanMeters: Double, share: Double, pitchDegrees: Double) -> Double {
        let half = tan(fieldOfView / 2)
        let distance = spanMeters / 2 / half          // камера → центр
        let p = pitchDegrees * .pi / 180
        let angle = atan(2 * share * half)            // луч к точке от оси взгляда
        // Горизонт: выше него земли нет — ограничиваем «очень далеко».
        let below = p - angle
        guard below < .pi / 2 - 0.01 else { return -distance * 50 }
        return distance * (sin(p) - cos(p) * tan(below))
    }

    /// На сколько метров центр экрана впереди машины, чтобы машина стояла на
    /// `anchorY` высоты вида.
    static func centreAhead(spanMeters: Double, anchorY: Double, pitchDegrees: Double) -> Double {
        groundOffset(spanMeters: spanMeters, share: anchorY - 0.5, pitchDegrees: pitchDegrees)
    }

    /// Сколько метров дороги видно от машины до верхнего края вида.
    static func visibleAhead(zoom: Double, pitchDegrees: Double, viewHeight: Double,
                             carY: Double, latitude: Double) -> Double {
        let span = span(zoom: zoom, viewHeight: viewHeight, latitude: latitude)
        let toTop = -groundOffset(spanMeters: span, share: -0.5, pitchDegrees: pitchDegrees)
        return toTop + centreAhead(spanMeters: span, anchorY: carY, pitchDegrees: pitchDegrees)
    }

    /// Масштаб, при котором впереди видно ровно `meters`. Обзор обратно
    /// пропорционален 2^zoom при том же наклоне — решается в одну строку.
    static func zoomShowing(_ meters: Double, pitchDegrees: Double, viewHeight: Double,
                            carY: Double, latitude: Double) -> Double {
        let reference = 17.0
        let seen = visibleAhead(zoom: reference, pitchDegrees: pitchDegrees, viewHeight: viewHeight,
                                carY: carY, latitude: latitude)
        guard seen > 0, meters > 0 else { return reference }
        return reference + log2(seen / meters)
    }

    // MARK: - Плавность

    /// Сглаживание во времени: кадр подходит к цели экспоненциально, а не
    /// ступенями. Ступени прежней камеры (охват по 30 м) на скорости у
    /// границы ступени «дышали» — то ближе, то дальше на каждом фиксе, — а
    /// после манёвра вид отпрыгивал назад одним рывком.
    struct Smoother: Sendable {
        private(set) var frame: Frame?
        private var time: Date?

        /// Постоянная времени, с.
        static let tau = 2.0
        /// После паузы дольше этого — сразу к цели (вернулись к карте).
        static let maxGap = 5.0

        mutating func step(toward target: Frame, at now: Date) -> Frame {
            defer { time = now }
            guard var current = frame, let last = time else {
                frame = target
                return target
            }
            let dt = now.timeIntervalSince(last)
            guard dt >= 0, dt <= Self.maxGap else {
                frame = target
                return target
            }
            let k = 1 - exp(-dt / Self.tau)
            current.zoom = approach(current.zoom, target.zoom, k, snap: 0.02, step: 0.01)
            current.pitchDegrees = approach(current.pitchDegrees, target.pitchDegrees, k, snap: 0.5, step: 0.5)
            current.carShare = approach(current.carShare, target.carShare, k, snap: 0.004, step: 0.002)
            frame = current
            return current
        }

        mutating func reset() {
            frame = nil
            time = nil
        }

        /// Шаг к цели, округлённый: движок не получает новую анимацию на
        /// каждую тысячную долю масштаба.
        private func approach(_ value: Double, _ target: Double, _ k: Double,
                              snap: Double, step: Double) -> Double {
            let next = value + (target - value) * k
            if abs(target - next) < snap { return target }
            return (next / step).rounded() * step
        }
    }
}
