//
//  QuietAlertGate.swift
//  RadarMap
//
//  Уведомление о камере в ТИХОМ ФОНЕ (поездки нет, экран не открыт) — только
//  когда есть доказательство, что мы едем на машине (этап 26.1).
//
//  Цепочка, которую это закрывает (владелец, 21.10: «Камера через 550 м» пришло
//  дома): в тихом фоне о камерах говорят двадцать геозон `CLCircularRegion`
//  радиусом `alertRadius` вокруг ближайших камер. Вход в геозону система
//  определяет не по GPS, а по Wi-Fi и вышкам — с ошибкой 100–500 м, и телефон,
//  лежащий дома в 500–600 м от камеры, «входит» в её круг от дрожания этой
//  ошибки. `handleEnter` слал уведомление на любой вход, а выход снимал
//  отметку «уже предупредили» — следующее дрожание присылало его снова.
//
//  Правило здесь ОБРАТНОЕ правилу оповещений в поездке, и это осознанно: в
//  поездке молчание о камере хуже лишнего писка, и там эти ворота не стоят
//  вовсе. Вне поездки нет ни курса, ни скорости, ни уверенности, что человек
//  вообще в машине, а пуш на диване учит выключать уведомления — и тогда
//  молчит и та камера, о которой предупредить было нужно. Поэтому вне
//  поездки уведомление только с доказательством езды:
//  - CoreMotion недавно видел «в машине» (уверенно), или
//  - свежий GPS-фикс с доплеровской скоростью машины, или
//  - два фикса со смещением, которого не даст дрожание, и скоростью машины.
//  Тишина — на стоянке (CoreMotion уверен «стоим»), пешком, у Дома и Работы
//  (если машину не видел CoreMotion), при свежем точном фиксе далеко от
//  камеры (вход ложный), повторно об одной камере в пределах окна и в режиме
//  «Только в машине» без подключения к ней.
//
//  Чистая логика без Date.now и без хранилища — QuietAlertGateTests.
//

import Foundation
import CoreLocation

nonisolated enum QuietAlertGate {

    /// Что CoreMotion знает о последних минутах.
    enum Motion: Equatable {
        /// В машине (едем или стоим на светофоре) — уверенно.
        case automotive
        /// Телефон лежит, машины рядом по времени не было.
        case stationary
        /// Пешком, бегом, на велосипеде.
        case onFoot
        /// Нет разрешения, нет данных — не знаем.
        case unknown
    }

    /// Один сэмпл CoreMotion (`CMMotionActivity`) — без фреймворка, для тестов.
    struct MotionSample: Equatable {
        let start: Date
        var automotive = false
        var walking = false
        var running = false
        var cycling = false
        var stationary = false
        /// `confidence != .low`.
        var confident = true
    }

    struct Situation {
        let now: Date
        let cameraLat: Double
        let cameraLon: Double
        /// Радиус геозоны, м.
        let radius: CLLocationDistance
        /// Недавние фиксы тихого фона (сырые, до фильтра), старые первыми.
        let fixes: [LocationFilter.Fix]
        let motion: Motion
        /// Дом и Работа (заданные и выученные).
        let quietZones: [CLLocationCoordinate2D]
        /// Когда об этой камере последний раз приходило уведомление.
        let lastNotifiedAt: Date?
        /// Режим «Только в машине»: вне подключения к машине — тишина.
        let requiresCarLink: Bool
        let carLinked: Bool
    }

    enum Reason: String, Equatable {
        case repeatCamera   // уже предупреждали об этой камере недавно
        case notInCar       // «Только в машине», а машина не подключена
        case onFoot         // CoreMotion: пешком/велосипед
        case standing       // CoreMotion: телефон лежит
        case outsideRegion  // свежий точный фикс далеко от камеры — вход ложный
        case atHomeOrWork   // у Дома/Работы, машины CoreMotion не видел
        case noProof        // доказательства езды нет (пока)

        /// Решение, которое новый фикс уже не изменит. Остальные ждут
        /// доказательства до конца окна (`quietAlertEvidenceSeconds`).
        var isFinal: Bool {
            switch self {
            case .repeatCamera, .notInCar, .onFoot, .standing: return true
            case .outsideRegion, .atHomeOrWork, .noProof: return false
            }
        }
    }

    enum Decision: Equatable {
        case notify
        case silence(Reason)
    }

    // MARK: - Решение

    static func decide(_ s: Situation) -> Decision {
        if let last = s.lastNotifiedAt,
           s.now.timeIntervalSince(last) < AppConfig.quietAlertRepeatSeconds {
            return .silence(.repeatCamera)
        }
        if s.requiresCarLink, !s.carLinked { return .silence(.notInCar) }
        switch s.motion {
        case .onFoot: return .silence(.onFoot)
        case .stationary: return .silence(.standing)
        case .automotive, .unknown: break
        }
        // Свежий точный фикс далеко за кругом — система ошиблась со входом.
        // Проверка раньше доказательства езды: машина, проезжающая В СТОРОНЕ
        // от камеры (параллельная улица за 700 м), тоже не повод.
        if let fresh = freshestPrecise(s.fixes, now: s.now), isOutside(fresh, s) {
            return .silence(.outsideRegion)
        }
        // CoreMotion видел машину — едем (включая отъезд от дома).
        if s.motion == .automotive { return .notify }
        // Без CoreMotion — у Дома и Работы молчим: здесь телефон лежит часами,
        // и всё дрожание Wi-Fi-координат приходится именно на эти места.
        if let here = s.fixes.last, isInQuietZone(here, zones: s.quietZones) {
            return .silence(.atHomeOrWork)
        }
        if hasDopplerProof(s.fixes, now: s.now) || hasDisplacementProof(s.fixes, now: s.now) {
            return .notify
        }
        return .silence(.noProof)
    }

    // MARK: - CoreMotion

    /// Сводка сэмплов CoreMotion: последний уверенный сэмпл — состояние «сейчас»
    /// (сэмпл длится до следующего). Машина в окне `quietAlertMotionWindowSeconds`
    /// перед последним сэмплом «стоим» — это светофор, а не диван.
    static func motion(from samples: [MotionSample], now: Date) -> Motion {
        let confident = samples.filter { $0.confident && $0.start <= now }
            .sorted { $0.start < $1.start }
        guard let latest = confident.last else { return .unknown }
        if latest.automotive { return .automotive }
        if latest.walking || latest.running || latest.cycling { return .onFoot }
        if latest.stationary {
            let since = now.addingTimeInterval(-AppConfig.quietAlertMotionWindowSeconds)
            let recentCar = confident.contains { $0.automotive && $0.start >= since }
            return recentCar ? .automotive : .stationary
        }
        return .unknown
    }

    // MARK: - Фиксы

    static func freshestPrecise(_ fixes: [LocationFilter.Fix], now: Date) -> LocationFilter.Fix? {
        fixes.last {
            $0.horizontalAccuracy > 0
                && $0.horizontalAccuracy <= AppConfig.quietAlertDopplerMaxAccuracy
                && age($0, now: now) <= AppConfig.quietAlertFreshFixSeconds
        }
    }

    /// Фикс дальше круга с запасом на погрешность и на путь, проделанный с его
    /// момента на его же скорости.
    static func isOutside(_ fix: LocationFilter.Fix, _ s: Situation) -> Bool {
        let distance = GeoMath.fastDistance(fix.lat, fix.lon, s.cameraLat, s.cameraLon)
        let travelled = max(0, fix.speed) * age(fix, now: s.now)
        return distance > s.radius + fix.horizontalAccuracy + travelled
            + AppConfig.quietAlertOutsideMarginMeters
    }

    static func isInQuietZone(_ fix: LocationFilter.Fix,
                              zones: [CLLocationCoordinate2D]) -> Bool {
        zones.contains {
            GeoMath.fastDistance(fix.lat, fix.lon, $0.latitude, $0.longitude)
                <= AppConfig.quietZoneMeters
        }
    }

    /// Доплеровская скорость спутникового фикса: Wi-Fi и вышки её не дают
    /// вовсе (speed < 0), так что дрожание дома сюда не проходит.
    static func hasDopplerProof(_ fixes: [LocationFilter.Fix], now: Date) -> Bool {
        fixes.contains { fix in
            guard fix.speed >= 0, fix.horizontalAccuracy > 0,
                  fix.horizontalAccuracy <= AppConfig.quietAlertDopplerMaxAccuracy,
                  age(fix, now: now) <= AppConfig.quietAlertFreshFixSeconds else { return false }
            if fix.speedAccuracy >= 0,
               fix.speedAccuracy * 3.6 > AppConfig.quietAlertMaxSpeedErrorKmh { return false }
            return fix.speed * 3.6 >= AppConfig.quietAlertMinSpeedKmh
        }
    }

    /// Два фикса: смещение больше суммы их погрешностей вдвое и не меньше
    /// порога (дрожание Wi-Fi в 300 м не проходит), средняя скорость — машины.
    static func hasDisplacementProof(_ fixes: [LocationFilter.Fix], now: Date) -> Bool {
        let usable = fixes.filter {
            $0.horizontalAccuracy > 0
                && $0.horizontalAccuracy <= AppConfig.quietAlertMaxFixAccuracy
                && age($0, now: now) <= AppConfig.quietAlertFixWindowSeconds
        }
        guard let last = usable.last else { return false }
        return usable.dropLast().contains { first in
            let dt = last.timestamp.timeIntervalSince(first.timestamp)
            guard dt >= AppConfig.quietAlertMinFixGapSeconds else { return false }
            let d = GeoMath.fastDistance(first.lat, first.lon, last.lat, last.lon)
            let noise = 2 * (first.horizontalAccuracy + last.horizontalAccuracy)
            guard d >= max(noise, AppConfig.quietAlertMinDisplacementMeters) else { return false }
            let kmh = d / dt * 3.6
            return kmh >= AppConfig.quietAlertMinSpeedKmh && kmh <= AppConfig.quietAlertMaxSpeedKmh
        }
    }

    private static func age(_ fix: LocationFilter.Fix, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(fix.timestamp))
    }

    // MARK: - Журнал уведомлений (дедуп)

    /// Журнал «камера → когда уведомили», без записей старше окна повтора.
    /// Хранится на диске: геозона будит НОВЫЙ процесс, и память о прошлом
    /// уведомлении в нём пуста.
    static func pruned(_ log: [Int: Date], now: Date) -> [Int: Date] {
        log.filter { now.timeIntervalSince($0.value) < AppConfig.quietAlertRepeatSeconds }
    }
}
