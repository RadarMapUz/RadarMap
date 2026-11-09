//
//  CarPlayPanelTextTests.swift
//  RadarMapTests
//
//  Строки узких панелей CarPlay: заголовок и подпись варианта не повторяют
//  друг друга, ни один первый вариант не длиннее реальной ширины, тип камеры
//  и адрес не рвутся посередине слова — на длинных русских и узбекских
//  значениях и на худших адресах реестра.
//

import XCTest
@testable import RadarMap

final class CarPlayPanelTextTests: XCTestCase {

    private let titleLimit = AppConfig.carPlayRouteTitleMaxChars
    private let detailLimit = AppConfig.carPlayRouteDetailMaxChars

    func testVariantsGoFromLongToShortAndKeepTheShortest() {
        XCTAssertEqual(CarPlayPanelText.variants(["длинная строка", "короткая", "эта"], limit: 10), ["короткая", "эта"])
        XCTAssertEqual(CarPlayPanelText.variants(["длинная строка", "ещё длинная"], limit: 3), ["ещё длинная"])
        XCTAssertEqual(CarPlayPanelText.variants(["а", "б"], limit: 10), ["а", "б"])
        XCTAssertEqual(CarPlayPanelText.variants(["одно", "одно"], limit: 10), ["одно"])
        XCTAssertEqual(CarPlayPanelText.variants([], limit: 10), [])
    }

    func testRouteTitleIsLabelAndTimeAndFactsBelowDoNotRepeatThem() {
        let lines = CarPlayPanelText.route(label: "Быстрый", eta: "29 мин", distance: "15,3 км", cameras: "камер: 17")
        XCTAssertEqual(lines.summary, ["Быстрый · 29 мин", "Быстрый", "29 мин"])
        XCTAssertEqual(lines.selection, ["15,3 км · камер: 17", "15,3 км"])
        XCTAssertEqual(lines.additional, lines.selection)
        for line in lines.selection {
            XCTAssertFalse(line.contains("Быстрый"), line)
            XCTAssertFalse(line.contains("29 мин"), line)
        }
    }

    func testRouteWithoutLabelIsJustTheTime() {
        let lines = CarPlayPanelText.route(label: nil, eta: "9 мин", distance: "4 км", cameras: "камер: 0")
        XCTAssertEqual(lines.summary, ["9 мин"])
    }

    func testLongRussianAndUzbekRouteLinesFitTheRealWidth() {
        let labels = ["Быстрый", "Спокойнее", "Меньше камер", "Без камер", "Перекрытие", "Моя дорога",
                      "Tez", "Xotirjamroq", "Kamera kamroq", "Kamerasiz", "Mening yoʻlim", "Yoʻl yopiq"]
        let times = ["29 мин", "1 ч", "12 ч 59 мин", "29 daq", "1 soat", "12 soat 59 daq"]
        let facts = [("15,3 км", "камер: 17"), ("1 234 км", "камер: 123"),
                     ("15,3 km", "kameralar: 17"), ("1 234 km", "kameralar: 123")]
        for label in labels {
            for time in times {
                for (distance, cameras) in facts {
                    let lines = CarPlayPanelText.route(label: label, eta: time, distance: distance, cameras: cameras)
                    XCTAssertEqual(lines.summary.last, time)
                    XCTAssertTrue(lines.summary[0].contains(label) || lines.summary[0] == time, lines.summary[0])
                    XCTAssertLessThanOrEqual(lines.summary[0].count, titleLimit, lines.summary[0])
                    XCTAssertLessThanOrEqual(lines.selection[0].count, detailLimit, lines.selection[0])
                    XCTAssertEqual(lines.selection.last, distance)
                    for line in [lines.summary, lines.selection] {
                        XCTAssertEqual(line, line.sorted { $0.count > $1.count }, "от длинного к короткому")
                    }
                }
            }
        }
    }

    func testCameraTypesAreShortAndNoWordOutgrowsTheRow() {
        XCTAssertEqual(CarPlayPanelText.kindName(.intelligentRadar), "Камера и радар")
        XCTAssertEqual(CarPlayPanelText.kindName(.stationaryCamera), "Камера")
        XCTAssertEqual(CarPlayPanelText.kindName(.stationaryRadar), "Радар")
        XCTAssertEqual(CarPlayPanelText.kindName(.mobileRadar), "Мобильный радар")
        XCTAssertEqual(CarPlayPanelText.kindName(.other("Новый тип")), "Новый тип")
        XCTAssertEqual(CarPlayPanelText.kindName(.other("Сверхинтеллектуальный комплекс")), "Камера",
                       "неизвестный длинный тип реестра не рвётся")
        XCTAssertEqual(CarPlayPanelText.kindName(.other("")), "Камера")
        let names = [CameraType.stationaryCamera, .stationaryRadar, .intelligentRadar, .mobileRadar,
                     .tripod, .dpsPost, .accident].map { CarPlayPanelText.kindName($0) }
        let uzbek = ["Kamera", "Radar", "Kamera va radar", "Koʻchma radar", "Uch oyoq", "YPX posti", "YTH"]
        for name in names + uzbek {
            for word in name.split(separator: " ") {
                XCTAssertLessThanOrEqual(word.count, AppConfig.carPlayPanelKindWordMaxChars, name)
            }
        }
    }

    func testCameraRowFromTheOwnersScreenshot() {
        let row = CarPlayPanelText.cameraRow(distance: "858\u{00A0}м", kind: CarPlayPanelText.kindName(.intelligentRadar),
                                             location: "Ziyolilar va Qalandar Ko'chalari chorrahasi")
        XCTAssertEqual(row, CarPlayPanelText.CameraRow(title: "858\u{00A0}м · Камера и радар",
                                                       detail: "Ziyolilar va Qalandar Ko'chalari"))
    }

    func testAddressKeepsWholeWordsOfTheRegistry() {
        let cases: [(String, String)] = [
            ("Labzak koʻchasi Avtobus bekati, Toshkenboyev koʻchasi Kirish Oldiga", "Labzak koʻchasi Avtobus bekati"),
            ("Юнусабад", "Юнусабад"),
            ("", ""),
            ("\"Toshkent-oʼsh-toshkent-ohangaron-аngren-qoʼqon-shahrixon-аndijon\" avtomobil yoʻli", "Toshkent"),
            ("(Toshkеnt–ohangaron–angrеn–qo‘qon–shahrixon–andijon) yoʻli", "Toshkеnt"),
            ("Qizilqum va (Toshkеnt–ohangaron–angrеn–qo‘qon–shahrixon) yoʻli", "Qizilqum"),
            ("Eshimoqsoq Qishlog‘iga (11 Km.dan) yoʻl boʻylab bir necha", "Eshimoqsoq Qishlog‘iga"),
            ("D146 \"A373 avtomobil (348 Km.dan) yoʻli oralig'i kesishgan", "D146 A373 avtomobil"),
            ("Qishloq (11 Km.dan) yoʻl", "Qishloq (11 Km.dan) yoʻl"),
        ]
        for (location, expected) in cases {
            let text = CarPlayPanelText.address(location)
            XCTAssertEqual(text, expected)
            XCTAssertLessThanOrEqual(text.count, AppConfig.carPlayPanelAddressMaxChars, text)
            for word in text.split(separator: " ") {
                XCTAssertLessThanOrEqual(word.count, AppConfig.carPlayPanelAddressWordMaxChars, text)
            }
        }
    }

    func testAddressNeverEndsOnAConnector() {
        XCTAssertEqual(CarPlayPanelText.address("Ziyolilar va Qalandar Ko'chalari va chorrahasi Ko'chasi", limit: 35),
                       "Ziyolilar va Qalandar Ko'chalari")
    }

    func testUnitsAreTheAppLanguageAndConvertLikeTheStandardOnes() {
        XCTAssertEqual(CarPlayUnits.meters(language: "ru").symbol, "м")
        XCTAssertEqual(CarPlayUnits.kilometers(language: "ru").symbol, "км")
        XCTAssertEqual(CarPlayUnits.meters(language: "uz").symbol, "m")
        XCTAssertEqual(CarPlayUnits.kilometers(language: "uz").symbol, "km")
        let km = Measurement(value: 11.8, unit: CarPlayUnits.kilometers(language: "ru"))
        XCTAssertEqual(km.converted(to: .meters).value, 11_800, accuracy: 0.001)
        XCTAssertEqual(Measurement(value: 40, unit: CarPlayUnits.meters(language: "ru")).converted(to: .meters).value,
                       40, accuracy: 0.001)
    }

    /// На телефоне с английским языком система печатала «40 m» (снимок 16:39).
    func testEnglishPhoneStillPrintsTheAppUnit() {
        let medium = MeasurementFormatter()
        medium.unitStyle = .medium
        medium.unitOptions = .providedUnit
        medium.locale = Locale(identifier: "en_US")
        XCTAssertEqual(medium.string(from: Measurement(value: 40, unit: CarPlayUnits.meters(language: "ru"))), "40 м")
        let short = MeasurementFormatter()
        short.unitStyle = .short
        short.unitOptions = .providedUnit
        short.locale = Locale(identifier: "en_US")
        XCTAssertEqual(short.string(from: CarPlayUnits.kilometers(language: "ru")), "км")
    }

    /// CPTravelEstimates уходит в процесс CarPlay через NSSecureCoding.
    func testUnitSurvivesTheTripToTheCarProcess() throws {
        let measurement = NSMeasurement(doubleValue: 11.8, unit: CarPlayUnits.kilometers(language: "ru"))
        let data = try NSKeyedArchiver.archivedData(withRootObject: measurement, requiringSecureCoding: true)
        let back = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSMeasurement.self, UnitLength.self],
                                                                    from: data) as? NSMeasurement)
        XCTAssertEqual(back.unit.symbol, "км")
        XCTAssertEqual(back.doubleValue, 11.8, accuracy: 0.001)
    }
}
