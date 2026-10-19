//
//  TripOdometer.swift
//  RadarMap
//
//  Пробег поездки (S13, 20.10). Два дефекта прежнего «сумма шагов меньше
//  500 м»: на стоянке приёмник гуляет на 5–30 м и за час пробки набегал
//  километр, а дыра длиннее 500 м (туннель, потеря сигнала, поздний
//  автостарт после магазина) выпадала из пробега целиком.
//
//  Решение — опора, а не последний фикс: пока стоим, опора не двигается, и
//  тронувшись, смещение от неё засчитывается одним шагом; дыра идёт в пробег
//  хордой (меньше настоящего пути, но не ноль), если средняя скорость по
//  хорде правдоподобна для машины, — иначе это перелёт приёмника.
//

import CoreLocation
import Foundation

nonisolated struct TripOdometer: Sendable {
    private(set) var anchor: CLLocationCoordinate2D?
    private(set) var anchorAt: Date?

    init(anchor: CLLocationCoordinate2D? = nil, at time: Date? = nil) {
        self.anchor = anchor
        anchorAt = anchor == nil ? nil : time
    }

    /// Принятый фикс: сколько метров прибавить к пробегу. `stopped` — машина
    /// стоит (Standstill): шаг — дрожание, опора на месте.
    mutating func advance(to coordinate: CLLocationCoordinate2D, at time: Date, stopped: Bool) -> Double {
        guard let anchor else {
            self.anchor = coordinate
            anchorAt = time
            return 0
        }
        // Тем же способом, что и весь пайплайн: HUD, гейты и запись проезда
        // обязаны сходиться в цифрах, а на масштабе одного тика (десятки
        // метров) разница с точной формулой — доли процента.
        let step = GeoMath.fastDistance(anchor.latitude, anchor.longitude,
                                        coordinate.latitude, coordinate.longitude)
        guard let counted = Self.counted(step, seconds: anchorAt.map { time.timeIntervalSince($0) },
                                         stopped: stopped) else { return 0 }
        self.anchor = coordinate
        anchorAt = time
        return counted
    }

    /// `nil` — стоим: опору не двигать. Короткий шаг — как есть; дыра —
    /// хордой, если по ней не быстрее `tripGapMaxSpeedMps`; иначе ноль (а
    /// опора переезжает: после перелёта считать от новой точки).
    static func counted(_ step: Double, seconds: TimeInterval?, stopped: Bool) -> Double? {
        if stopped { return nil }
        if step < AppConfig.tripMaxStepMeters { return step }
        guard let seconds, seconds > 0, step / seconds <= AppConfig.tripGapMaxSpeedMps else { return 0 }
        return step
    }
}
