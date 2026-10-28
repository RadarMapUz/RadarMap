//
//  PollScheduleTests.swift
//  RadarMapTests
//
//  Расписание опроса сервера о чужих отметках.
//
//  Проверяем не сами числа, а ПОРЯДОК и правила: быстрее едешь — чаще
//  спрашиваешь; стоишь или греешься — реже; пульт, специально разредивший
//  опрос, не обходится поездкой.
//

import XCTest
@testable import RadarMap

final class PollScheduleTests: XCTestCase {

    private func interval(trip: Bool = true, speed: Double = 60,
                          thermal: PerformanceMode = .full,
                          remote: TimeInterval? = nil) -> TimeInterval {
        PollSchedule.interval(isTripActive: trip, speedKmh: speed,
                              thermal: thermal, remoteBaseline: remote)
    }

    func testFasterDrivingMeansMoreFrequentPolling() {
        // Отметка впереди устаревает тем быстрее, чем быстрее к ней едешь.
        XCTAssertLessThan(interval(speed: 110), interval(speed: 50))
        XCTAssertLessThan(interval(speed: 50), interval(speed: 0))
    }

    func testHighwayPollFitsInsideTheWarningDistance() {
        // Смысл сорока секунд: на 110 км/ч это 1.2 км пути при радиусе
        // оповещения 886 м. Реже — и о чужой треноге узнаёшь, поравнявшись
        // с ней.
        let metres = interval(speed: 110) * (110 / 3.6)
        XCTAssertLessThan(metres, 1400, "за один интервал не должны проезжать больше полутора км")
    }

    func testStandingStillPollsRarely() {
        XCTAssertEqual(interval(speed: 0), AppConfig.mobilePollTripIdle)
    }

    func testOutsideTripNothingChanged() {
        XCTAssertEqual(interval(trip: false, speed: 110), AppConfig.mobilePollInterval,
                       "вне поездки опрос остаётся прежним — три минуты на переднем плане")
    }

    func testHeatStretchesEveryInterval() {
        for speed in [0.0, 60, 110] {
            XCTAssertEqual(interval(speed: speed, thermal: .reduced),
                           interval(speed: speed) * AppConfig.mobilePollThermalFactor,
                           accuracy: 0.001)
        }
        XCTAssertGreaterThan(interval(speed: 110, thermal: .minimal), interval(speed: 110))
    }

    func testRemoteThrottleWinsOverTheSchedule() {
        // Пульт разредил опрос специально — это защита сервера от наплыва,
        // и поездка её не отменяет.
        XCTAssertEqual(interval(speed: 110, remote: 600), 600)
    }

    func testRemoteSpeedUpDoesNotOverrideTheTripSchedule() {
        // А вот в другую сторону расписание главнее: в поездке мы и так знаем,
        // когда спрашивать чаще.
        XCTAssertEqual(interval(speed: 110, remote: 90), AppConfig.mobilePollTripFast)
    }
}
