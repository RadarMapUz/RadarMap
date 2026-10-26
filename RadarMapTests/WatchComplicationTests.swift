//
//  WatchComplicationTests.swift
//  RadarMapTests
//
//  Компликация часов «следующая камера» (9.3б). Главное здесь — чего быть
//  НЕ должно: перезагрузки WidgetKit на каждом контексте (бюджет кончился бы
//  к концу поездки), точной дистанции, которая через две минуты врёт, и
//  старого снимка поездки, выданного за свежий. Плюс цвета: диск камеры —
//  цвет её типа на карте, красный — только у камеры. С 14.5 — id камеры
//  (и откат на адрес+значок без него) и толчок с телефона: старый толчок не
//  берётся, а контекст и толчок одного снимка — одна перезагрузка.
//

import SwiftUI
import XCTest
@testable import RadarMap

final class WatchComplicationTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    /// Полдень по UTC — до конца суток далеко, счёт суток не мешает тестам интервала.
    private let noon = Date(timeIntervalSince1970: 1_799_971_200 + 43_200)   // 2027-01-15 12:00 UTC

    private func trip(_ distance: Int?, title: String? = "Юнусабад",
                      symbol: String = "camera.fill", id: Int? = nil) -> WatchComplicationState {
        WatchComplication.state(isTripActive: true, symbol: symbol, title: title, distanceMeters: distance,
                                cameraID: id)
    }

    // MARK: - Состояние

    func testDistanceIsAnUpperBound() {
        XCTAssertEqual(WatchComplication.bound(forMeters: 0), 300)
        XCTAssertEqual(WatchComplication.bound(forMeters: 300), 300)
        XCTAssertEqual(WatchComplication.bound(forMeters: 301), 500)
        XCTAssertEqual(WatchComplication.bound(forMeters: 999), 1000)
        XCTAssertEqual(WatchComplication.bound(forMeters: 4_900), 5000)
        XCTAssertNil(WatchComplication.bound(forMeters: 5_001), "дальше крупной ступени — «> 5 км»")
        // Граница не меньше дистанции: к камере впереди путь только короче.
        for meters in stride(from: 0, through: 5000, by: 37) {
            XCTAssertGreaterThanOrEqual(WatchComplication.bound(forMeters: meters)!, meters)
        }
    }

    func testStateFromContext() {
        XCTAssertEqual(WatchComplication.state(isTripActive: false, symbol: "camera.fill",
                                               title: "Юнусабад", distanceMeters: 400), .noTrip,
                       "вне поездки камера не рисуется")
        XCTAssertNil(trip(nil).camera, "в поездке без дистанции — «камер рядом нет»")
        XCTAssertTrue(trip(nil).isTripActive)
        XCTAssertEqual(trip(420).camera?.within, 500)
        // Бегущая дистанция внутри ступени — то же состояние.
        XCTAssertEqual(trip(950), trip(620))
        XCTAssertNotEqual(trip(950), trip(1050))
    }

    func testDistanceText() {
        // Ключи каталога в тестовом процессе — русские значения.
        XCTAssertEqual(WatchComplication.distanceText(within: 300), "< 300 м")
        XCTAssertEqual(WatchComplication.distanceText(within: 2000), "< 2 км")
        XCTAssertEqual(WatchComplication.distanceText(within: nil), "> 5 км")
    }

    // MARK: - Перезагрузки

    func testFirstSnapshotAndTripEdgesAlwaysReload() {
        let empty = WatchComplicationLedger()
        XCTAssertEqual(WatchComplication.reloadReason(for: .noTrip, ledger: empty, now: noon,
                                                      calendar: calendar), .tripChanged)
        let ledger = WatchComplication.recording(.tripChanged, state: .noTrip, ledger: empty,
                                                 now: noon, calendar: calendar)
        // Поездка началась через 5 секунд — сразу, мимо интервала.
        let start = noon.addingTimeInterval(5)
        XCTAssertEqual(WatchComplication.reloadReason(for: trip(800), ledger: ledger, now: start,
                                                      calendar: calendar), .tripChanged)
        // И кончилась — тоже сразу, даже если дневной лимит выбран.
        var spent = WatchComplication.recording(.tripChanged, state: trip(800), ledger: ledger,
                                                now: start, calendar: calendar)
        spent.routineReloads = WatchComplication.maxRoutineReloadsPerDay
        XCTAssertEqual(WatchComplication.reloadReason(for: .noTrip, ledger: spent,
                                                      now: start.addingTimeInterval(1), calendar: calendar),
                       .tripChanged)
    }

    func testSameStateDoesNotReload() {
        let ledger = WatchComplication.recording(.tripChanged, state: trip(800), ledger: .init(),
                                                 now: noon, calendar: calendar)
        // Контекст приходит раз в 10 с с бегущей дистанцией — циферблат тот же.
        for second in stride(from: 10, to: 400, by: 10) {
            XCTAssertNil(WatchComplication.reloadReason(for: trip(700), ledger: ledger,
                                                        now: noon.addingTimeInterval(TimeInterval(second)),
                                                        calendar: calendar), "секунда \(second)")
        }
    }

    func testCameraChangeIsThrottled() {
        let ledger = WatchComplication.recording(.tripChanged, state: trip(800), ledger: .init(),
                                                 now: noon, calendar: calendar)
        let other = trip(800, title: "Чиланзар")
        XCTAssertNil(WatchComplication.reloadReason(for: other, ledger: ledger,
                                                    now: noon.addingTimeInterval(60), calendar: calendar),
                     "другая камера через минуту — ждёт интервала")
        XCTAssertEqual(WatchComplication.reloadReason(for: other, ledger: ledger,
                                                      now: noon.addingTimeInterval(WatchComplication.minReloadInterval),
                                                      calendar: calendar), .contentChanged)
        XCTAssertEqual(WatchComplication.reloadReason(for: trip(250), ledger: ledger,
                                                      now: noon.addingTimeInterval(200), calendar: calendar),
                       .contentChanged, "ступень ближе — тоже смена")
    }

    func testDailyCapHoldsRoutineReloads() {
        var ledger = WatchComplication.recording(.tripChanged, state: trip(800), ledger: .init(),
                                                 now: noon, calendar: calendar)
        var now = noon
        var reloads = 0
        // Час города: камера меняется каждые 30 с — без учёта это 120 перезагрузок.
        for step in 1...120 {
            now = noon.addingTimeInterval(TimeInterval(step * 30))
            let state = trip(800, title: "Камера \(step)")
            if let reason = WatchComplication.reloadReason(for: state, ledger: ledger, now: now,
                                                           calendar: calendar) {
                ledger = WatchComplication.recording(reason, state: state, ledger: ledger, now: now,
                                                     calendar: calendar)
                reloads += 1
            }
        }
        XCTAssertLessThanOrEqual(reloads, Int(3600 / WatchComplication.minReloadInterval),
                                 "не чаще раза в интервал")
        XCTAssertGreaterThan(reloads, 0)

        // Лимит суток: выбран — плановые молчат, а со следующих суток снова можно.
        ledger.routineReloads = WatchComplication.maxRoutineReloadsPerDay
        let later = now.addingTimeInterval(600)
        XCTAssertNil(WatchComplication.reloadReason(for: trip(250, title: "Сергели"), ledger: ledger,
                                                    now: later, calendar: calendar))
        let tomorrow = calendar.startOfDay(for: later).addingTimeInterval(86_400 + 60)
        XCTAssertEqual(WatchComplication.reloadReason(for: trip(250, title: "Сергели"), ledger: ledger,
                                                      now: tomorrow, calendar: calendar), .contentChanged)
        let fresh = WatchComplication.recording(.contentChanged, state: trip(250), ledger: ledger,
                                                now: tomorrow, calendar: calendar)
        XCTAssertEqual(fresh.routineReloads, 1, "счёт суток начинается заново")
    }

    func testUnchangedTripIsRefreshedBeforeItFades() {
        let ledger = WatchComplication.recording(.tripChanged, state: trip(nil), ledger: .init(),
                                                 now: noon, calendar: calendar)
        XCTAssertNil(WatchComplication.reloadReason(for: trip(nil), ledger: ledger,
                                                    now: noon.addingTimeInterval(WatchComplication.refreshAfter - 1),
                                                    calendar: calendar))
        XCTAssertEqual(WatchComplication.reloadReason(for: trip(nil), ledger: ledger,
                                                      now: noon.addingTimeInterval(WatchComplication.refreshAfter),
                                                      calendar: calendar), .refresh)
        XCTAssertLessThan(WatchComplication.refreshAfter, WatchComplication.staleAfter,
                          "освежаем раньше, чем снимок потускнеет")
        // Вне поездки «нет поездки» не освежается — оно не стареет.
        let idle = WatchComplication.recording(.tripChanged, state: .noTrip, ledger: .init(),
                                               now: noon, calendar: calendar)
        XCTAssertNil(WatchComplication.reloadReason(for: .noTrip, ledger: idle,
                                                    now: noon.addingTimeInterval(86_000), calendar: calendar))
    }

    // MARK: - id камеры (14.5)

    func testAnotherCameraAtTheSameAddressIsToldByID() {
        let ledger = WatchComplication.recording(.tripChanged, state: trip(800, id: 3496), ledger: .init(),
                                                 now: noon, calendar: calendar)
        let later = noon.addingTimeInterval(WatchComplication.minReloadInterval)
        // Адрес, значок и ступень те же — без id это была бы «та же камера».
        XCTAssertEqual(WatchComplication.reloadReason(for: trip(800, id: 3497), ledger: ledger, now: later,
                                                      calendar: calendar), .contentChanged)
        // Та же камера ближе внутри ступени — по-прежнему не повод.
        XCTAssertNil(WatchComplication.reloadReason(for: trip(650, id: 3496), ledger: ledger, now: later,
                                                    calendar: calendar))
        // Интервал держит и смену по id.
        XCTAssertNil(WatchComplication.reloadReason(for: trip(800, id: 3497), ledger: ledger,
                                                    now: noon.addingTimeInterval(60), calendar: calendar))
    }

    func testWithoutIDTheCameraIsToldByAddressAndIcon() {
        // Телефон старой сборки id не шлёт — поведение до 14.5.
        let ledger = WatchComplication.recording(.tripChanged, state: trip(800), ledger: .init(),
                                                 now: noon, calendar: calendar)
        let later = noon.addingTimeInterval(WatchComplication.minReloadInterval)
        XCTAssertNil(WatchComplication.reloadReason(for: trip(800), ledger: ledger, now: later,
                                                    calendar: calendar))
        XCTAssertEqual(WatchComplication.reloadReason(for: trip(800, title: "Чиланзар"), ledger: ledger,
                                                      now: later, calendar: calendar), .contentChanged)
        XCTAssertEqual(WatchComplication.reloadReason(for: trip(800, symbol: "speedometer"), ledger: ledger,
                                                      now: later, calendar: calendar), .contentChanged)
        let old = WatchComplicationState.Camera(symbol: "camera.fill", title: "Юнусабад", within: 1000)
        var twin = old
        twin.id = 3497
        XCTAssertFalse(WatchComplication.isAnotherCamera(old, twin), "id только у одной — откат на адрес")
    }

    func testIDAppearingMidTripIsNotAReload() {
        // Телефон обновился посреди поездки: та же камера, теперь с id.
        let ledger = WatchComplication.recording(.tripChanged, state: trip(800), ledger: .init(),
                                                 now: noon, calendar: calendar)
        XCTAssertNil(WatchComplication.reloadReason(for: trip(800, id: 3496), ledger: ledger,
                                                    now: noon.addingTimeInterval(300), calendar: calendar))
        // А нарисованное у той же камеры поменялось (язык, тип отметки) — повод.
        let same = WatchComplication.recording(.tripChanged, state: trip(800, id: 7), ledger: .init(),
                                               now: noon, calendar: calendar)
        XCTAssertEqual(WatchComplication.reloadReason(for: trip(800, title: "Yunusobod", id: 7), ledger: same,
                                                      now: noon.addingTimeInterval(300), calendar: calendar),
                       .contentChanged)
    }

    /// Снимок и учёт, записанные сборкой до 14.5, читаются: поля id в них нет.
    func testSnapshotWithoutIDDecodes() throws {
        let json = #"{"state":{"isTripActive":true,"camera":{"symbol":"camera.fill","title":"Юнусабад","within":500}},"updatedAt":0}"#
        let snapshot = try JSONDecoder().decode(WatchComplicationSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.state.camera?.within, 500)
        XCTAssertNil(snapshot.state.camera?.id)
        let ledgerJSON = #"{"lastState":{"isTripActive":true,"camera":{"symbol":"camera.fill","within":300}},"routineReloads":3}"#
        let ledger = try JSONDecoder().decode(WatchComplicationLedger.self, from: Data(ledgerJSON.utf8))
        XCTAssertEqual(ledger.routineReloads, 3)
        XCTAssertNil(ledger.lastState?.camera?.id)
    }

    // MARK: - Толчок с телефона (14.5)

    func testPushIsTakenOnlyWhenNewerAndFresh() {
        let applied = noon.addingTimeInterval(-30)
        XCTAssertTrue(WatchComplication.acceptsPush(sentAt: noon.addingTimeInterval(-5), lastAppliedAt: applied,
                                                    now: noon))
        XCTAssertFalse(WatchComplication.acceptsPush(sentAt: applied, lastAppliedAt: applied, now: noon),
                       "тот же снимок, что уже пришёл контекстом")
        XCTAssertFalse(WatchComplication.acceptsPush(sentAt: noon.addingTimeInterval(-60), lastAppliedAt: applied,
                                                     now: noon), "старее применённого — очередь, не откат")
        XCTAssertTrue(WatchComplication.acceptsPush(sentAt: noon.addingTimeInterval(-60), lastAppliedAt: nil,
                                                    now: noon), "часы только проснулись")
        XCTAssertFalse(WatchComplication.acceptsPush(sentAt: noon.addingTimeInterval(-WatchComplication.pushMaxAge - 1),
                                                     lastAppliedAt: nil, now: noon), "опоздавший — не берём")
        XCTAssertFalse(WatchComplication.acceptsPush(sentAt: nil, lastAppliedAt: nil, now: noon),
                       "без времени отправки — не наш")
        XCTAssertTrue(WatchComplication.acceptsPush(sentAt: noon.addingTimeInterval(20), lastAppliedAt: nil,
                                                    now: noon), "часы телефона чуть впереди")
        XCTAssertFalse(WatchComplication.acceptsPush(sentAt: noon.addingTimeInterval(WatchComplication.pushClockSkew + 1),
                                                     lastAppliedAt: nil, now: noon))
    }

    /// Контекст и толчок несут один снимок — в каком бы порядке они ни
    /// пришли, перезагрузка одна (тот же путь ComplicationFeed).
    func testContextAndPushOfOneStateReloadOnce() {
        var ledger = WatchComplication.recording(.tripChanged, state: trip(800, id: 1), ledger: .init(),
                                                 now: noon, calendar: calendar)
        var reloads = 0
        let next = trip(800, id: 2)
        for second in [150.0, 151.0, 170.0] {   // контекст, толчок, повтор контекста
            let now = noon.addingTimeInterval(second)
            if let reason = WatchComplication.reloadReason(for: next, ledger: ledger, now: now,
                                                           calendar: calendar) {
                ledger = WatchComplication.recording(reason, state: next, ledger: ledger, now: now,
                                                     calendar: calendar)
                reloads += 1
            }
        }
        XCTAssertEqual(reloads, 1)
    }

    func testSnapshotIsDatedBySendTime() {
        let hourAgo = noon.addingTimeInterval(-3600)
        // Контекст, пролежавший час, — «данные на» час назад, а не «сейчас».
        let snapshot = WatchComplicationSnapshot(state: trip(800),
                                                 updatedAt: WatchComplication.snapshotDate(sentAt: hourAgo,
                                                                                           receivedAt: noon))
        XCTAssertEqual(snapshot.updatedAt, hourAgo)
        XCTAssertTrue(WatchComplication.isStale(snapshot, now: noon))
        XCTAssertEqual(WatchComplication.snapshotDate(sentAt: nil, receivedAt: noon), noon,
                       "старый телефон без времени — время приёма")
        XCTAssertEqual(WatchComplication.snapshotDate(sentAt: noon.addingTimeInterval(30), receivedAt: noon), noon,
                       "из будущего — не свежее, чем сейчас")
    }

    // MARK: - Устаревание

    func testStaleTripSnapshotIsMarkedNotHidden() {
        let snapshot = WatchComplicationSnapshot(state: trip(800), updatedAt: noon)
        XCTAssertFalse(WatchComplication.isStale(snapshot, now: noon.addingTimeInterval(60)))
        XCTAssertTrue(WatchComplication.isStale(snapshot,
                                                now: noon.addingTimeInterval(WatchComplication.staleAfter + 1)))
        let idle = WatchComplicationSnapshot(state: .noTrip, updatedAt: noon)
        XCTAssertFalse(WatchComplication.isStale(idle, now: noon.addingTimeInterval(86_400)),
                       "«нет поездки» не стареет")
    }

    func testTimelineFadesWithoutAReload() {
        let snapshot = WatchComplicationSnapshot(state: trip(800), updatedAt: noon)
        let dates = WatchComplication.entryDates(for: snapshot, now: noon.addingTimeInterval(30))
        XCTAssertEqual(dates.count, 2, "сейчас и момент, когда снимок потускнеет")
        XCTAssertTrue(WatchComplication.isStale(snapshot, now: dates[1]))
        XCTAssertFalse(WatchComplication.isStale(snapshot, now: dates[0]))
        XCTAssertEqual(WatchComplication.entryDates(for: snapshot,
                                                    now: noon.addingTimeInterval(3600)).count, 1,
                       "уже старый — одна запись")
        let idle = WatchComplicationSnapshot(state: .noTrip, updatedAt: noon)
        XCTAssertEqual(WatchComplication.entryDates(for: idle, now: noon).count, 1)
    }

    func testSnapshotRoundTrip() throws {
        let snapshot = WatchComplicationSnapshot(state: trip(420), updatedAt: noon)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WatchComplicationSnapshot.self, from: data), snapshot)
    }

    // MARK: - Цвета

    private func hex(_ color: Color, _ style: UIUserInterfaceStyle) -> UInt32 {
        let ui = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            func linear(_ v: UInt32) -> Double {
                let c = Double(v) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear((hex >> 16) & 0xFF) + 0.7152 * linear((hex >> 8) & 0xFF)
                + 0.0722 * linear(hex & 0xFF)
        }
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private let types: [CameraType] = [.stationaryCamera, .stationaryRadar, .intelligentRadar,
                                       .mobileRadar, .tripod, .dpsPost, .accident, .other("x")]

    /// Диск камеры на циферблате — цвет её маркера на карте (Theme.Types).
    func testCameraDiscIsTheMapMarkerColour() {
        // С 29.C — все восемь: заливка значка одна (CameraGlyph.fillRGB), и
        // ДТП на маркере — постоянный красный опасности.
        for type in types {
            XCTAssertEqual(WidgetPalette.cameraFill(symbol: type.symbolName), hex(type.tint, .light),
                           "\(type.symbolName) разошёлся с Theme.Types")
        }
        XCTAssertEqual(WidgetPalette.cameraFill(symbol: nil), WidgetPalette.cameraFill(symbol: "mappin"))
    }

    func testGlyphIsReadableOnEveryDisc() {
        for type in types {
            let fill = WidgetPalette.cameraFill(symbol: type.symbolName)
            let glyph = WidgetPalette.cameraGlyph(symbol: type.symbolName)
            XCTAssertGreaterThanOrEqual(contrast(fill, glyph), 4.5, type.symbolName)
        }
    }

    /// Красный на циферблате — только камера: «нет поездки» синий, «камер
    /// рядом нет» зелёный, неизвестная точка — графит, не красный и не синий.
    func testOnlyACameraIsRed() {
        let red = WidgetPalette.cameraFill(symbol: CameraType.stationaryCamera.symbolName)
        XCTAssertNotEqual(WidgetPalette.accentFill.dark, red)
        XCTAssertNotEqual(WidgetPalette.successFill.dark, red)
        let unknown = WidgetPalette.cameraFill(symbol: "mappin")
        XCTAssertNotEqual(unknown, red)
        XCTAssertNotEqual(unknown, WidgetPalette.accentFill.dark)
    }
}
