//
//  AlertEngine.swift
//  RadarMap
//
//  Движок порогов приближения к камере: чем ближе — тем выше уровень (1–3).
//  Чистая машина состояний без CLLocation, звука и UI — каждое решение
//  «сигналить или нет» покрыто тестами. Кто и чем сигналит, решает вызывающий.
//

import CoreLocation

nonisolated struct AlertEngine {
    /// «Пора сигналить»: уровень эскалации вырос.
    struct Decision: Equatable {
        /// 1 — вошли в радиус, 2–3 — эскалация сигналов по мере приближения.
        let level: Int
        /// Первое оповещение об этой камере. Уровень может начаться и со второго,
        /// и с третьего: камеру бывает видно поздно — повернули на улицу прямо
        /// перед ней, вернулся сигнал после туннеля, соседняя камера была ближе.
        /// Голос и баннер привязаны к этому флагу, а не к `level == 1`, иначе о
        /// поздно замеченной камере приложение молчит совсем.
        let isFirst: Bool
    }

    /// Достигнутый уровень по каждой камере — повторно на том же уровне не сигналим.
    private var announcedLevel: [Int: Int] = [:]
    /// Проеханные камеры (сценарий S4, 20.10). Новый подъезд к такой камере —
    /// разворот через 300 м, круг по кварталу — это новое приближение, и о нём
    /// предупреждаем с начала. До этого уровень жил всю поездку: сброс был
    /// только у ближайшей камеры за радиусом, а проеханная ближайшей уже не
    /// бывала — и после разворота на разделённом проспекте камера, снимающая
    /// обе стороны, молчала.
    ///
    /// «Проехали» — строго: о камере сказали, мы были у неё на траверзе, и
    /// она явно позади два фикса подряд. «Новый подъезд» — явно впереди два
    /// фикса подряд. Оба решения — в `noteGeometry` на КАЖДОМ годном фиксе:
    /// одиночный фикс с кривым курсом (отражение от стены на ползущей машине)
    /// иначе давал второе «первое» оповещение о той же камере (ревью 20.10).
    private var traversed: Set<Int> = []
    private var passed: Set<Int> = []
    private var behindStreak: [Int: Int] = [:]
    private var aheadStreak: [Int: Int] = [:]

    /// Сколько секунд запаса даём: городские 22 внизу, трассовые 29 наверху,
    /// линейный переход между ними (см. AppConfig).
    ///
    /// `isHighway` — вердикт детектора город/трасса. Без него запас зависел
    /// только от скорости, и стоило встать за фурой на 70 км/ч, как трасса
    /// молча превращалась в город: 428 метров вместо 564. Между тем впереди
    /// по-прежнему трасса, камер мало, и разогнаться после обгона можно за
    /// несколько секунд. Бдительность не должна зависеть от того, попали ли
    /// вы в пробку.
    static func leadTime(speedKmh: Double, isHighway: Bool = false) -> Double {
        if isHighway { return AppConfig.alertLeadTimeHighwaySeconds }
        let from = AppConfig.alertLeadRampFromKmh
        let to = AppConfig.alertLeadRampToKmh
        let city = AppConfig.alertLeadTimeSeconds
        let highway = AppConfig.alertLeadTimeHighwaySeconds
        if speedKmh <= from { return city }
        if speedKmh >= to { return highway }
        return city + (highway - city) * (speedKmh - from) / (to - from)
    }

    /// Умный радиус: предупреждаем за `leadTime` до камеры.
    /// Растёт со скоростью (на трассе — раньше), но не ниже базового из настроек.
    static func effectiveRadius(speedKmh: Double, baseRadius: CLLocationDistance,
                                context: AlertPolicy.Context = .city) -> CLLocationDistance {
        let bySpeed = (speedKmh / 3.6) * leadTime(speedKmh: speedKmh,
                                                  isHighway: context == .highway)
        return min(AppConfig.maxDynamicRadius, max(baseRadius, bySpeed))
    }

    /// Сколько секунд дороги мы НА САМОМ ДЕЛЕ даём водителю на этой скорости.
    ///
    /// `leadTime` — это намерение, а не факт: между ними стоит потолок радиуса,
    /// и упёршись в него, запас начинает таять ровно там, где он нужнее всего —
    /// на большой скорости. Пока это число считалось в уме, недобор было видно
    /// только тому, кто взял калькулятор. Теперь оно есть, и его сторожит тест.
    static func leadSeconds(speedKmh: Double, baseRadius: CLLocationDistance,
                            context: AlertPolicy.Context = .city) -> Double {
        guard speedKmh > 0 else { return .infinity }
        return effectiveRadius(speedKmh: speedKmh, baseRadius: baseRadius,
                               context: context) / (speedKmh / 3.6)
    }

    /// Оценить приближение: вернёт решение, если уровень вырос; nil — молчим.
    /// Выход за радиус с гистерезисом сбрасывает серию — при возврате сигналим заново.
    mutating func evaluate(cameraID: Int, distance: CLLocationDistance,
                           radius: CLLocationDistance) -> Decision? {
        if distance > radius + AppConfig.alertExitHysteresisMeters {
            forget(cameraID)
            return nil
        }
        let level = Self.level(distance: distance, radius: radius)
        let previous = announcedLevel[cameraID] ?? 0
        guard level > previous else { return nil }
        announcedLevel[cameraID] = level
        return Decision(level: level, isFirst: previous == 0)
    }

    mutating func reset() {
        announcedLevel.removeAll()
        traversed.removeAll()
        passed.removeAll()
        behindStreak.removeAll()
        aheadStreak.removeAll()
    }

    /// Серия по камере закончена — следующий подъезд начнётся с нуля.
    private mutating func forget(_ cameraID: Int) {
        announcedLevel[cameraID] = 0
        traversed.remove(cameraID)
        passed.remove(cameraID)
        behindStreak[cameraID] = nil
        aheadStreak[cameraID] = nil
    }

    /// О камере уже сказали (уровень > 0).
    func isAnnounced(_ cameraID: Int) -> Bool { (announcedLevel[cameraID] ?? 0) > 0 }

    /// Геометрия камеры, о которой сказали, на годном фиксе — звать на КАЖДОМ
    /// (сказано о единицах камер):
    /// - `atTraverse` — у камеры (PassGeometry.traverseLimit). Без траверза
    ///   «позади» не значит «проехали»: свернули до неё, шпилька, кривой курс;
    /// - `behind` / `ahead` — LocationGates.isClearlyBehind / isClearlyAhead.
    /// Проехали (траверз и позади два фикса подряд) → потом впереди два фикса
    /// подряд — серия забыта, и следующее приближение предупреждается заново.
    /// Камера маршрута, ещё «0 м» за спиной по остатку, впереди не бывает —
    /// второго «0 метров» нет.
    mutating func noteGeometry(_ cameraID: Int, atTraverse: Bool, behind: Bool, ahead: Bool) {
        guard isAnnounced(cameraID) else { return }
        if atTraverse { traversed.insert(cameraID) }
        let confirm = AppConfig.alertPassedConfirmFixes
        if passed.contains(cameraID) {
            let streak = ahead ? (aheadStreak[cameraID] ?? 0) + 1 : 0
            aheadStreak[cameraID] = streak
            if streak >= confirm { forget(cameraID) }
        } else if traversed.contains(cameraID) {
            let streak = behind ? (behindStreak[cameraID] ?? 0) + 1 : 0
            behindStreak[cameraID] = streak
            if streak >= confirm {
                passed.insert(cameraID)
                behindStreak[cameraID] = nil
            }
        }
    }

    /// Ступень тревоги по дистанции: 1 — в радиусе, 2 — ближе
    /// `alertLevel2Share` радиуса, 3 — ближе `alertLevel3Share`. Одна лестница
    /// на движок, экран и часы — до 19.10 у LocationService была своя копия
    /// тех же 0,6/0,3 (аудит архитектуры).
    static func level(distance: CLLocationDistance, radius: CLLocationDistance) -> Int {
        if distance <= radius * AppConfig.alertLevel3Share { return 3 }
        if distance <= radius * AppConfig.alertLevel2Share { return 2 }
        return distance <= radius ? 1 : 0
    }
}
