//
//  BottomHintTests.swift
//  RadarMapTests
//

import Testing

@testable import RadarMap

@Suite("Внизу экрана — одна плашка, а не четыре")
struct BottomHintTests {

    private func choose(error: String? = nil, building: Bool = false,
                        trip: Bool = false, speed: Double = 0,
                        destinations: Bool = true) -> BottomHint {
        BottomHint.choose(routeError: error, isBuilding: building,
                          tripActive: trip, speedKmh: speed,
                          speakThreshold: 20, showsQuickDestinations: destinations)
    }

    @Test("Ошибка старше всего: она ждёт решения")
    func errorWins() {
        #expect(choose(error: "Маршрут не построен", building: true,
                       speed: 60) == .routeError("Маршрут не построен"))
    }

    @Test("«Строим» старше подсказки и назначения")
    func buildingBeatsHints() {
        #expect(choose(building: true, speed: 60) == .building)
    }

    @Test("Подсказка о поездке старше предложения назначения")
    func drivingBeatsDestinations() {
        #expect(choose(speed: 60) == .driving)
    }

    @Test("Едем с включённой поездкой — подсказка не нужна")
    func tripActiveSilencesTheHint() {
        #expect(choose(trip: true, speed: 60) == .destinations)
    }

    @Test("Стоим — подсказки о поездке нет")
    func standingStillIsQuiet() {
        #expect(choose(speed: 3) == .destinations)
    }

    @Test("Пустая строка ошибки — не ошибка")
    func emptyErrorIsNotAnError() {
        // Иначе пустая строка заняла бы единственное место на экране и
        // прогнала бы всё остальное, ничего при этом не сказав.
        #expect(choose(error: "", speed: 60) == .driving)
    }

    @Test("Когда сказать нечего — не говорим ничего")
    func silenceIsAllowed() {
        #expect(choose(destinations: false) == .none)
    }
}

@Suite("Ночью ничего не ярче камеры")
struct NightDimmingTests {

    @Test("Ночью док приглушён сильнее, чем днём")
    func nightIsDimmer() {
        let day = SpeedHUDView.dimming(secondary: false, night: false, alertLevel: 0)
        let night = SpeedHUDView.dimming(secondary: false, night: true, alertLevel: 0)
        #expect(night < day)
    }

    @Test("Во время тревоги не приглушаем ничего")
    func alertKeepsFullBrightness() {
        // Тревога поднимает всё вместе: иначе водитель увидит предупреждение
        // и не увидит, с какой скоростью едет.
        #expect(SpeedHUDView.dimming(secondary: true, night: true,
                                     alertLevel: 2) == 1)
    }

    @Test("Второй план приглушён и днём")
    func secondaryStaysSecondary() {
        let main = SpeedHUDView.dimming(secondary: false, night: false, alertLevel: 0)
        let side = SpeedHUDView.dimming(secondary: true, night: false, alertLevel: 0)
        #expect(side < main)
    }
}
