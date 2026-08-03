//
//  LocationFilter.swift
//  RadarMap
//
//  Гейт качества GPS-фикса: что можно пускать в алерты, трек и статистику.
//  Раньше в обработку шёл ЛЮБОЙ фикс, и это давало не косметические ошибки:
//  первый фикс после запуска или выезда из туннеля часто кэшированный со старого
//  места, «прыжок» позиции через камеру записывался как настоящий проезд с
//  занижённой скоростью (PassTracking берёт минимум по зоне измерения), а в
//  городских каньонах расстояние до камеры скакало и алерт срабатывал дважды.
//
//  Здесь же решается вопрос курса. Ось дороги камеры (гейт мостов) и коридор
//  считаются от курса, поэтому недостоверный курс опаснее отсутствующего: он
//  ЗАГЛУШИТ настоящую камеру. Поэтому сырой курс берётся только когда система
//  сама в нём уверена (courseAccuracy), иначе считаем курс по земле — по двум
//  последним принятым фиксам, — а если и это невозможно, отдаём −1: направленные
//  фильтры при этом отключаются и лучше предупредить лишний раз.
//
//  Чистая структура без CLLocation: всё покрыто тестами (LocationFilterTests).
//

import CoreLocation

nonisolated struct LocationFilter {

    /// Фикс в виде голых чисел — движок не зависит от CoreLocation.
    struct Fix: Equatable {
        let lat: Double
        let lon: Double
        /// Метры; ≤ 0 — система считает координату недостоверной.
        let horizontalAccuracy: Double
        /// м/с; < 0 — скорость неизвестна (туннель, плохая геометрия спутников).
        let speed: CLLocationSpeed
        /// м/с; < 0 — устройство не оценивает точность скорости.
        let speedAccuracy: Double
        /// Градусы 0…360; < 0 — курс недостоверен.
        let course: CLLocationDirection
        /// Градусы; < 0 — устройство не оценивает точность курса.
        let courseAccuracy: Double
        let timestamp: Date
    }

    /// Почему фикс отброшен — уходит в лог, молча глотать нельзя.
    enum Rejection: String, Equatable {
        case accuracy   // погрешность больше допустимой (или отрицательная)
        case stale      // кэш со старого места / часы уехали в будущее
        case jump       // мгновенный перелёт: между фиксами скорость нереальна
    }

    /// Принятый фикс с уже проверенными курсом и скоростью.
    struct Accepted: Equatable {
        let lat: Double
        let lon: Double
        /// Доверенный курс или −1 — тогда направленные фильтры не применяются.
        let course: CLLocationDirection
        /// м/с или nil — скорость держим прошлую, нулём считать нельзя.
        let speed: CLLocationSpeed?
    }

    enum Outcome: Equatable {
        case accepted(Accepted)
        case rejected(Rejection)
    }

    private var lastAccepted: (lat: Double, lon: Double, at: Date)?

    /// `now` параметром — чтобы тесты не зависели от часов.
    mutating func accept(_ fix: Fix, now: Date = Date()) -> Outcome {
        guard fix.horizontalAccuracy > 0,
              fix.horizontalAccuracy <= AppConfig.maxHorizontalAccuracyMeters else {
            return .rejected(.accuracy)
        }
        // Отрицательный возраст — часы устройства ушли вперёд относительно фикса.
        let age = now.timeIntervalSince(fix.timestamp)
        guard abs(age) < AppConfig.maxFixAgeSeconds else { return .rejected(.stale) }
        if let jump = isJump(fix) , jump { return .rejected(.jump) }

        let course = trustedCourse(fix)
        let speed = trustedSpeed(fix)
        lastAccepted = (fix.lat, fix.lon, fix.timestamp)
        return .accepted(Accepted(lat: fix.lat, lon: fix.lon, course: course, speed: speed))
    }

    /// Смена режима GPS/новая поездка: прошлая точка больше не опора для курса.
    mutating func reset() {
        lastAccepted = nil
    }

    // MARK: - Проверки

    /// Перелёт: между двумя фиксами прошло мало времени, а расстояние такое, что
    /// машина так не едет. Именно это и создаёт ложные проезды камер.
    private func isJump(_ fix: Fix) -> Bool? {
        guard let last = lastAccepted else { return nil }
        let moved = GeoMath.fastDistance(last.lat, last.lon, fix.lat, fix.lon)
        let dt = fix.timestamp.timeIntervalSince(last.at)
        // Один и тот же (или ушедший назад) штамп: судим по одному расстоянию.
        guard dt > 0 else { return moved > AppConfig.maxPlausibleJumpMeters }
        // После долгой паузы (стоянка, фон) большое смещение законно.
        guard dt <= AppConfig.jumpCheckMaxSeconds else { return false }
        return moved / dt > AppConfig.maxPlausibleSpeedMps
    }

    private func trustedCourse(_ fix: Fix) -> CLLocationDirection {
        // Сырой курс — только когда система сама в нём уверена.
        if fix.course >= 0, fix.courseAccuracy >= 0,
           fix.courseAccuracy <= AppConfig.courseMaxAccuracyDegrees {
            return fix.course
        }
        // Курс по земле: на малой скорости и при плохой геометрии спутников он
        // надёжнее сырого. Нужен заметный сдвиг, иначе считаем шум.
        if let last = lastAccepted {
            let moved = GeoMath.fastDistance(last.lat, last.lon, fix.lat, fix.lon)
            let dt = fix.timestamp.timeIntervalSince(last.at)
            if moved >= AppConfig.derivedCourseMinMeters, dt > 0,
               dt <= AppConfig.derivedCourseMaxSeconds {
                return GeoMath.bearing(
                    from: CLLocationCoordinate2D(latitude: last.lat, longitude: last.lon),
                    to: CLLocationCoordinate2D(latitude: fix.lat, longitude: fix.lon))
            }
        }
        return -1   // курса нет — ось и коридор обязаны молчать
    }

    private func trustedSpeed(_ fix: Fix) -> CLLocationSpeed? {
        guard fix.speed >= 0 else { return nil }
        // speedAccuracy < 0 — устройство не оценивает точность, но сама скорость
        // при этом обычно верна: отбрасываем только явно плохую оценку.
        if fix.speedAccuracy >= 0,
           fix.speedAccuracy > AppConfig.maxSpeedAccuracyMps { return nil }
        return fix.speed
    }
}

extension LocationFilter.Fix {
    /// Фикс из CoreLocation. Единственное место, где движок встречается с CLLocation.
    init(_ location: CLLocation) {
        self.init(lat: location.coordinate.latitude,
                  lon: location.coordinate.longitude,
                  horizontalAccuracy: location.horizontalAccuracy,
                  speed: location.speed,
                  speedAccuracy: location.speedAccuracy,
                  course: location.course,
                  courseAccuracy: location.courseAccuracy,
                  timestamp: location.timestamp)
    }
}
