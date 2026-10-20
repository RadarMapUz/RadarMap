//
//  MaintenanceTests.swift
//  RadarMapTests
//
//  Обслуживание машины (18.1): одометр по дневным агрегатам (поездки до
//  ввода пробега не считаются), срок — первый из двух (км или дата),
//  «сделано сегодня», документы только по дате, нет данных — нет срока.
//

import XCTest
@testable import RadarMap

final class MaintenanceTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        return calendar
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, km: Double) -> TripDay {
        var row = TripDay(day: calendar.startOfDay(for: date(y, m, d)))
        row.trips = 1
        row.distanceMeters = km * 1000
        return row
    }

    private func book(odometer km: Double = 85_000, at: Date, base: Double = 0,
                      _ records: [MaintenanceKind: MaintenanceRecord] = [:]) -> MaintenanceBook {
        var book = MaintenanceBook(odometerKm: km, odometerAt: at, odometerDayBaseMeters: base)
        for (kind, record) in records { book.set(record, for: kind) }
        return book
    }

    private func state(_ kind: MaintenanceKind, _ record: MaintenanceRecord, odometer: Double?,
                       now: Date) -> Maintenance.State {
        Maintenance.state(kind, record: record, odometerKm: odometer, now: now, calendar: calendar)
    }

    // MARK: - Одометр

    func testTripsBeforeEntryDoNotCount() {
        // Ввод 10.10 в 12:00: в строке дня уже 20 км (утренние поездки — они
        // на приборке). К вечеру строка выросла до 35 км, назавтра — 40 км.
        let entry = date(2026, 10, 10)
        let days = [day(2026, 10, 11, km: 40), day(2026, 10, 10, km: 35), day(2026, 10, 7, km: 50)]
        let odometer = Maintenance.odometer(book(at: entry, base: 20_000), days: days, calendar: calendar)
        XCTAssertEqual(odometer ?? 0, 85_055, accuracy: 0.001, "15 км дня ввода после ввода + 40 км завтра; 7.10 — до ввода")
    }

    func testSettingOdometerTakesTodaysRowAsBase() {
        let now = date(2026, 10, 10, 18)
        let days = [day(2026, 10, 10, km: 35), day(2026, 10, 9, km: 12)]
        let set = Maintenance.settingOdometer(MaintenanceBook(), km: 90_000, now: now, days: days, calendar: calendar)
        XCTAssertEqual(set.odometerDayBaseMeters, 35_000, "сегодняшние поездки до ввода уже на приборке")
        XCTAssertEqual(Maintenance.odometer(set, days: days, calendar: calendar), 90_000)
        XCTAssertNil(Maintenance.odometer(MaintenanceBook(), days: days, calendar: calendar), "пробег не вводили — одометра нет")
    }

    func testDeletingPreEntryTripNeverLowersOdometer() {
        // Строка дня ввода уменьшилась (удалили утреннюю поездку): прибавка — ноль, не минус.
        let entry = date(2026, 10, 10)
        let odometer = Maintenance.odometer(book(at: entry, base: 20_000), days: [day(2026, 10, 10, km: 5)],
                                            calendar: calendar)
        XCTAssertEqual(odometer, 85_000)
    }

    func testOdometerEditKeepsServiceHistory() {
        // Масло меняли при 80 000. Водитель поправил одометр вверх (по поездкам
        // набежало меньше, чем на приборке) — пройдено с замены стало больше.
        let now = date(2026, 10, 20)
        var oil = MaintenanceRecord()
        oil.doneKm = 80_000
        oil.doneAt = date(2026, 8, 1)
        var edited = book(odometer: 84_000, at: date(2026, 9, 1), [.oil: oil])
        XCTAssertEqual(state(.oil, edited.record(.oil), odometer: 84_000, now: now).remainingKm, 4_000)
        edited = Maintenance.settingOdometer(edited, km: 87_700, now: now, days: [], calendar: calendar)
        let odometer = Maintenance.odometer(edited, days: [], calendar: calendar)
        XCTAssertEqual(odometer, 87_700)
        let after = state(.oil, edited.record(.oil), odometer: odometer, now: now)
        XCTAssertEqual(after.remainingKm, 300)
        XCTAssertEqual(after.status, .soon)
        // Поправили вниз ниже пробега замены (опечатка) — «только что сделано», не минус.
        let typo = state(.oil, edited.record(.oil), odometer: 79_000, now: now)
        XCTAssertEqual(typo.remainingKm, 8_000)
    }

    // MARK: - Первый из двух сроков

    func testKmBeforeDate() {
        var oil = MaintenanceRecord()
        oil.doneKm = 80_000
        oil.doneAt = date(2026, 8, 20)
        let now = date(2026, 10, 20)
        let soon = state(.oil, oil, odometer: 87_600, now: now)
        XCTAssertEqual(soon.status, .soon, "400 км до замены, а по дате ещё 10 месяцев")
        XCTAssertEqual(soon.remainingKm, 400)
        XCTAssertGreaterThan(soon.daysLeft ?? 0, 300)
        XCTAssertEqual(state(.oil, oil, odometer: 88_000, now: now).status, .due)
        XCTAssertEqual(state(.oil, oil, odometer: 88_999, now: now).status, .due)
        XCTAssertEqual(state(.oil, oil, odometer: 89_000, now: now).status, .overdue)
        XCTAssertEqual(state(.oil, oil, odometer: 86_000, now: now).status, .ok)
    }

    func testDateBeforeKm() {
        var oil = MaintenanceRecord()
        oil.doneKm = 80_000
        oil.doneAt = date(2025, 11, 1)
        // Проехали за год всего 2 000 км — срок по дате наступает раньше.
        let soon = state(.oil, oil, odometer: 82_000, now: date(2026, 10, 22))
        XCTAssertEqual(soon.status, .soon)
        XCTAssertEqual(soon.daysLeft, 10)
        XCTAssertEqual(soon.dueDate, calendar.startOfDay(for: date(2026, 11, 1)))
        XCTAssertEqual(state(.oil, oil, odometer: 82_000, now: date(2026, 11, 1, 8)).status, .due, "в сам день срока — «пора»")
        XCTAssertEqual(state(.oil, oil, odometer: 82_000, now: date(2026, 11, 30)).status, .due)
        XCTAssertEqual(state(.oil, oil, odometer: 82_000, now: date(2026, 12, 1)).status, .overdue, "30 дней за сроком")
        XCTAssertEqual(state(.oil, oil, odometer: 82_000, now: date(2026, 10, 1)).status, .ok)
    }

    func testMarkDoneToday() {
        var oil = MaintenanceRecord()
        oil.doneKm = 78_000
        oil.doneAt = date(2025, 6, 1)
        let now = date(2026, 10, 20, 17)
        let before = book(at: date(2026, 1, 1), [.oil: oil])
        let old = state(.oil, before.record(.oil), odometer: 88_100, now: now)
        XCTAssertEqual(old.status, .overdue)
        let done = Maintenance.markedDone(before, kind: .oil, odometerKm: 88_100, now: now)
        let fresh = state(.oil, done.record(.oil), odometer: 88_100, now: now)
        XCTAssertEqual(fresh.status, .ok)
        XCTAssertEqual(fresh.remainingKm, 8_000)
        XCTAssertEqual(fresh.dueDate, calendar.startOfDay(for: date(2027, 10, 20)))
        XCTAssertEqual(fresh.progress, 0)
        XCTAssertNotEqual(fresh.cycle, old.cycle, "новый цикл — новые напоминания")
    }

    func testMarkDoneKeepsCustomIntervalAndEnablesItem() {
        var plugs = MaintenanceRecord()
        plugs.enabled = false
        plugs.intervalKm = 20_000
        let done = Maintenance.markedDone(book(at: date(2026, 1, 1), [.sparkPlugs: plugs]),
                                          kind: .sparkPlugs, odometerKm: 90_000, now: date(2026, 10, 20))
        XCTAssertTrue(done.isEnabled(.sparkPlugs))
        let fresh = state(.sparkPlugs, done.record(.sparkPlugs), odometer: 90_000, now: date(2026, 10, 20))
        XCTAssertEqual(fresh.remainingKm, 20_000, "свой интервал газовой машины сохраняется")
        XCTAssertNil(fresh.dueDate, "у свечей нет срока по времени")
    }

    // MARK: - Документы: только дата

    func testDocumentIsDateOnly() {
        var osago = MaintenanceRecord()
        osago.dueDate = date(2026, 10, 30)
        osago.intervalKm = 5_000   // мусор из старой версии: у документа пробега нет
        osago.doneKm = 1
        let now = date(2026, 10, 20)
        let soon = state(.osago, osago, odometer: 90_000, now: now)
        XCTAssertEqual(soon.status, .soon)
        XCTAssertNil(soon.remainingKm)
        XCTAssertEqual(soon.daysLeft, 10)
        XCTAssertEqual(state(.osago, osago, odometer: nil, now: date(2026, 10, 30, 23)).status, .due,
                       "последний день действия — «пора»")
        XCTAssertEqual(state(.osago, osago, odometer: nil, now: date(2026, 10, 31, 0, 30)).status, .overdue,
                       "назавтра полис уже не действует")
        XCTAssertEqual(state(.osago, osago, odometer: nil, now: date(2026, 9, 1)).status, .ok)
    }

    func testDocumentRenewedToday() {
        var tint = MaintenanceRecord()
        tint.enabled = true
        tint.dueDate = date(2026, 10, 15)
        let now = date(2026, 10, 20)
        let renewed = Maintenance.markedDone(book(at: now, [.tintPermit: tint]), kind: .tintPermit,
                                             odometerKm: 90_000, now: now)
        let fresh = state(.tintPermit, renewed.record(.tintPermit), odometer: 90_000, now: now)
        XCTAssertEqual(fresh.status, .ok)
        XCTAssertEqual(fresh.dueDate, calendar.startOfDay(for: date(2027, 10, 20)))
        XCTAssertNil(renewed.record(.tintPermit).doneKm, "у документа нет пробега")
    }

    func testProxyNeedsDate() {
        XCTAssertFalse(Maintenance.canMarkDone(.proxy, record: MaintenanceRecord()),
                       "у доверенности свой срок — вводится датой")
        XCTAssertTrue(Maintenance.canMarkDone(.osago, record: MaintenanceRecord()))
        XCTAssertTrue(Maintenance.canMarkDone(.timingBelt, record: MaintenanceRecord()))
        XCTAssertEqual(state(.proxy, MaintenanceRecord(), odometer: 90_000, now: date(2026, 10, 20)).status, .unknown)
    }

    // MARK: - Нет данных — нет срока

    func testUnknownWithoutData() {
        let now = date(2026, 10, 20)
        XCTAssertEqual(state(.oil, MaintenanceRecord(), odometer: 90_000, now: now).status, .unknown,
                       "не «меняли при вводе пробега» — не знаем")
        var kmOnly = MaintenanceRecord()
        kmOnly.doneKm = 85_000
        XCTAssertEqual(state(.oil, kmOnly, odometer: nil, now: now).status, .unknown, "без одометра пробег не посчитать")
        XCTAssertEqual(state(.oil, kmOnly, odometer: 92_800, now: now).status, .soon, "200 км до замены — даты нет, хватает пробега")
        var dateOnly = MaintenanceRecord()
        dateOnly.doneAt = date(2024, 10, 1)
        let brake = state(.brakeFluid, dateOnly, odometer: nil, now: now)
        XCTAssertEqual(brake.status, .due, "тормозная жидкость — по времени, без одометра")
        XCTAssertNil(brake.intervalKm)
    }

    func testZeroIntervalSwitchesDimensionOff() {
        var oil = MaintenanceRecord()
        oil.doneKm = 80_000
        oil.doneAt = date(2024, 1, 1)
        oil.intervalMonths = 0
        let kmOnly = state(.oil, oil, odometer: 81_000, now: date(2026, 10, 20))
        XCTAssertEqual(kmOnly.status, .ok, "срок по времени выключен — два года не в счёт")
        XCTAssertNil(kmOnly.dueDate)
        oil.intervalMonths = nil
        oil.intervalKm = 0
        let dateOnly = state(.oil, oil, odometer: 200_000, now: date(2024, 6, 1))
        XCTAssertEqual(dateOnly.status, .ok, "срок по пробегу выключен — 120 000 км не в счёт")
        XCTAssertNil(dateOnly.remainingKm)
    }

    func testProgressIsWorseOfTwo() {
        var oil = MaintenanceRecord()
        oil.doneKm = 80_000
        oil.doneAt = date(2026, 1, 1)
        let half = state(.oil, oil, odometer: 82_000, now: date(2026, 7, 2))
        XCTAssertEqual(half.progress ?? 0, 0.5, accuracy: 0.01, "по дате половина, по км четверть")
        XCTAssertEqual(state(.oil, oil, odometer: 99_000, now: date(2026, 2, 1)).progress, 1, "полоса не вылезает")
    }

    // MARK: - Состав списка

    func testItemsFollowVehicle() {
        let now = date(2026, 10, 20)
        let empty = MaintenanceBook()
        let petrol = Maintenance.states(empty, energy: .fuel, odometerKm: nil, now: now, calendar: calendar).map(\.kind)
        XCTAssertTrue(petrol.contains(.oil))
        XCTAssertFalse(petrol.contains(.gasCylinder), "баллон — только у метана и пропана")
        XCTAssertFalse(petrol.contains(.kasko), "КАСКО включают сами")
        XCTAssertTrue(Maintenance.states(empty, energy: .cng, odometerKm: nil, now: now, calendar: calendar)
            .map(\.kind).contains(.gasCylinder))
        XCTAssertTrue(Maintenance.states(empty, energy: .lpg, odometerKm: nil, now: now, calendar: calendar)
            .map(\.kind).contains(.gasCylinder))
        let electric = Maintenance.states(empty, energy: .electric, odometerKm: nil, now: now, calendar: calendar)
            .map(\.kind)
        XCTAssertFalse(electric.contains(.oil))
        XCTAssertFalse(electric.contains(.sparkPlugs))
        XCTAssertTrue(electric.contains(.cabinFilter))
        XCTAssertTrue(electric.contains(.osago))

        var off = MaintenanceRecord()
        off.enabled = false
        var kasko = MaintenanceRecord()
        kasko.enabled = true
        let custom = book(at: now, [.timingBelt: off, .kasko: kasko])
        let kinds = Maintenance.states(custom, energy: .fuel, odometerKm: nil, now: now, calendar: calendar).map(\.kind)
        XCTAssertFalse(kinds.contains(.timingBelt), "цепь вместо ремня — пункт выключен")
        XCTAssertTrue(kinds.contains(.kasko))
    }

    func testAttentionMostUrgentFirst() {
        let now = date(2026, 10, 20)
        var oil = MaintenanceRecord()
        oil.doneKm = 80_000
        var osago = MaintenanceRecord()
        osago.dueDate = date(2026, 10, 25)
        var brake = MaintenanceRecord()
        brake.doneAt = date(2024, 1, 1)
        let all = Maintenance.states(book(at: now, [.oil: oil, .osago: osago, .brakeFluid: brake]),
                                     energy: .fuel, odometerKm: 87_700, now: now, calendar: calendar)
        XCTAssertEqual(Maintenance.attention(all).map(\.kind), [.brakeFluid, .oil, .osago],
                       "просрочено → скоро (по порядку экрана)")
    }

    // MARK: - Файл на диске

    func testDecodingIsForgiving() throws {
        let json = """
        {"odometerKm": 85000, "records": {"oil": {"doneKm": 80000},
         "wipers": {"intervalKm": 1}, "osago": {}}}
        """
        let book = try JSONDecoder().decode(MaintenanceBook.self, from: Data(json.utf8))
        XCTAssertEqual(book.record(.oil).doneKm, 80_000)
        XCTAssertNil(book.odometerAt)
        XCTAssertEqual(book.records?.count, 3, "пункт будущей версии не валит разбор")
        let empty = try JSONDecoder().decode(MaintenanceBook.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, MaintenanceBook())
    }
}
