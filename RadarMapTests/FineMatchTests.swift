//
//  FineMatchTests.swift
//  RadarMapTests
//
//  Сверка пришедшего штрафа с проездом (этап 17.1). Главное правило —
//  молча не угадываем: две камеры рядом по времени без различий — выбор за
//  человеком; один кандидат без подтверждений — тоже. Место по координате
//  и скорость могут кандидата отвергнуть, текст адреса — только подтвердить.
//

import XCTest
@testable import RadarMap

final class FineMatchTests: XCTestCase {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        return calendar
    }

    /// 12.10.2026 18:45 по Ташкенту.
    private var fineAt: Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 18, minute: 45))!
    }

    private func pass(_ id: Int, speed: Double, limit: Int? = 60, at date: Date,
                      location: String = "Amir Temur shoh ko‘chasi 108-uy",
                      lat: Double = 41.3110, lon: Double = 69.2790) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: id, typeRaw: "Стационар радар", location: location,
                     speedKmh: speed, date: date, lat: lat, lon: lon, limitKmh: limit)
    }

    private func record(_ passes: [PassedCamera], start: Date) -> TripRecord {
        TripRecord(id: start.timeIntervalSince1970, startedAt: start, endedAt: start.addingTimeInterval(1800),
                   distanceMeters: 12_000, maxSpeedKmh: 95, passed: passes, score: 80)
    }

    private func query(place: String? = nil, lat: Double? = nil, lon: Double? = nil,
                       speed: Int? = nil, timeKnown: Bool = true, at: Date? = nil) -> FineMatch.Query {
        FineMatch.Query(at: at ?? fineAt, timeKnown: timeKnown, place: place, lat: lat, lon: lon, speedKmh: speed)
    }

    // MARK: - Точное совпадение

    /// Время в окне, адрес и скорость сходятся — сверено.
    func testExactMatch() {
        let target = pass(1, speed: 78, at: fineAt.addingTimeInterval(120))
        let history = [record([target], start: fineAt.addingTimeInterval(-600))]
        let result = FineMatch.match(query(place: "г. Ташкент, ул. Амира Темура, 108", speed: 81),
                                     history: history, days: [], calendar: utc)
        guard case .matched(let candidate) = result else { return XCTFail("ожидали сверку: \(result)") }
        XCTAssertEqual(candidate.passID, target.id)
        XCTAssertEqual(candidate.place, .agrees)
        XCTAssertEqual(candidate.speed, .agrees)
    }

    /// Проезд вне окна (полчаса) — не кандидат, даже на той же камере.
    func testOutsideTimeWindowIsNoCandidate() {
        let late = pass(1, speed: 78, at: fineAt.addingTimeInterval(1800))
        let history = [record([late], start: fineAt.addingTimeInterval(1500))]
        XCTAssertEqual(FineMatch.match(query(speed: 78), history: history, days: [], calendar: utc), .none)
    }

    /// Окно — ± AppConfig.fineMatchWindowSeconds: дрейф часов камеры в 9 минут ловится.
    func testClockDriftInsideWindow() {
        let drifted = pass(1, speed: 78, at: fineAt.addingTimeInterval(-540))
        let history = [record([drifted], start: fineAt.addingTimeInterval(-1200))]
        guard case .matched = FineMatch.match(query(speed: 80), history: history, days: [], calendar: utc)
        else { return XCTFail("дрейф 9 минут должен сверяться") }
    }

    // MARK: - Две камеры рядом

    /// Две камеры за пять минут, у штрафа ни места, ни скорости — выбирает человек.
    func testTwoCamerasCloseInTimeAskTheUser() {
        let a = pass(1, speed: 78, at: fineAt.addingTimeInterval(-60))
        let b = pass(2, speed: 81, at: fineAt.addingTimeInterval(240), location: "Mustaqillik shoh ko‘chasi")
        let history = [record([a, b], start: fineAt.addingTimeInterval(-900))]
        guard case .choose(let candidates) = FineMatch.match(query(), history: history, days: [], calendar: utc)
        else { return XCTFail("две равные камеры — только выбор человека") }
        XCTAssertEqual(Set(candidates.map(\.passID)), [a.id, b.id])
        XCTAssertEqual(candidates.first?.passID, a.id, "ближняя по времени — первой")
    }

    /// Обе камеры подходят и по скорости — подтверждений поровну, снова выбор.
    func testTwoCamerasEqualEvidenceStillAsk() {
        let a = pass(1, speed: 78, at: fineAt.addingTimeInterval(-60))
        let b = pass(2, speed: 80, at: fineAt.addingTimeInterval(240))
        let history = [record([a, b], start: fineAt.addingTimeInterval(-900))]
        guard case .choose = FineMatch.match(query(speed: 82), history: history, days: [], calendar: utc)
        else { return XCTFail("равные подтверждения — не угадываем") }
    }

    /// Адрес из СМС совпал с одной из двух камер — это довод, а не догадка.
    func testPlaceTextPicksOneOfTwo() {
        let temur = pass(1, speed: 78, at: fineAt.addingTimeInterval(-60))
        let other = pass(2, speed: 80, at: fineAt.addingTimeInterval(240), location: "Bunyodkor ko‘chasi")
        let history = [record([temur, other], start: fineAt.addingTimeInterval(-900))]
        let result = FineMatch.match(query(place: "ул. Амира Темура"), history: history, days: [], calendar: utc)
        guard case .matched(let candidate) = result else { return XCTFail("адрес различает камеры: \(result)") }
        XCTAssertEqual(candidate.passID, temur.id)
    }

    /// Координата дальше порога отвергает камеру; вторая подтверждена координатой.
    func testCoordinateRejectsFarCamera() {
        let near = pass(1, speed: 78, at: fineAt.addingTimeInterval(-60), lat: 41.3110, lon: 69.2790)
        let far = pass(2, speed: 80, at: fineAt.addingTimeInterval(60), lat: 41.3300, lon: 69.2790)
        let history = [record([near, far], start: fineAt.addingTimeInterval(-900))]
        let result = FineMatch.match(query(lat: 41.3112, lon: 69.2791), history: history, days: [], calendar: utc)
        guard case .matched(let candidate) = result else { return XCTFail("координата решает: \(result)") }
        XCTAssertEqual(candidate.passID, near.id)
    }

    /// Скорость штрафа не сходится с замером (60 против наших 88) — не наш проезд.
    func testSpeedDisagreementRejects() {
        let fast = pass(1, speed: 88, at: fineAt.addingTimeInterval(60))
        let history = [record([fast], start: fineAt.addingTimeInterval(-900))]
        XCTAssertEqual(FineMatch.match(query(speed: 60), history: history, days: [], calendar: utc), .none)
    }

    /// Камера может показать больше нашего минимума в зоне — до +20 сходится.
    func testCameraMayReadAboveOurMinimum() {
        XCTAssertEqual(FineMatch.speedAgreement(98, passSpeed: 80), .agrees)
        XCTAssertEqual(FineMatch.speedAgreement(72, passSpeed: 80), .agrees)
        XCTAssertEqual(FineMatch.speedAgreement(101, passSpeed: 80), .disagrees)
        XCTAssertEqual(FineMatch.speedAgreement(71, passSpeed: 80), .disagrees)
        XCTAssertEqual(FineMatch.speedAgreement(nil, passSpeed: 80), .unknown)
    }

    /// Несовпадение слов адреса не отвергает: «Чиланзар» и «Бунёдкор» бывают одним местом.
    func testPlaceTextMismatchIsUnknownNotDisagree() {
        let camera = pass(1, speed: 78, at: fineAt, location: "Bunyodkor ko‘chasi")
        XCTAssertEqual(FineMatch.placeAgreement(query(place: "Чиланзарский район"), pass: camera), .unknown)
    }

    // MARK: - Один без подтверждений, без времени, занятые

    /// Единственный кандидат, но у штрафа нет ни места, ни скорости — спросить.
    func testSingleCandidateWithoutEvidenceAsks() {
        let only = pass(1, speed: 78, at: fineAt.addingTimeInterval(60))
        let history = [record([only], start: fineAt.addingTimeInterval(-900))]
        XCTAssertEqual(FineMatch.match(query(), history: history, days: [], calendar: utc),
                       .choose(FineMatch.candidates(query(), history: history, calendar: utc)))
    }

    /// Время не известно — ищем по всему дню; скорость подтверждает.
    func testDayOnlyQuerySearchesWholeDay() {
        let morning = utc.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 8, minute: 10))!
        let target = pass(1, speed: 78, at: morning)
        let yesterday = pass(2, speed: 78, at: morning.addingTimeInterval(-86400))
        let history = [record([target], start: morning.addingTimeInterval(-600)),
                       record([yesterday], start: morning.addingTimeInterval(-87000))]
        let day = utc.startOfDay(for: morning)
        let result = FineMatch.match(query(speed: 80, timeKnown: false, at: day), history: history,
                                     days: [], calendar: utc)
        guard case .matched(let candidate) = result else { return XCTFail("день без времени: \(result)") }
        XCTAssertEqual(candidate.passID, target.id)
    }

    /// Проезд, уже сверенный с другим постановлением, не предлагается.
    func testTakenPassIsExcluded() {
        let target = pass(1, speed: 78, at: fineAt)
        let history = [record([target], start: fineAt.addingTimeInterval(-900))]
        XCTAssertEqual(FineMatch.match(query(speed: 78), history: history, days: [], taken: [target.id],
                                       calendar: utc), .none)
    }

    // MARK: - Нет проезда и дневная сводка

    /// Ни записи, ни сводки — штраф «без поездки в истории».
    func testNoPassAtAll() {
        XCTAssertEqual(FineMatch.match(query(speed: 78), history: [], days: [], calendar: utc), .none)
    }

    /// Запись вычищена, но сводка дня помнит превышение — сверка с днём.
    func testPrunedRecordFallsBackToDayRollup() {
        let old = pass(1, speed: 88, at: fineAt)
        let pruned = record([old], start: fineAt.addingTimeInterval(-900))
        let days = TripDayBook.folded(pruned, into: [], calendar: utc)
        XCTAssertEqual(FineMatch.match(query(speed: 90), history: [], days: days, calendar: utc),
                       .day(utc.startOfDay(for: fineAt)))
    }

    /// Все превышения дня — в сохранённых записях (и не подошли) — сверять с днём нечего.
    func testDayRollupFullyCoveredByKeptRecordsIsNone() {
        let other = pass(1, speed: 88, at: fineAt.addingTimeInterval(-4 * 3600))
        let kept = record([other], start: fineAt.addingTimeInterval(-4 * 3600 - 600))
        let days = TripDayBook.folded(kept, into: [], calendar: utc)
        XCTAssertEqual(FineMatch.match(query(speed: 90), history: [kept], days: days, calendar: utc), .none)
    }

    /// Перенос денег дня: с «возможных» — не больше оценки и только вычищенное;
    /// в «пришло» — сумма постановления.
    func testDayShiftMovesOnlyPrunedRisk() {
        let prunedPass = pass(1, speed: 88, at: fineAt)              // +28 → 5 БРВ
        let keptPass = pass(2, speed: 72, at: fineAt.addingTimeInterval(3600))   // +12 → 1 БРВ
        let pruned = record([prunedPass], start: fineAt.addingTimeInterval(-900))
        let kept = record([keptPass], start: fineAt.addingTimeInterval(3000))
        let days = TripDayBook.folded(kept, into: TripDayBook.folded(pruned, into: [], calendar: utc), calendar: utc)
        let day = utc.startOfDay(for: fineAt)
        let shift = FineMatch.dayShift(day: day, amount: 2_100_000, speedKmh: 90, limitKmh: 60,
                                       history: [kept], days: days, calendar: utc)
        XCTAssertEqual(shift.riskMoved, 5 * FineSchedule.brv, accuracy: 0.01)
        XCTAssertEqual(shift.paidAdded, 2_100_000, accuracy: 0.01)
        // Ни суммы, ни скорости с лимитом — деньги по догадке не двигаем.
        let blind = FineMatch.dayShift(day: day, amount: nil, speedKmh: nil, limitKmh: nil,
                                       history: [kept], days: days, calendar: utc)
        XCTAssertEqual(blind.riskMoved, 0)
        XCTAssertEqual(blind.paidAdded, 0)
    }

    // MARK: - Адрес словами

    func testPlaceSimilarityAcrossScripts() {
        XCTAssertGreaterThanOrEqual(FinePlace.similarity("г. Ташкент, ул. Амира Темура, 108",
                                                         "Amir Temur shoh ko‘chasi 108-uy"), 0.5)
        XCTAssertGreaterThanOrEqual(FinePlace.similarity("Чиланзарский р-н", "Chilonzor tumani"), 0.5)
        XCTAssertGreaterThanOrEqual(FinePlace.similarity("Юнусабад", "Yunusobod tumani, Amir Temur"), 0.5)
        // Кириллическая «е» внутри латинского слова реестра.
        XCTAssertGreaterThanOrEqual(FinePlace.similarity("Ibn Sino va Andijon ko‘chalari kesishmasi",
                                                         "Ibn Sino va Andijon Ko‘chalari Kеsishmasi"), 0.9)
        XCTAssertEqual(FinePlace.similarity("ул. Мукими", "Bunyodkor ko‘chasi"), 0)
        // Совпали одни числа — это не адрес.
        XCTAssertEqual(FinePlace.similarity("дом 12", "12-uy, Navoiy"), 0)
        XCTAssertEqual(FinePlace.similarity("", "Amir Temur"), 0)
    }
}
