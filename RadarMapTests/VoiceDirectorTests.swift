//
//  VoiceDirectorTests.swift
//  RadarMapTests
//
//  Арбитр реплик. Главный тест здесь — тот, что воспроизводит поездку, в
//  которой камера промолчала: превышение объявили, а про камеру в 300–500
//  метрах не сказали. Он должен падать на старом поведении и проходить на новом.
//

import XCTest
@testable import RadarMap

final class VoiceDirectorTests: XCTestCase {

    private func situation(mode: VoiceMode = .smart,
                           context: AlertPolicy.Context = .city,
                           sudden: Bool = false, familiar: Bool = false,
                           over: Double? = nil, limit: Int? = 60,
                           crawling: Bool = false) -> VoiceDirector.Situation {
        VoiceDirector.Situation(mode: mode, context: context, isSudden: sudden,
                                isFamiliar: familiar, overKmh: over,
                                limitKmh: limit, isCrawling: crawling)
    }

    // MARK: - Регрессия: камера обязана звучать

    func testCameraSpeaksInDefaultModeEvenWithinTheLimit() {
        // Именно это и молчало: режим «Умно» стоит по умолчанию, водитель едет
        // в лимите, камера в 300 метрах — и ни слова. Камеру видно на карте,
        // голоса нет, приложение выглядит сломанным.
        let plan = VoiceDirector.decide(situation(mode: .smart, over: nil))
        XCTAssertNotEqual(plan.voice, .none,
                          "о камере впереди надо СКАЗАТЬ; вопрос только в том, сколько слов")
        XCTAssertEqual(plan.voice, .brief, "в городе — коротко")
    }

    func testCameraSpeaksWhenRoadLimitIsUnknown() {
        // Без лимита превышения не бывает по определению, и раньше это означало
        // полную тишину о камерах на всей такой дороге.
        let plan = VoiceDirector.decide(situation(over: nil, limit: nil))
        XCTAssertNotEqual(plan.voice, .none)
    }

    // MARK: - Приоритеты

    func testOverspeedNearCameraIsUrgent() {
        let plan = VoiceDirector.decide(situation(over: 18))
        XCTAssertEqual(plan.voice, .urgent)
        XCTAssertTrue(plan.beeps)
        XCTAssertTrue(plan.escalates)
        XCTAssertTrue(plan.speaksLimit, "в срочной фразе лимит обязателен")
    }

    func testSuddenPointIsAlwaysUrgent() {
        for mode in [VoiceMode.smart, .always] {
            let plan = VoiceDirector.decide(situation(mode: mode, sudden: true))
            XCTAssertEqual(plan.voice, .urgent, "\(mode) — о внезапной точке знать неоткуда")
        }
    }

    func testSilentModeBeatsEverything() {
        let plan = VoiceDirector.decide(situation(mode: .off, sudden: true, over: 40))
        XCTAssertEqual(plan.voice, .none, "выбор пользователя старше всех правил")
    }

    func testHighwaySpeaksFullPhraseWithLimit() {
        let plan = VoiceDirector.decide(situation(context: .highway))
        XCTAssertEqual(plan.voice, .calm)
        XCTAssertTrue(plan.speaksLimit, "на трассе времени хватает на «здесь 100»")
        XCTAssertFalse(plan.isBrief)
    }

    func testCitySpeaksBrieflyWithoutLimit() {
        let plan = VoiceDirector.decide(situation(context: .city))
        XCTAssertEqual(plan.voice, .brief)
        XCTAssertFalse(plan.speaksLimit, "в городе камеры идут одна за другой, слова дороги")
    }

    // MARK: - Пробка

    func testCrawlingPostponesRatherThanCancels() {
        let plan = VoiceDirector.decide(situation(crawling: true))
        XCTAssertEqual(plan.voice, .none)
        XCTAssertTrue(plan.postpone, "камера, вошедшая в радиус на светофоре, иначе теряется")
    }

    func testOverspeedBeatsCrawling() {
        // Ползём, но при этом устойчиво превышаем (узкая дворовая улица) —
        // это уже не пробка.
        let plan = VoiceDirector.decide(situation(over: 12, crawling: true))
        XCTAssertEqual(plan.voice, .urgent)
    }

    // MARK: - Свои камеры

    func testFamiliarCameraIsSilentInSmartMode() {
        let plan = VoiceDirector.decide(situation(familiar: true))
        XCTAssertEqual(plan.voice, .none,
                       "восемь камер дважды в день — голос перестаёт быть помощью")
    }

    func testFamiliarCameraStillSpeaksWhenOverspeeding() {
        let plan = VoiceDirector.decide(situation(familiar: true, over: 15))
        XCTAssertEqual(plan.voice, .urgent, "у своей камеры с превышением молчать нельзя")
    }

    func testFamiliarCameraSpeaksInAlwaysMode() {
        let plan = VoiceDirector.decide(situation(mode: .always, familiar: true))
        XCTAssertNotEqual(plan.voice, .none, "«обо всех» значит обо всех")
    }

    // MARK: - Камера перебивает превышение

    func testOverspeedPhraseIsSuppressedWhenCameraWillSpeak() {
        let speaking = VoiceDirector.decide(situation(over: 20))
        XCTAssertFalse(
            VoiceDirector.announcesOverspeedAlone(cameraAhead: true, plan: speaking),
            "две реплики внахлёст — одна обязательно потеряется")
    }

    func testOverspeedPhraseSoundsWhenThereIsNoCamera() {
        let silent = VoiceDirector.Plan.silent
        XCTAssertTrue(VoiceDirector.announcesOverspeedAlone(cameraAhead: false, plan: silent))
    }

    func testOverspeedPhraseSoundsWhenCameraStaysSilent() {
        // Своя камера молчит — значит про превышение сказать всё-таки надо.
        let familiar = VoiceDirector.decide(situation(familiar: true))
        XCTAssertEqual(familiar.voice, .none)
        XCTAssertTrue(VoiceDirector.announcesOverspeedAlone(cameraAhead: true, plan: familiar))
    }

    /// Предупредить и закричать — разные вещи.
    ///
    /// У камеры порог предупреждения жёстче штрафного, и превышение на +3 в
    /// зоне 60 обязано дойти до водителя голосом о скорости — но не сиреной:
    /// газ ещё можно отпустить. Сирена начинается там, где начинается штраф.
    func testSirenFollowsTheFineNotTheWarningThreshold() {
        XCTAssertNotEqual(VoiceDirector.decide(situation(over: 3)).voice, .urgent,
                          "на +3 ещё можно успеть — это не повод кричать")
        XCTAssertEqual(VoiceDirector.decide(situation(over: 6)).voice, .urgent,
                       "в зоне 60 на 66 камера уже фиксирует")
    }
}

final class CameraFamiliarityTests: XCTestCase {

    private func record(passes: [(id: Int, speed: Double, limit: Int)],
                        daysAgo: Double, now: Date) -> TripRecord {
        let date = now.addingTimeInterval(-daysAgo * 86400)
        return TripRecord(
            id: date.timeIntervalSince1970, startedAt: date, endedAt: date,
            distanceMeters: 5000, maxSpeedKmh: 80,
            passed: passes.map {
                PassedCamera(id: UUID(), cameraID: $0.id, typeRaw: "Стационар радар",
                             location: "Тест", speedKmh: $0.speed, date: date,
                             lat: 41.31, lon: 69.25, limitKmh: $0.limit)
            })
    }

    func testRegularCalmPassesMakeACameraFamiliar() {
        let now = Date()
        let history = (1...CameraFamiliarity.minPasses).map {
            record(passes: [(1, 55, 60)], daysAgo: Double($0), now: now)
        }
        XCTAssertEqual(CameraFamiliarity.familiarIDs(history: history, now: now), [1])
    }

    /// Одно превышение отменяет тишину, и это не строгость ради строгости.
    ///
    /// Камера в зоне 60 фиксирует уже на 66. Молчать у камеры, где водитель
    /// хоть раз ехал с превышением, значит промолчать о штрафе — а цена
    /// молчания здесь выше цены лишней фразы.
    func testOneViolationRevokesFamiliarity() {
        let now = Date()
        var history = (1...CameraFamiliarity.minPasses).map {
            record(passes: [(1, 55, 60)], daysAgo: Double($0), now: now)
        }
        history.append(record(passes: [(1, 90, 60)], daysAgo: 0.5, now: now))
        XCTAssertTrue(CameraFamiliarity.familiarIDs(history: history, now: now).isEmpty,
                      "тишина покупается привычкой ездить спокойно, а не частотой")
    }

    func testTooFewPassesIsNotEnough() {
        let now = Date()
        let history = (1..<CameraFamiliarity.minPasses).map {
            record(passes: [(1, 55, 60)], daysAgo: Double($0), now: now)
        }
        XCTAssertTrue(CameraFamiliarity.familiarIDs(history: history, now: now).isEmpty)
    }

    func testOldPassesFallOutOfTheWindow() {
        let now = Date()
        let history = (1...CameraFamiliarity.minPasses).map {
            record(passes: [(1, 55, 60)],
                   daysAgo: Double(CameraFamiliarity.windowDays + $0), now: now)
        }
        XCTAssertTrue(CameraFamiliarity.familiarIDs(history: history, now: now).isEmpty,
                      "маршрут, которым не ездят месяц, перестаёт быть своим")
    }

    func testUnknownLimitDoesNotBlockFamiliarity() {
        // Без лимита нарушения не выдумываем — проезд считается спокойным.
        let now = Date()
        let history = (1...CameraFamiliarity.minPasses).map { day -> TripRecord in
            let date = now.addingTimeInterval(-Double(day) * 86400)
            return TripRecord(
                id: date.timeIntervalSince1970, startedAt: date, endedAt: date,
                distanceMeters: 5000, maxSpeedKmh: 80,
                passed: [PassedCamera(id: UUID(), cameraID: 2, typeRaw: "Стационар радар",
                                      location: "Тест", speedKmh: 70, date: date,
                                      lat: 41.31, lon: 69.25, limitKmh: nil)])
        }
        XCTAssertEqual(CameraFamiliarity.familiarIDs(history: history, now: now), [2])
    }
}
