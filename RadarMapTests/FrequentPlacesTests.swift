//
//  FrequentPlacesTests.swift
//  RadarMapTests
//
//  Дом и работа выучиваются по РАСПОРЯДКУ, а не по частоте, и требуют
//  подтверждения разными днями: ошибиться с «домом» хуже, чем промолчать.
//  Подсказка не имеет права предлагать место, в котором мы уже стоим.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class FrequentPlacesTests: XCTestCase {

    /// Понедельник 12 января 2027, 12:00 UTC — от него отсчитываем дни назад.
    private let now = Date(timeIntervalSince1970: 1_799_755_200)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let home = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
    private let work = CLLocationCoordinate2D(latitude: 41.3400, longitude: 69.3300)
    private let shop = CLLocationCoordinate2D(latitude: 41.3200, longitude: 69.2900)

    /// Поездка «откуда-то в точку»: важны финиш и время прибытия.
    private func trip(to place: CLLocationCoordinate2D, daysAgo: Int, hour: Int,
                      from: CLLocationCoordinate2D? = nil,
                      startHour: Int? = nil) -> TripRecord {
        let day = utc.date(byAdding: .day, value: -daysAgo, to: now)!
        let arrival = utc.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        let departure = utc.date(bySettingHour: startHour ?? max(0, hour - 1),
                                 minute: 0, second: 0, of: day)!
        // Трек нужен только для точки отъезда — берём две точки.
        let track: [Double]? = from.map { start in
            [start.latitude, start.longitude, 40,
             place.latitude, place.longitude, 40]
        }
        return TripRecord(id: arrival.timeIntervalSince1970,
                          startedAt: departure, endedAt: arrival,
                          distanceMeters: 9000, maxSpeedKmh: 80, passed: [],
                          endLat: place.latitude, endLon: place.longitude,
                          track: track, score: 90)
    }

    /// Рабочая неделя: утром на работу, вечером домой — ровно тот распорядок,
    /// по которому места и опознаются.
    private func workWeek(days: [Int]) -> [TripRecord] {
        days.flatMap { daysAgo in
            [trip(to: work, daysAgo: daysAgo, hour: 9, from: home, startHour: 8),
             trip(to: home, daysAgo: daysAgo, hour: 19, from: work, startHour: 18)]
        }
    }

    // MARK: - Обучение

    /// Опорный день — вторник, поэтому будни берём точечно: 1 день назад —
    /// понедельник, 4 и 5 — пятница и четверг. Захватить субботу значило бы
    /// недобрать рабочих дней и получить дом без работы (ровно это и поймал
    /// первый прогон этого теста).
    private let weekdaysAgo = [1, 4, 5]

    func testLearnsHomeAndWorkFromWeekdayRoutine() {
        let places = FrequentPlaces.learn(history: workWeek(days: weekdaysAgo),
                                          now: now, calendar: utc)
        guard let learnedHome = places.first(where: { $0.kind == .home }),
              let learnedWork = places.first(where: { $0.kind == .work }) else {
            return XCTFail("распорядок будней обязан дать и дом, и работу")
        }
        XCTAssertEqual(GeoMath.fastDistance(learnedHome.lat, learnedHome.lon,
                                            home.latitude, home.longitude), 0, accuracy: 30)
        XCTAssertEqual(GeoMath.fastDistance(learnedWork.lat, learnedWork.lon,
                                            work.latitude, work.longitude), 0, accuracy: 30)
        XCTAssertEqual(learnedHome.days, 3)
    }

    /// Частота сама по себе не делает место домом: магазин у дома посещается
    /// чаще работы, но в его распорядке нет ни ночёвок, ни рабочего дня.
    func testFrequentShopDoesNotBecomeHomeOrWork() {
        var history = workWeek(days: weekdaysAgo)
        // Восемь дневных заездов в магазин — больше, чем визитов на работу.
        for daysAgo in [1, 4, 5, 6] {
            history.append(trip(to: shop, daysAgo: daysAgo, hour: 13))
            history.append(trip(to: shop, daysAgo: daysAgo, hour: 14))
        }
        let places = FrequentPlaces.learn(history: history, now: now, calendar: utc)
        for place in places {
            XCTAssertGreaterThan(
                GeoMath.fastDistance(place.lat, place.lon, shop.latitude, shop.longitude),
                AppConfig.placeClusterMeters,
                "дневной магазин не имеет права стать \(place.kind.rawValue)")
        }
    }

    /// Один насыщенный день — не привычка: пока разных дней меньше порога,
    /// места нет вовсе.
    func testSingleDayIsNotEnough() {
        let history = [
            trip(to: home, daysAgo: 2, hour: 19),
            trip(to: home, daysAgo: 2, hour: 21),
            trip(to: home, daysAgo: 2, hour: 23),
            trip(to: work, daysAgo: 2, hour: 9),
        ]
        XCTAssertTrue(FrequentPlaces.learn(history: history, now: now, calendar: utc).isEmpty)
    }

    /// Дом не может быть и работой: утренний отъезд из дома выглядит как
    /// утренний приезд на работу, и без исключения дом побеждал бы дважды.
    func testHomeIsNeverAlsoWork() {
        let history = workWeek(days: weekdaysAgo)
        let places = FrequentPlaces.learn(history: history, now: now, calendar: utc)
        guard let learnedHome = places.first(where: { $0.kind == .home }),
              let learnedWork = places.first(where: { $0.kind == .work }) else {
            return XCTFail("не выучились оба места")
        }
        XCTAssertGreaterThan(
            GeoMath.fastDistance(learnedHome.lat, learnedHome.lon,
                                 learnedWork.lat, learnedWork.lon),
            AppConfig.placeClusterMeters)
    }

    /// История старше окна не учитывается: переехал — старый дом уходит.
    func testOldHistoryIsIgnored() {
        let old = workWeek(days: [40, 41, 42])
        XCTAssertTrue(FrequentPlaces.learn(history: old, now: now, calendar: utc).isEmpty)
    }

    // MARK: - Подсказка

    private var learned: [FrequentPlaces.Place] {
        [FrequentPlaces.Place(kind: .home, lat: home.latitude, lon: home.longitude, days: 5),
         FrequentPlaces.Place(kind: .work, lat: work.latitude, lon: work.longitude, days: 5)]
    }

    private func at(_ hour: Int, daysAgo: Int = 0) -> Date {
        let day = utc.date(byAdding: .day, value: -daysAgo, to: now)!
        return utc.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    func testSuggestsWorkFromHomeOnWeekdayMorning() {
        let suggestion = FrequentPlaces.suggestion(places: learned, from: home,
                                                   now: at(8), calendar: utc)
        XCTAssertEqual(suggestion?.kind, .work)
    }

    func testSuggestsHomeFromWork() {
        let suggestion = FrequentPlaces.suggestion(places: learned, from: work,
                                                   now: at(18), calendar: utc)
        XCTAssertEqual(suggestion?.kind, .home)
    }

    /// Место, в котором мы уже стоим, — единственная гарантированно
    /// бесполезная подсказка.
    func testNeverSuggestsThePlaceWeAreAlreadyAt() {
        XCTAssertNil(FrequentPlaces.suggestion(places: learned, from: home,
                                               now: at(20), calendar: utc),
                     "вечером дома предлагать «Домой» нельзя")
        let nearHome = CLLocationCoordinate2D(latitude: home.latitude + 0.001,
                                              longitude: home.longitude)
        XCTAssertNil(FrequentPlaces.suggestion(places: learned, from: nearHome,
                                               now: at(21), calendar: utc))
    }

    /// В выходной на работу не предлагаем — распорядок другой.
    func testNoWorkSuggestionOnWeekend() {
        // 10 января 2027 — воскресенье (за два дня до понедельника-опоры).
        let sundayMorning = at(8, daysAgo: 2)
        XCTAssertEqual(utc.component(.weekday, from: sundayMorning), 1)
        XCTAssertNil(FrequentPlaces.suggestion(places: learned, from: home,
                                               now: sundayMorning, calendar: utc))
    }

    /// Вечером из произвольной точки города — домой.
    func testSuggestsHomeInTheEveningFromAnywhere() {
        let suggestion = FrequentPlaces.suggestion(places: learned, from: shop,
                                                   now: at(19), calendar: utc)
        XCTAssertEqual(suggestion?.kind, .home)
    }

    /// Без позиции подсказывать нечего — и это не повод рисовать пустую строку.
    func testNoSuggestionWithoutCoordinate() {
        XCTAssertNil(FrequentPlaces.suggestion(places: learned, from: nil,
                                               now: at(19), calendar: utc))
    }
}
