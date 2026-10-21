//
//  NearestDisplayHold.swift
//  RadarMap
//
//  Ближайшая камера ДЛЯ ПОКАЗА не мигает на пороге гейтов (план 25.I).
//
//  Ниже `directionalMinSpeedKmh` (10 км/ч) гейты «наша ли камера» выключены
//  (`LocationGates.isFilteringActive`): стоящая машина не «едет мимо» камеры,
//  и глушить по случайному курсу нельзя. Для ПРЕДУПРЕЖДЕНИЯ это верно —
//  неизвестность в пользу камеры, — но ближайшей тогда становится любая камера
//  вокруг: боковая улица в 140 м, проеханная позади. Выше порога — снова наша
//  впереди. В пробке скорость пересекает 10 км/ч постоянно, и HUD телефона,
//  док CarPlay, часы и Live Activity мигали между двумя камерами
//  (docs/drive_camera_2026-10-21.md, причина 2).
//
//  Решение — удержание, а не второй порог скорости. Гистерезис 10/6 км/ч
//  мигал бы в той же пробке на 5 км/ч; удержание держит последнюю «нашу
//  впереди» камеру, пока скорость ниже порога НЕДОЛГО (`nearestDisplayHoldSeconds`
//  с последнего тика с работающими гейтами), камера ближе
//  `nearestDisplayHoldMaxMeters` и по-прежнему проходит те же гейты — с
//  текущим курсом, если ему верят, иначе с последним доверенным. Свернули на
//  боковую улицу — курс другой, гейт говорит «не наша», показ переключается
//  сразу. Стоим долго — прежнее поведение: ближайшая любая («136 м сбоку»,
//  12.10). Отпущенное удержание не возвращается до следующего тика с
//  гейтами, иначе показ мигал бы теперь на границе удержания.
//
//  ТОЛЬКО ПОКАЗ. Камера предупреждения (`LocationService.nearestCamera`,
//  `distanceToNearest`) выбирается как раньше, и движок тревоги, уровни,
//  голос и баннеры её и читают; этот модуль получает её индекс по значению и
//  вернуть может только индекс для показа (тест-сверка в
//  `NearestDisplayHoldTests`). Удержание срабатывает лишь ниже порога
//  скорости, где `isApproachingCamera` и так ложь, — полноэкранное
//  предупреждение и баннер машины с показом не расходятся.
//

import CoreLocation

nonisolated struct NearestDisplayHold: Equatable, Sendable {

    /// Последняя камера, которую гейты признали нашей на ходу.
    struct Anchor: Equatable, Sendable {
        let cameraID: Int
        /// Доверенный курс того тика: стоя курса часто нет, а «впереди ли она
        /// ещё» без курса не решить.
        let course: CLLocationDirection
        /// Время ПОСЛЕДНЕГО тика с работающими гейтами — от него и считаются
        /// секунды удержания; на тиках удержания не обновляется.
        let at: Date
    }

    private(set) var anchor: Anchor?

    /// Индекс камеры для показа, если он не тот, что у предупреждения; nil —
    /// показывать камеру предупреждения (`alertIndex`).
    ///
    /// - Parameters:
    ///   - candidates: те же кандидаты, по возрастанию расстояния, что
    ///     выбирают камеру предупреждения.
    ///   - alertIndex: её индекс (`LocationGates.nearestOursIndex`) — только
    ///     вход: изменить выбор предупреждения отсюда нельзя.
    mutating func update(candidates: [LocationGates.Candidate], alertIndex: Int?,
                         situation: LocationGates.Situation, now: Date) -> Int? {
        if LocationGates.isFilteringActive(situation) {
            // Гейты работают: показ и есть предупреждение. Запоминаем, о какой
            // камере тик с гейтами сказал «наша» (или что такой нет).
            anchor = alertIndex.map {
                Anchor(cameraID: candidates[$0].camera.id, course: situation.course, at: now)
            }
            return nil
        }
        guard let held = anchor else { return nil }
        // Мостим только порог СКОРОСТИ. Быстро, но курса нет — другая беда
        // (туннель, каньон), там прежнее поведение.
        guard situation.speedKmh < AppConfig.directionalMinSpeedKmh,
              let index = Self.stillHeld(held, candidates: candidates,
                                         situation: situation, now: now) else {
            anchor = nil
            return nil
        }
        return index == alertIndex ? nil : index
    }

    /// Держится ли камера якоря: недолго, близко, и те же гейты с курсом
    /// (текущим доверенным или последним) говорят «наша».
    static func stillHeld(_ held: Anchor, candidates: [LocationGates.Candidate],
                          situation: LocationGates.Situation, now: Date) -> Int? {
        let elapsed = now.timeIntervalSince(held.at)
        guard elapsed >= 0, elapsed <= AppConfig.nearestDisplayHoldSeconds,
              let index = candidates.firstIndex(where: { $0.camera.id == held.cameraID }),
              candidates[index].distance <= AppConfig.nearestDisplayHoldMaxMeters else { return nil }
        // Пробная обстановка: та же точка и погрешность, курс — которому
        // верим, скорость — порог, чтобы гейты не воздержались. Свернули на
        // боковую (курс доверенный и другой) — камера вне коридора, держать
        // нечего; проехали её — «позади».
        let probe = LocationGates.Situation(
            coordinate: situation.coordinate,
            course: situation.course >= 0 ? situation.course : held.course,
            speedKmh: AppConfig.directionalMinSpeedKmh,
            horizontalAccuracy: situation.horizontalAccuracy,
            context: situation.context)
        let candidate = candidates[index]
        guard LocationGates.isOnOurRoad(candidate.camera, in: probe,
                                        isOnRoute: candidate.onRoute) else { return nil }
        return index
    }
}
