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
//  прежде всего наклон (до 58° — см. AppConfig.engineMapPitchDegrees), и
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
//  Экран машины — свой профиль (18.10, «при езде нормального вида нет»):
//  порог полос z17 на всей городской скорости давал на экране машины 106 м
//  дороги впереди на 40 км/ч и 175 м на 60 — следующий перекрёсток за краем.
//  В машине впереди видно секунды пути, как у больших навигаторов (261 м на
//  40 км/ч, 408 м на 60 на экране 382 pt), полосы — стоя, ползком и на
//  подъезде к манёвру; телефон не меняется.
//
//  Чистая логика, время — параметром; покрыто DriveCameraTests.
//

import CoreLocation
import Foundation

nonisolated enum DriveCamera {

    /// Чей экран: у машины свой профиль — обзор впереди важнее разметки.
    enum Screen: Sendable {
        case phone, car
    }

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

    /// Что обязано быть в кадре (ближайшая камера): смещение от машины в
    /// метрах, в осях экрана — вперёд (к верху) и вправо. `anyDirection` —
    /// поворот карты неизвестен (стоим без курса, карта держит прежний):
    /// тогда точка обязана влезть в любую сторону.
    struct Keep: Equatable, Sendable {
        var forward: Double
        var right: Double
        var anyDirection = false

        var distance: Double { (forward * forward + right * right).squareRoot() }

        /// Смещение `point` от машины при повороте карты `bearing` (куда
        /// смотрит верх экрана, градусы); nil или отрицательный — неизвестен.
        static func offset(from car: CLLocationCoordinate2D, to point: CLLocationCoordinate2D,
                           bearing: Double?) -> Keep {
            let k = cos(car.latitude * .pi / 180) * 111_320
            let east = (point.longitude - car.longitude) * k
            let north = (point.latitude - car.latitude) * 111_320
            guard let bearing, bearing.isFinite, bearing >= 0 else {
                return Keep(forward: (east * east + north * north).squareRoot(), right: 0, anyDirection: true)
            }
            let a = bearing * .pi / 180
            return Keep(forward: east * sin(a) + north * cos(a), right: east * cos(a) - north * sin(a))
        }
    }

    /// Где на экране карта не закрыта: доли высоты под верхней и нижней
    /// панелями и точки по бокам под кнопками. Ширина 0 — сбоку не меряем.
    struct Clear: Equatable, Sendable {
        var top = 0.0
        var bottom = 0.0
        var width = 0.0
        var side = 0.0
    }

    /// Вертикальный угол обзора MapLibre Native (util::DEFAULT_FOV).
    static let fieldOfView = 0.6435011087932844
    /// Масштаб, с которого стиль рисует разметку и стрелки полос
    /// (make_style.LANE_MARKINGS_FROM).
    static let laneZoom = 17.0

    private struct Knot {
        let kmh, pitch, seconds, minZoom, maxZoom, share: Double
    }

    /// С наклоном. Стоя и ползком (до 5 км/ч: стоянка, светофор, шум GPS на
    /// месте) — строго сверху, полосы и перекрёсток (владелец, 12.10); уже с
    /// 10 км/ч — наклон, как у Яндекса и Amap: дома в объёме и дорога
    /// уходит вдаль («у Яндекса богато под наклоном», 21.10, план 25.D).
    /// До 21.10 сверху было до 15 км/ч, и город на 10–40 км/ч выглядел
    /// чертежом. В движок наклон идёт не круче `maxPitch`
    /// (AppConfig.engineMapPitchDegrees, 58°); горячий телефон — плоская
    /// таблица. Обзор при меньшем наклоне добирает масштаб. В городе порог
    /// масштаба — полосы; на трассе ниже: на прямой важнее видеть дальше, а
    /// у съезда камера и так вернётся к полосам (манёвр).
    /// Узлы 5 и 10 км/ч лежат на прямой 0…15 по всем столбцам, кроме наклона, —
    /// масштаб, обзор и место машины от него не меняются (их ведёт 25.A).
    private static let pitched: [Knot] = [
        Knot(kmh: 0, pitch: 0, seconds: 0, minZoom: 17.0, maxZoom: 18.0, share: 0.62),
        Knot(kmh: 5, pitch: 0, seconds: 8.0 / 3, minZoom: 17.0, maxZoom: 18.0, share: 0.62),
        Knot(kmh: 10, pitch: 30, seconds: 16.0 / 3, minZoom: 17.0, maxZoom: 18.0, share: 0.62),
        Knot(kmh: 15, pitch: 40, seconds: 8, minZoom: 17.0, maxZoom: 18.0, share: 0.62),
        Knot(kmh: 30, pitch: 50, seconds: 9, minZoom: 17.0, maxZoom: 17.9, share: 0.66),
        Knot(kmh: 50, pitch: 54, seconds: 10, minZoom: 17.0, maxZoom: 17.7, share: 0.70),
        Knot(kmh: 70, pitch: 56, seconds: 11, minZoom: 17.0, maxZoom: 17.5, share: 0.72),
        Knot(kmh: 90, pitch: 57, seconds: 13, minZoom: 16.4, maxZoom: 17.4, share: 0.74),
        Knot(kmh: 110, pitch: 58, seconds: 14, minZoom: 16.1, maxZoom: 17.3, share: 0.75),
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

    /// Экран машины с наклоном. Стоя и ползком (до 5 км/ч) — сверху и на
    /// полосах (z17, около 100 м вперёд); с 10 км/ч — наклон (25.D, как
    /// у Яндекса в той же машине); с 30 км/ч впереди 20–25 секунд пути, как у
    /// Apple и Яндекса на том же экране: на 40 км/ч — 261 м, на 60 — 408 м
    /// (382 pt, расчёт DriveCameraTests). Разметка полос с z17 на ходу в
    /// городе не видна — её возвращает подъезд к манёвру (порог z17.3).
    private static let carPitched: [Knot] = [
        Knot(kmh: 0, pitch: 0, seconds: 0, minZoom: 17.0, maxZoom: 17.2, share: 0.62),
        Knot(kmh: 5, pitch: 0, seconds: 10.0 / 3, minZoom: 17.0, maxZoom: 17.2, share: 0.62),
        Knot(kmh: 10, pitch: 28, seconds: 20.0 / 3, minZoom: 17.0, maxZoom: 17.2, share: 0.62),
        Knot(kmh: 15, pitch: 38, seconds: 10, minZoom: 17.0, maxZoom: 17.2, share: 0.62),
        Knot(kmh: 30, pitch: 48, seconds: 22, minZoom: 16.4, maxZoom: 17.4, share: 0.66),
        Knot(kmh: 50, pitch: 53, seconds: 25, minZoom: 16.0, maxZoom: 17.2, share: 0.70),
        Knot(kmh: 70, pitch: 55, seconds: 24, minZoom: 15.7, maxZoom: 17.0, share: 0.72),
        Knot(kmh: 90, pitch: 57, seconds: 22, minZoom: 15.5, maxZoom: 16.8, share: 0.74),
        Knot(kmh: 110, pitch: 58, seconds: 21, minZoom: 15.3, maxZoom: 16.6, share: 0.75),
        Knot(kmh: 130, pitch: 58, seconds: 20, minZoom: 15.1, maxZoom: 16.4, share: 0.75),
    ]

    /// Экран машины плоско (горячий телефон): обзор — только отдалением.
    private static let carFlat: [Knot] = [
        Knot(kmh: 0, pitch: 0, seconds: 0, minZoom: 17.0, maxZoom: 17.2, share: 0.62),
        Knot(kmh: 15, pitch: 0, seconds: 10, minZoom: 17.0, maxZoom: 17.2, share: 0.62),
        Knot(kmh: 40, pitch: 0, seconds: 18, minZoom: 16.0, maxZoom: 17.2, share: 0.70),
        Knot(kmh: 70, pitch: 0, seconds: 18, minZoom: 15.4, maxZoom: 16.8, share: 0.74),
        Knot(kmh: 100, pitch: 0, seconds: 16, minZoom: 15.0, maxZoom: 16.4, share: 0.75),
        Knot(kmh: 130, pitch: 0, seconds: 15, minZoom: 14.8, maxZoom: 16.2, share: 0.75),
    ]

    /// Обзор впереди не короче этого и стоя.
    static let minLookaheadMeters = 60.0
    /// На экране машины стоя — перекрёсток впереди целиком, а не 60 м.
    static let carMinLookaheadMeters = 100.0

    static func minLookahead(_ screen: Screen) -> Double {
        screen == .car ? carMinLookaheadMeters : minLookaheadMeters
    }
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
    /// Запас вокруг удерживаемой точки, точки экрана: значок тревоги — 38.
    static let keepMarginPoints = 28.0
    static let maneuverMinZoom = 17.3
    static let maneuverMarginMeters = 40.0

    static func profile(speedKmh: Double, pitchAllowed: Bool,
                        maxPitch: Double = AppConfig.engineMapPitchDegrees,
                        screen: Screen = .phone) -> Profile {
        let knots = switch screen {
        case .phone: pitchAllowed ? pitched : flat
        case .car:   pitchAllowed ? carPitched : carFlat
        }
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
    ///   - keep: что обязано быть в кадре (ближайшая камера) — в любую
    ///     сторону, не только вперёд: стоя курса нет, и камера «136 м» сбоку
    ///     за краем экрана — та же пропажа, что впереди (12.10); дальше
    ///     `keepAheadMaxMeters` не учитывается.
    ///   - clear: незакрытая часть экрана. «Видно» считается до нижней кромки
    ///     верхней панели (HUD телефона, бар машины): камера под плашкой
    ///     «377 м до радара» в кадре только формально (12.10), — до верхней
    ///     кромки нижней и до кнопок сбоку.
    static func target(speedKmh: Double, maneuverDistance: Double?, pitchAllowed: Bool,
                       maxPitch: Double = AppConfig.engineMapPitchDegrees,
                       screen: Screen = .phone,
                       keep: Keep? = nil,
                       viewHeight: Double, latitude: Double, clear: Clear = Clear(),
                       carY: (Double) -> Double) -> Frame {
        let profile = profile(speedKmh: speedKmh, pitchAllowed: pitchAllowed, maxPitch: maxPitch,
                              screen: screen)
        let mps = max(0, speedKmh.isFinite ? speedKmh : 0) / 3.6
        var pitch = profile.pitchDegrees
        var minZoom = profile.minZoom
        let nearest = minLookahead(screen)
        var lookahead = max(nearest, mps * profile.lookaheadSeconds)

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
                lookahead = max(nearest, d + maneuverMarginMeters)
                visibilityCap = lookahead
            }
        }

        let y = carY(profile.carShare)
        var zoom = zoomShowing(lookahead, pitchDegrees: pitch, viewHeight: viewHeight,
                               carY: y, latitude: latitude, clearTop: clear.top)
        // Порог полос не крупнее масштаба, при котором развилка ещё в кадре.
        if visibilityCap.isFinite {
            minZoom = min(minZoom, zoomShowing(visibilityCap, pitchDegrees: pitch,
                                               viewHeight: viewHeight, carY: y, latitude: latitude,
                                               clearTop: clear.top))
        }
        // Камера, которая обязана быть видна: масштаб не крупнее того, при
        // котором она в кадре, и порог полос ей уступает — в приложении о
        // камерах камера на карте важнее разметки. Развилка при этом тоже в
        // кадре: из двух потолков берётся меньший.
        //
        // Два предела (21.10, «то уменьшается, то увеличивается»): камера
        // позади или в стороне на ходу не держится вовсе — её проехали, а
        // «ближайшей» она остаётся ещё 60 м по маршруту (на экране машины до
        // дока позади «я» 50 точек, и ради неё кадр уходил до z10,6); и потолок не мельче
        // `keepMinZoom` — камера в 400 м на 10 км/ч уводила кадр в район (z15).
        if let keep, keep.distance.isFinite, keep.distance <= keepAheadMaxMeters,
           !isPassed(keep, speedKmh: speedKmh) {
            let cap = max(keepMinZoom(speedKmh: speedKmh),
                          maxZoom(keeping: keep, pitchDegrees: pitch, viewHeight: viewHeight,
                                  carY: y, latitude: latitude, clear: clear))
            zoom = min(zoom, cap)
            minZoom = min(minZoom, cap)
        }
        // Порог развилки (стрелки полос) старше потолка скорости.
        let maxZoom = max(profile.maxZoom, minZoom)
        return Frame(zoom: min(maxZoom, max(minZoom, zoom)),
                     pitchDegrees: pitch, carShare: profile.carShare)
    }

    /// Мельче этого масштаба удерживаемая камера кадр не уводит: в городе —
    /// городской предел, на скорости — трассовый (AppConfig.driveKeep…).
    static func keepMinZoom(speedKmh: Double) -> Double {
        let v = speedKmh.isFinite ? speedKmh : 0
        let t = min(1, max(0, (v - AppConfig.driveKeepTownKmh)
                           / (AppConfig.driveKeepRoadKmh - AppConfig.driveKeepTownKmh)))
        return AppConfig.driveKeepMinZoomTown
            + (AppConfig.driveKeepMinZoomRoad - AppConfig.driveKeepMinZoomTown) * t
    }

    /// Машина едет, а камера позади (её уже проехали) или далеко в стороне
    /// от хода — вне конуса `driveKeepMovingConeDegrees`. Медленнее 10 км/ч
    /// гейты направления выключены, и «ближайшей» становится камера соседней
    /// улицы в 140 м сбоку; на 10 км/ч — снова наша впереди: кадр прыгал
    /// между ними на каждом пороге (замер 21.10). Стоя держим любую — курса
    /// нет, и камера «136 м» сбоку обязана быть видна (12.10).
    static func isPassed(_ keep: Keep, speedKmh: Double) -> Bool {
        guard !keep.anyDirection, speedKmh > AppConfig.driveKeepBehindMaxKmh else { return false }
        let cone = tan(AppConfig.driveKeepMovingConeDegrees * .pi / 180)
        return keep.forward < 0 || abs(keep.right) > keep.forward * cone
    }

    /// Что держать в кадре: ближайшую камеру — кроме своей. Своя камера
    /// (CameraFamiliarity, «без голоса») знакома водителю, о ней молчит голос,
    /// и тянуть ради неё кадр в район незачем (снимок 63, 21.10: своя камера в
    /// 403 м на 10 км/ч уводила карту машины к z15).
    static func keep(camera id: Int, at point: CLLocationCoordinate2D, familiar: Set<Int>,
                     from car: CLLocationCoordinate2D, bearing: Double?) -> Keep? {
        guard !familiar.contains(id) else { return nil }
        return Keep.offset(from: car, to: point, bearing: bearing)
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

    /// Сколько метров дороги видно от машины до верхнего края вида или — с
    /// `clearTop` — до нижней кромки верхней панели.
    static func visibleAhead(zoom: Double, pitchDegrees: Double, viewHeight: Double,
                             carY: Double, latitude: Double, clearTop: Double = 0) -> Double {
        let span = span(zoom: zoom, viewHeight: viewHeight, latitude: latitude)
        // Кромка ниже машины — не обзор: панель не бывает выше «я».
        let top = min(max(0, clearTop), max(0, carY - 0.05))
        let toTop = -groundOffset(spanMeters: span, share: top - 0.5, pitchDegrees: pitchDegrees)
        return toTop + centreAhead(spanMeters: span, anchorY: carY, pitchDegrees: pitchDegrees)
    }

    /// Сколько метров видно от машины назад, до верхней кромки нижней
    /// панели; 0 — панель выше машины.
    static func visibleBehind(zoom: Double, pitchDegrees: Double, viewHeight: Double,
                              carY: Double, latitude: Double, clearBottom: Double = 0) -> Double {
        let bottom = 1 - min(max(0, clearBottom), 1)
        guard bottom > carY + 0.02 else { return 0 }
        let span = span(zoom: zoom, viewHeight: viewHeight, latitude: latitude)
        return groundOffset(spanMeters: span, share: bottom - 0.5, pitchDegrees: pitchDegrees)
            - groundOffset(spanMeters: span, share: carY - 0.5, pitchDegrees: pitchDegrees)
    }

    /// Метров на точку поперёк экрана в строке `share` ниже центра, к
    /// метрам на точку в центре: на наклоне ближние строки мельче.
    static func lateralScale(share: Double, pitchDegrees: Double) -> Double {
        let a = atan(2 * share * tan(fieldOfView / 2))
        let p = pitchDegrees * .pi / 180
        let ratio = cos(p) * cos(a) / cos(p - a)
        return ratio.isFinite && ratio > 0 ? ratio : 1
    }

    /// Самый крупный масштаб, при котором `keep` в незакрытой части экрана с
    /// запасом `keepMarginPoints`. Обзор в любую сторону ∝ 2^-zoom, запас —
    /// в точках, поэтому решение в одну строку на каждую сторону.
    static func maxZoom(keeping keep: Keep, pitchDegrees: Double, viewHeight: Double,
                        carY: Double, latitude: Double, clear: Clear) -> Double {
        let reference = 17.0
        let margin = keepMarginPoints * metersPerPoint(zoom: reference, latitude: latitude)
        var cap = Double.infinity
        /// `seen` — обзор в эту сторону на эталонном масштабе, `need` — метров до точки.
        func limit(_ seen: Double, _ need: Double) {
            guard seen > margin, need > 0 else { return }
            cap = min(cap, reference - log2(need / (seen - margin)))
        }
        let ahead = visibleAhead(zoom: reference, pitchDegrees: pitchDegrees, viewHeight: viewHeight,
                                 carY: carY, latitude: latitude, clearTop: clear.top)
        let behind = visibleBehind(zoom: reference, pitchDegrees: pitchDegrees, viewHeight: viewHeight,
                                   carY: carY, latitude: latitude, clearBottom: clear.bottom)
        let usable = clear.width / 2 - clear.side
        let perPoint = metersPerPoint(zoom: reference, latitude: latitude)
        func half(atShare share: Double) -> Double {
            usable > 0 ? perPoint * usable * lateralScale(share: share, pitchDegrees: pitchDegrees) : 0
        }
        if keep.anyDirection {
            // Сторона неизвестна — точка обязана влезть в самую короткую.
            let sides = [ahead, behind, half(atShare: carY - 0.5)].filter { $0 > margin }
            if let shortest = sides.min() { limit(shortest, keep.distance) }
            return cap
        }
        if keep.forward >= 0 {
            limit(ahead, keep.forward)
            // Впереди строка точки — между машиной и центром и выше: мерка центра.
            limit(half(atShare: 0), abs(keep.right))
        } else {
            limit(behind, -keep.forward)
            // Позади — самая мелкая строка, нижняя кромка.
            limit(half(atShare: 0.5 - min(max(0, clear.bottom), 1)), abs(keep.right))
        }
        return cap
    }

    /// Масштаб, при котором впереди видно ровно `meters`. Обзор обратно
    /// пропорционален 2^zoom при том же наклоне — решается в одну строку.
    static func zoomShowing(_ meters: Double, pitchDegrees: Double, viewHeight: Double,
                            carY: Double, latitude: Double, clearTop: Double = 0) -> Double {
        let reference = 17.0
        let seen = visibleAhead(zoom: reference, pitchDegrees: pitchDegrees, viewHeight: viewHeight,
                                carY: carY, latitude: latitude, clearTop: clearTop)
        guard seen > 0, meters > 0 else { return reference }
        return reference + log2(seen / meters)
    }

    // MARK: - Плавность

    /// Сглаживание во времени: кадр подходит к цели экспоненциально, а не
    /// ступенями. Ступени прежней камеры (охват по 30 м) на скорости у
    /// границы ступени «дышали» — то ближе, то дальше на каждом фиксе, — а
    /// после манёвра вид отпрыгивал назад одним рывком.
    ///
    /// Масштаб, кроме того, идёт через гистерезис (21.10, «то уменьшается, то
    /// увеличивается»): экспонента гладила переход, но повторяла каждый скачок
    /// цели — разгон и остановка в пробке, смена ближайшей камеры у порога
    /// 10 км/ч, поворот. Теперь:
    /// - продолжать в ту же сторону можно сразу; сменить направление — только
    ///   когда цель ушла за полосу гистерезиса и держится там (приближение
    ///   ждёт `driveZoomInDwell`, отъезд — `driveZoomOutConfirm`), и не
    ///   раньше `driveZoomReversalLock` после прошлой смены (обходного пути для
    ///   «срочного» отъезда нет: отъезд и так не быстрее уровня за 8 с, а
    ///   обход ломал ровность на каждой камере сбоку стоя — замер 21.10);
    /// - пока смена не разрешена, кадр не продолжает идти «не туда», а стоит;
    /// - скорость: отъезд не быстрее `driveZoomOutLevelsPerSecond`,
    ///   приближение не быстрее `driveZoomInLevelsPerSecond`.
    /// Наклон и место машины — прежняя экспонента (наклон — по таблице 25.D).
    struct Smoother: Sendable {
        private(set) var frame: Frame?
        private var time: Date?
        /// Куда сейчас идёт масштаб (уже принятое решение).
        private var goal = 0.0
        /// Масштаб без округления: округлённый шаг на частых вызовах (кадр
        /// SwiftUI, а не фикс) был бы нулём, и кадр стоял бы.
        private var exact = 0.0
        /// Последнее направление хода масштаба: +1 приближение, −1 отъезд, 0 — ещё не было.
        private var direction = 0
        /// Когда это направление началось.
        private var directionSince: Date?
        /// Цель за полосой гистерезиса в обратную сторону: с какого момента и
        /// самое осторожное её значение за это время.
        private var pendingSince: Date?
        private var pendingZoom = 0.0

        /// Постоянная времени, с.
        static let tau = 2.0
        /// После паузы дольше этого — сразу к цели (вернулись к карте).
        static let maxGap = 5.0
        /// Ближе этого к цели — уже у цели (шаг округления ×2).
        static let snap = 0.02

        mutating func step(toward target: Frame, at now: Date) -> Frame {
            defer { time = now }
            guard var current = frame, let last = time else { return jump(to: target, at: now) }
            let dt = now.timeIntervalSince(last)
            guard dt >= 0, dt <= Self.maxGap else { return jump(to: target, at: now) }
            let k = 1 - exp(-dt / Self.tau)
            decide(target.zoom, from: exact, at: now)
            let zoom = glide(exact, toward: goal, k: k, dt: dt)
            if abs(zoom - exact) > 1e-9 {
                let moved = zoom > exact ? 1 : -1
                if moved != direction {
                    direction = moved
                    directionSince = now
                }
            }
            exact = zoom
            // Движку — с шагом 0,01: не новая анимация на каждую тысячную.
            current.zoom = zoom == goal ? zoom : (zoom / 0.01).rounded() * 0.01
            current.pitchDegrees = approach(current.pitchDegrees, target.pitchDegrees, k, snap: 0.5, step: 0.5)
            current.carShare = approach(current.carShare, target.carShare, k, snap: 0.004, step: 0.002)
            frame = current
            return current
        }

        mutating func reset() {
            self = Smoother()
        }

        private mutating func jump(to target: Frame, at now: Date) -> Frame {
            self = Smoother()
            frame = target
            goal = target.zoom
            exact = target.zoom
            return target
        }

        /// Решение о цели масштаба: та же сторона — сразу, обратная — через
        /// гистерезис, выдержку и запрет частой смены.
        private mutating func decide(_ wanted: Double, from zoom: Double, at now: Date) {
            guard wanted != zoom else {
                goal = wanted
                pendingSince = nil
                return
            }
            let wantsIn = wanted > zoom
            if direction == 0 || direction == (wantsIn ? 1 : -1) {
                // Та же сторона (или первый ход) — без задержек.
                goal = wanted
                pendingSince = nil
                return
            }
            // Обратная сторона: пока не разрешено — стоим, а не идём «не туда».
            goal = zoom
            let band = wantsIn ? AppConfig.driveZoomInDeadband : AppConfig.driveZoomOutDeadband
            guard abs(wanted - zoom) > band else {
                pendingSince = nil
                return
            }
            if let since = pendingSince {
                // Принимаем самое осторожное значение за выдержку.
                pendingZoom = wantsIn ? min(pendingZoom, wanted) : max(pendingZoom, wanted)
                let hold = wantsIn ? AppConfig.driveZoomInDwell : AppConfig.driveZoomOutConfirm
                let unlocked = directionSince.map { now.timeIntervalSince($0) >= AppConfig.driveZoomReversalLock } ?? true
                if now.timeIntervalSince(since) >= hold, unlocked {
                    goal = pendingZoom
                    pendingSince = nil
                }
            } else {
                pendingSince = now
                pendingZoom = wanted
            }
        }

        /// Ход масштаба к цели: экспонента, но не быстрее предела стороны.
        private func glide(_ value: Double, toward target: Double, k: Double, dt: Double) -> Double {
            let delta = (target - value) * k
            let limited = min(AppConfig.driveZoomInLevelsPerSecond * dt,
                              max(-AppConfig.driveZoomOutLevelsPerSecond * dt, delta))
            let next = value + limited
            return abs(target - next) < Self.snap ? target : next
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
