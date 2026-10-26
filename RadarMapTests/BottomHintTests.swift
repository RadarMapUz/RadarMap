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
                          isProbablyDriving: !trip && speed >= 20,
                          showsQuickDestinations: destinations)
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

@Suite("Флаг «похоже, вы едете» не щёлкает у порога")
struct ProbablyDrivingTests {

    private let threshold = AppConfig.speakSpeedThresholdKmh

    @Test("На пороге включается")
    func turnsOnAtThreshold() {
        #expect(LocationService.probablyDriving(was: false, speedKmh: threshold,
                                                tripActive: false))
    }

    @Test("Ниже порога не включается")
    func staysOffBelow() {
        #expect(!LocationService.probablyDriving(was: false, speedKmh: threshold - 0.1,
                                                 tripActive: false))
    }

    /// Ради этого запаса всё и заведено: у самого порога сглаженная скорость
    /// колеблется, а каждое переключение флага — это пересборка панелей.
    @Test("Гаснет не на пороге, а с запасом")
    func releaseNeedsHysteresis() {
        #expect(LocationService.probablyDriving(was: true, speedKmh: threshold - 1,
                                                tripActive: false))
        #expect(!LocationService.probablyDriving(
            was: true,
            speedKmh: threshold - AppConfig.drivingHintHysteresisKmh - 0.1,
            tripActive: false))
    }

    @Test("В поездке подсказка не нужна вовсе")
    func tripSilencesIt() {
        #expect(!LocationService.probablyDriving(was: true, speedKmh: 90, tripActive: true))
    }

    /// Стоя без поездки «0 км/ч» не показывается — только ближайшая камера (5.7).
    @Test("Стоя без поездки скорости в HUD нет")
    func idleHudHasNoSpeed() {
        #expect(!SpeedHUDView.showsSpeed(isTripActive: false, isProbablyDriving: false))
        // В поездке скорость всегда, и в пробке на месте.
        #expect(SpeedHUDView.showsSpeed(isTripActive: true, isProbablyDriving: false))
        #expect(SpeedHUDView.showsSpeed(isTripActive: false, isProbablyDriving: true))
    }
}
