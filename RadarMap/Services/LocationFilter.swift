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
//  сама в нём уверена (courseAccuracy), иначе считаем курс по земле — от
//  последнего годного фикса, отстоящего не меньше чем на шаг (от
//  `derivedCourseMinMeters`, см. ниже) и не старше `derivedCourseMaxSeconds`,
//  — а если и это невозможно, отдаём −1: направленные фильтры при этом
//  отключаются и лучше предупредить лишний раз.
//
//  Опора — не обязательно СОСЕДНИЙ фикс. Пока курс по земле считался только
//  по двум соседним, при фиксах раз в секунду он появлялся лишь быстрее
//  43 км/ч (12 м за секунду): на городских 30–40 км/ч — ровно там, где сырой
//  курс хуже всего (каньоны), а параллельных улиц больше всего, — курса не
//  было вовсе, и гейты молчали всю дорогу. В симуляторе (courseAccuracy там
//  всегда −1) на 40 км/ч гейты не включались ни разу (прогон 13.3, 20.10).
//
//  Курс по земле — только между ГОДНЫМИ фиксами (14.13). Фиксы уровня
//  Wi-Fi (точность 30–65 м — фильтр их пропускает, позиция района годится)
//  прыгают на десятки метров, и «сдвиг в 12 м» между ними — шум, а не путь:
//  курс выходил поперёк дороги на каждом фиксе, гейт оси ему верил и глушил
//  камеру на нашей же дороге весь подъезд. Поэтому ни текущий фикс, ни опора
//  не бывают хуже `courseProofMaxAccuracyMeters` (тот же порог, что у
//  доказательств записи проезда и охвата, 14.10: курс, который ничего не
//  доказывает там, не вправе глушить и здесь), а сдвиг обязан превышать
//  сумму их погрешностей (`derivedCourseAccuracyFactor`). На хорошем GPS
//  (5–6 м) шаг остаётся прежним — 12 м. Сырой курс с уверенной оценкой
//  системы этим не ограничен: он доплеровский, и в каньоне портится позиция,
//  а не скорость.
//
//  Одно исключение — повторный фикс на ходу: курс секунду назад был
//  доверенный, машина едет, а фикс пришёл через миллисекунды или сдвинулся
//  явно меньше, чем следует из его же скорости. Его отдаёт
//  iOS после перенастройки точности, а точность меняется как раз у камер —
//  и −1 на один тик выключал гейты: ближайшей становилась камера соседней
//  улицы в 130–330 м сбоку, с баннером и голосом (прогон 20.10). Курс двух
//  секунд давности на ходу — почти доказательство; дальше снова −1.
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
        /// Координату подменила программа (симулятор, Xcode, GPX на телефоне
        /// разработчика): для алертов это обычный фикс, но в общие данные —
        /// пробки — такая поездка не идёт (TrafficService.contributes).
        var isSimulated = false
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
        /// Погрешность координаты: геометрические проверки обязаны смягчаться
        /// на плохом фиксе, иначе отбросят камеру на нашей же дороге.
        let accuracy: Double
        /// Погрешность доверенной скорости, м/с; < 0 — неизвестна или скорости
        /// нет. Спидометру: доплер не больше своей погрешности — не отличим
        /// от нуля (шум стоя, Standstill, 25.C).
        var speedAccuracy: Double = -1
    }

    enum Outcome: Equatable {
        case accepted(Accepted)
        case rejected(Rejection)
    }

    private var lastAccepted: (lat: Double, lon: Double, at: Date)?
    /// Недавние ГОДНЫЕ фиксы — опоры для курса по земле, новые в конце.
    /// Хранятся не дольше `derivedCourseMaxSeconds` и не больше
    /// `derivedCourseAnchorLimit` штук: дальше опора уже ничего не значит.
    /// Фикс хуже `courseProofMaxAccuracyMeters` опорой не бывает.
    private var recent: [(lat: Double, lon: Double, at: Date, accuracy: Double)] = []
    /// Последний доверенный курс — держим его на повторном фиксе на ходу.
    private var lastCourse: (course: CLLocationDirection, at: Date)?

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

        let speed = trustedSpeed(fix)
        let course = trustedCourse(fix, speed: speed)
        // Опора — только измеренный курс: удержанный её не продлевает, иначе
        // цепочка повторов держала бы курс сколько угодно.
        if course.measured { lastCourse = (course.value, fix.timestamp) }
        lastAccepted = (fix.lat, fix.lon, fix.timestamp)
        remember(fix)
        return .accepted(Accepted(lat: fix.lat, lon: fix.lon, course: course.value,
                                  speed: speed, accuracy: fix.horizontalAccuracy,
                                  speedAccuracy: speed == nil ? -1 : fix.speedAccuracy))
    }

    /// Смена режима GPS/новая поездка: прошлая точка больше не опора для курса.
    mutating func reset() {
        lastAccepted = nil
        lastCourse = nil
        recent.removeAll()
    }

    private mutating func remember(_ fix: Fix) {
        recent.removeAll { fix.timestamp.timeIntervalSince($0.at) > AppConfig.derivedCourseMaxSeconds }
        guard fix.horizontalAccuracy <= AppConfig.courseProofMaxAccuracyMeters else { return }
        recent.append((fix.lat, fix.lon, fix.timestamp, fix.horizontalAccuracy))
        if recent.count > AppConfig.derivedCourseAnchorLimit {
            recent.removeFirst(recent.count - AppConfig.derivedCourseAnchorLimit)
        }
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

    /// Курс и признак «измерен на этом фиксе» (сырой или по земле), а не
    /// удержан с прошлого.
    private func trustedCourse(_ fix: Fix,
                               speed: CLLocationSpeed?) -> (value: CLLocationDirection, measured: Bool) {
        // Сырой курс — только когда система сама в нём уверена.
        if fix.course >= 0, fix.courseAccuracy >= 0,
           fix.courseAccuracy <= AppConfig.courseMaxAccuracyDegrees {
            return (fix.course, true)
        }
        // Курс по земле: на малой скорости и при плохой геометрии спутников он
        // надёжнее сырого. Нужен заметный сдвиг, иначе считаем шум. Опора —
        // САМЫЙ СВЕЖИЙ фикс, от которого сдвиг уже заметный: на 40 км/ч это
        // позапрошлый (22 м), на 60 — прошлый, как и раньше. Только между
        // годными фиксами (см. шапку): плохой фикс курса по земле не получает.
        if fix.horizontalAccuracy <= AppConfig.courseProofMaxAccuracyMeters {
            for anchor in recent.reversed() {
                let dt = fix.timestamp.timeIntervalSince(anchor.at)
                guard dt <= AppConfig.derivedCourseMaxSeconds else { break }
                guard dt > 0 else { continue }
                let moved = GeoMath.fastDistance(anchor.lat, anchor.lon, fix.lat, fix.lon)
                if moved >= Self.derivedCourseStep(anchor.accuracy, fix.horizontalAccuracy) {
                    return (GeoMath.bearing(
                        from: CLLocationCoordinate2D(latitude: anchor.lat, longitude: anchor.lon),
                        to: CLLocationCoordinate2D(latitude: fix.lat, longitude: fix.lon)), true)
                }
            }
        }
        // Повторный фикс на ходу (см. шапку): курс недавний, едем — держим.
        // Стоя не держим: стоящая машина не едет мимо камеры, а её курс — шум.
        // Свой сырой курс у фикса есть, пусть и недоверенный, и он смотрит
        // совсем в другую сторону — это поворот, а не повтор: не держим.
        if let held = lastCourse, let speed, isRepeat(fix, speed: speed),
           speed * 3.6 >= AppConfig.directionalMinSpeedKmh,
           fix.timestamp.timeIntervalSince(held.at) <= AppConfig.courseHoldSeconds,
           fix.course < 0 || GeoMath.angleDifference(fix.course, held.course)
                <= AppConfig.courseHoldMaxTurnDegrees {
            return (held.course, false)
        }
        return (-1, false)   // курса нет — ось и коридор обязаны молчать
    }

    /// Сдвиг, с которого курс по земле — путь, а не шум двух координат: не
    /// меньше `derivedCourseMinMeters` и не меньше суммы погрешностей опоры и
    /// фикса (с множителем `derivedCourseAccuracyFactor`). Сдвинься оба фикса
    /// на всю свою погрешность поперёк пути в разные стороны — курс уйдёт не
    /// больше чем на 45°, меньше порога гейта оси (`cameraAxisMaxAngle`).
    private static func derivedCourseStep(_ anchorAccuracy: Double, _ fixAccuracy: Double) -> Double {
        max(AppConfig.derivedCourseMinMeters,
            AppConfig.derivedCourseAccuracyFactor * (anchorAccuracy + fixAccuracy))
    }

    /// Повтор прошлого фикса, а не новое измерение: пришёл почти сразу или
    /// сдвинулся заметно меньше, чем следует из его же скорости. Настоящий
    /// фикс в повороте на 30 км/ч сдвигается на свои 8 м — он не повтор, и
    /// курс для него по-прежнему −1.
    private func isRepeat(_ fix: Fix, speed: CLLocationSpeed) -> Bool {
        guard let last = lastAccepted else { return false }
        let moved = GeoMath.fastDistance(last.lat, last.lon, fix.lat, fix.lon)
        let dt = fix.timestamp.timeIntervalSince(last.at)
        return dt < AppConfig.courseRepeatMaxSeconds
            || moved < speed * dt * AppConfig.courseRepeatMoveShare
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
    /// Фикс из CoreLocation. Единственное место, где движок встречается с
    /// CLLocation. nonisolated: зовётся из nonisolated-делегата CLLocationManager.
    nonisolated init(_ location: CLLocation) {
        self.init(lat: location.coordinate.latitude,
                  lon: location.coordinate.longitude,
                  horizontalAccuracy: location.horizontalAccuracy,
                  speed: location.speed,
                  speedAccuracy: location.speedAccuracy,
                  course: location.course,
                  courseAccuracy: location.courseAccuracy,
                  timestamp: location.timestamp,
                  isSimulated: location.sourceInformation?.isSimulatedBySoftware ?? false)
    }
}
