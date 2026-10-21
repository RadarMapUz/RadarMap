//
//  ArrivalFinish.swift
//  RadarMap
//
//  «Вы на месте!» — и поездка закрывается сама.
//
//  Поездка 21.10: доехали до цели, карточка «Вы на месте!» с кнопкой
//  «Завершить поездку», а дальше — ничего: шесть минут на стоянке, поездка
//  идёт, владелец закрыл её рукой. Прибытие само по себе поездку не трогало
//  (RouteService только снимал маршрут и говорил «Вы прибыли»), а единственный
//  автостоп — CoreMotion — ждёт три минуты устойчивого «не в машине», и любой
//  сэмпл «в машине» этот отсчёт сбрасывает. А сидя в стоящей машине с
//  работающим мотором CoreMotion так и говорит: automotive + stationary разом
//  (так описан и сам CMMotionActivity — «машина встала на светофоре»).
//  Пока водитель не вышел, автостоп не наступает; в режиме «Ручной» его нет
//  вовсе.
//
//  Здесь — когда закрывать поездку самим. После прибытия к цели маршрута:
//    * машина стоит у цели (или у точки, где сработало прибытие) не меньше
//      `arrivalAutoFinishSeconds` — припарковались;
//    * или CarPlay отключился, пока стоим у цели — заглушили машину.
//  Никогда — на ходу, вдали от цели (уехали дальше — прибытие уже не про
//  эту поездку) и если водитель поставил новую цель. И только в режимах
//  со стартом по движению: закрытую поездку там поднимет автостарт, если
//  поехали дальше (и склейка вернёт её в ту же запись), а в «Ручном» её
//  продолжение не записалось бы вовсе.
//
//  Закрытие — автоматическое, а не ручное: человек ничего не нажимал, и
//  ошибку автоматики (ждал пассажира у подъезда полторы минуты и поехал
//  дальше) должна чинить склейка. Но цель маршрута — это место, куда
//  ехали, а не «случайное место по пути»: склейка считает его как Дом и
//  Работу (TripMerge.Context.stopAtDestination) — короткая пауза ещё
//  заезд, долгая уже «приехали».
//
//  Чистая логика без Date.now; ArrivalFinishTests.
//

import Foundation

nonisolated enum ArrivalFinish {

    /// Точка на карте без CoreLocation — Equatable и Sendable.
    struct Point: Equatable, Sendable {
        let lat: Double
        let lon: Double
    }

    /// Прибытие, за которым следим: когда и где.
    struct Arrival: Equatable, Sendable {
        let at: Date
        /// Цель маршрута.
        let destination: Point?
        /// Где была машина, когда сработало прибытие: «проехали финиш по
        /// линии» срабатывает и в 250 м от точки цели (цель внутри квартала).
        let point: Point?
        /// CarPlay отключился уже после прибытия. Защёлка: отключили, пока
        /// ещё катились по парковке, — встанем, и поездка закроется сразу.
        var carPlayDisconnected = false
    }

    /// Всё, что известно о машине сейчас.
    struct Situation {
        let arrival: Arrival
        let now: Date
        let isTripActive: Bool
        /// Поездка может стартовать сама (режим «Авто» или «Умный»).
        let startsByItself: Bool
        /// Новая цель: маршрут есть или строится.
        let hasNewRoute: Bool
        /// Цифра спидометра, км/ч (на стоянке — ровно ноль, Standstill).
        let speedKmh: Double
        /// Когда машина последний раз двигалась (`movementSeenSpeedKmh`).
        let lastMovementAt: Date
        /// Где машина сейчас; nil — позиции нет.
        let here: Point?
    }

    enum Reason: String, Equatable, Sendable {
        /// Простояли у цели `arrivalAutoFinishSeconds`.
        case parked
        /// CarPlay отключился у цели.
        case carPlayDisconnected
    }

    enum Decision: Equatable, Sendable {
        /// Пока нет; проверить снова не позже чем через столько секунд —
        /// на стоянке фиксов нет (distanceFilter), и ждать их нельзя.
        case wait(recheckIn: TimeInterval)
        /// Закрыть поездку (автоматически).
        case finish(Reason)
        /// Прибытие больше не про эту поездку — перестать следить.
        case drop
    }

    static func decide(_ s: Situation) -> Decision {
        // Поездки нет (закрыли рукой, автостоп) — закрывать нечего.
        guard s.isTripActive else { return .drop }
        // В «Ручном» поездку открывает и закрывает только человек: закрытую
        // нами поездку там не поднял бы никто, и дорога дальше пропала бы.
        guard s.startsByItself else { return .drop }
        // Новая цель — едем дальше, это уже другое ведение.
        guard !s.hasNewRoute else { return .drop }
        // Без позиции «у цели» не доказано — ждём фикса или таймера.
        guard let here = s.here, let meters = metersFromArrival(here, s.arrival) else {
            return .wait(recheckIn: AppConfig.arrivalAutoFinishRecheckSeconds)
        }
        // Уехали от цели — прибытие кончилось, поездка идёт как обычная
        // (её закроет автостоп, как любую другую).
        guard meters <= AppConfig.arrivalAutoFinishRadiusMeters else { return .drop }
        // На ходу — никогда: паркуемся, объезжаем квартал, светофор тронулся.
        guard s.speedKmh < AppConfig.movementSeenSpeedKmh else {
            return .wait(recheckIn: AppConfig.arrivalAutoFinishSeconds)
        }
        if s.arrival.carPlayDisconnected { return .finish(.carPlayDisconnected) }
        // Стоим с прибытия или с последнего движения после него.
        let parked = s.now.timeIntervalSince(max(s.arrival.at, s.lastMovementAt))
        if parked >= AppConfig.arrivalAutoFinishSeconds { return .finish(.parked) }
        return .wait(recheckIn: max(1, AppConfig.arrivalAutoFinishSeconds - parked))
    }

    /// Расстояние до цели или до точки прибытия — что ближе. nil — ни той,
    /// ни другой не знаем.
    static func metersFromArrival(_ here: Point, _ arrival: Arrival) -> Double? {
        let distances = [arrival.destination, arrival.point].compactMap { point in
            point.map { GeoMath.fastDistance(here.lat, here.lon, $0.lat, $0.lon) }
        }
        return distances.min()
    }
}
