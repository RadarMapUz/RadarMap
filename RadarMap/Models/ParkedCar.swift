//
//  ParkedCar.swift
//  RadarMap
//
//  «Где машина» (план 19.10, 12б.1). Поездка кончилась — машина где-то
//  стоит, и это единственная точка, которую через час ищут глазами: у
//  торгового центра, на чужой улице, у базара. Пешком Apple Maps в
//  Узбекистане не ведёт, поэтому подсказка — метка машины на карте и строка
//  «Машина · 350 м» со стрелкой, а не маршрут.
//
//  Правила — здесь, чистые и с тестами (ParkedCarTests):
//    * паркует только конец поездки за рулём при точной точке (≤ 30 м):
//      пассажир машину не ставил, а грубая точка из помещения показала бы
//      «машину» в соседнем квартале — хуже, чем ничего. Точка — последняя,
//      где ещё ЕХАЛИ (≥ 12 км/ч), а не позиция в момент автостопа: он
//      приходит через три минуты стоянки, когда человек уже ушёл;
//    * остановка ВНУТРИ поездки (склейка TripMerge) не паркует — поездка
//      продолжается, и новая поездка, склеенная или нет, сбрасывает точку:
//      человек уже в машине;
//    * показ — когда отошли ≥ 150 м и прошло ≥ 2 мин: у подъезда стрелка на
//      машину в десяти метрах — шум;
//    * сброс — подошли к машине (≤ 30 м) ПОСЛЕ того, как отходили: сразу
//      после парковки человек и так стоит рядом; или прошло трое суток.
//
//  Точка живёт только на телефоне (Storage), на сервер не уходит.
//

import Foundation
import CoreLocation

nonisolated struct ParkedCar: Codable, Equatable, Sendable {
    let lat: Double
    let lon: Double
    let parkedAt: Date
    /// Отходили ли от машины дальше порога показа: только после этого
    /// «подошли на 30 м» значит «вернулись к машине».
    var hasLeft: Bool = false

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Последняя точка, где ещё ехали: автостоп срабатывает через три минуты
    /// стоянки, и к этому моменту человек мог уйти от машины на сотни метров —
    /// нынешняя позиция была бы его, а не машины.
    struct Fix: Equatable, Sendable {
        let lat: Double
        let lon: Double
        let accuracy: Double
    }

    /// Фикс годится в «последнюю точку езды»: скорость выше пешей и бега.
    static func isDriving(speedKmh: Double) -> Bool {
        speedKmh >= AppConfig.parkedCarDrivingKmh
    }

    /// Машина встала: конец поездки за рулём при точной последней точке езды.
    static func park(lastDriven: Fix?, asPassenger: Bool, now: Date) -> ParkedCar? {
        guard !asPassenger, let fix = lastDriven,
              fix.accuracy > 0, fix.accuracy <= AppConfig.parkedCarMaxAccuracyMeters else { return nil }
        return ParkedCar(lat: fix.lat, lon: fix.lon, parkedAt: now)
    }

    /// Что показать сейчас.
    enum State: Equatable {
        /// Не показывать. `recheckIn` — через сколько секунд ответ может
        /// смениться сам, без нового фикса (стоим, а две минуты ещё не прошли).
        case hidden(recheckIn: TimeInterval?)
        /// Показать: расстояние и азимут от нас на машину (0–360°, от севера).
        case shown(meters: Double, bearing: Double)
        /// Точку пора забыть: вернулись к машине или прошло трое суток.
        case expired
    }

    /// Решение по нашей позиции. Мутирует только `hasLeft` — вызывающий
    /// сохраняет точку, если она изменилась.
    mutating func update(here: CLLocationCoordinate2D?, now: Date) -> State {
        let age = now.timeIntervalSince(parkedAt)
        if age >= AppConfig.parkedCarMaxAgeSeconds { return .expired }
        guard let here else { return .hidden(recheckIn: nil) }
        let meters = GeoMath.fastDistance(here.latitude, here.longitude, lat, lon)
        if meters >= AppConfig.parkedCarShowMeters { hasLeft = true }
        if hasLeft, meters <= AppConfig.parkedCarReachedMeters { return .expired }
        guard meters >= AppConfig.parkedCarShowMeters else { return .hidden(recheckIn: nil) }
        let wait = AppConfig.parkedCarShowAfterSeconds - age
        guard wait <= 0 else { return .hidden(recheckIn: wait) }
        return .shown(meters: meters, bearing: GeoMath.bearing(from: here, to: coordinate))
    }

    /// Подсказка для строки: расстояние и азимут ступенями — строка
    /// перерисовывается, когда меняется то, что видно, а не на каждом фиксе.
    struct Hint: Equatable {
        let meters: Double
        let bearing: Double

        init(meters: Double, bearing: Double) {
            let step = meters < 1000 ? 10.0 : 100.0
            self.meters = (meters / step).rounded() * step
            self.bearing = ((bearing / 10).rounded() * 10).truncatingRemainder(dividingBy: 360)
        }
    }

    /// Поворот стрелки на экране: азимут на машину минус поворот карты —
    /// стрелка показывает туда же, где метка машины на карте.
    static func arrowRotation(bearing: Double, mapDirection: Double) -> Double {
        let value = (bearing - mapDirection).truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }
}
