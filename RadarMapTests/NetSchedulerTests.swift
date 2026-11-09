//
//  NetSchedulerTests.swift
//  RadarMapTests
//
//  Один такт сети вместо таймера у каждой службы (36B, 28.10): SyncPlan —
//  какие службы идут в окно, RadioWindows — сколько раз просыпалось радио,
//  и замер на фальшивых часах «до/после» для 10 мин поездки и 10 мин
//  открытого экрана без поездки.
//

import XCTest
@testable import RadarMap

final class NetSchedulerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private typealias Job = SyncPlan.Job

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func situation(_ mode: SyncPlan.Mode, at seconds: TimeInterval = 0, speed: Double = 50,
                           screenOn: Bool = true, route: Bool = false, online: Bool = true,
                           remote: TimeInterval? = AppConfig.mobilePollInterval,
                           thermal: PerformanceMode = .full,
                           disabled: Set<Job> = [], due: Set<Job> = []) -> SyncPlan.Situation {
        SyncPlan.Situation(now: at(seconds), mode: mode, isOnline: online, screenOn: screenOn,
                           hasRoute: route, speedKmh: speed, thermal: thermal,
                           remotePollInterval: remote, disabled: disabled, riderDue: due)
    }

    func testPultOnlyWidensTrafficPolling() {
        var s = situation(.trip)
        XCTAssertEqual(SyncPlan.interval(.traffic, s), AppConfig.trafficRefreshInterval)
        s.remoteTrafficInterval = 300
        XCTAssertEqual(SyncPlan.interval(.traffic, s), 300, "перегрузка: пробки реже")
        s.remoteTrafficInterval = 60
        XCTAssertEqual(SyncPlan.interval(.traffic, s), AppConfig.trafficRefreshInterval, "чаще сборки нельзя")
    }

    private func tracks(_ pairs: [Job: TimeInterval], failures: [Job: Int] = [:]) -> [Job: SyncPlan.Track] {
        pairs.reduce(into: [:]) { out, pair in
            out[pair.key] = SyncPlan.Track(lastAttempt: at(pair.value), failures: failures[pair.key] ?? 0)
        }
    }

    // MARK: - Такт

    func testTripTickIsTheMobileCadenceAndTrafficRidesEverySecondTickInTown() {
        // 50 км/ч — город: такт 70 с, как опрос отметок до планировщика.
        XCTAssertEqual(SyncPlan.interval(.mobile, situation(.trip, speed: 50)), AppConfig.mobilePollTripCity)
        // Пробки ходили 70 с назад — на этом такте их нет, на следующем есть.
        let tick1 = SyncPlan.plan(situation(.trip, at: 140), tracks: tracks([.mobile: 70, .traffic: 70]), trigger: .tick)
        XCTAssertEqual(tick1.jobs, [.mobile], "пробкам рано: 70 с из 150")
        let tick2 = SyncPlan.plan(situation(.trip, at: 140), tracks: tracks([.mobile: 70, .traffic: 0]), trigger: .tick)
        XCTAssertEqual(tick2.jobs, [.mobile, .traffic], "140 из 150 — к ближайшему такту, а не своим разом")
    }

    func testFreshnessOfDriverReportsInTripIsUnchanged() {
        // Свежесть отметок в поездке — та же лестница PollSchedule.
        XCTAssertEqual(SyncPlan.interval(.mobile, situation(.trip, speed: 110)), AppConfig.mobilePollTripFast)
        XCTAssertEqual(SyncPlan.interval(.mobile, situation(.trip, speed: 0)), AppConfig.mobilePollTripIdle)
        // На трассе к уже открытому окну отметки прыгают не раньше чем за
        // четверть интервала: 40 с не превращаются в 30.
        let early = SyncPlan.plan(situation(.trip, at: 100, speed: 110),
                                  tracks: tracks([.mobile: 70, .traffic: 0]), trigger: .tick)
        XCTAssertEqual(early.jobs, [], "30 с из 40 — ещё рано, окно не открываем")
        let ok = SyncPlan.plan(situation(.trip, at: 110, speed: 110),
                               tracks: tracks([.mobile: 70, .traffic: 0]), trigger: .tick)
        XCTAssertEqual(ok.jobs.first, .mobile)
    }

    func testOpenScreenWithoutTripIsOneTickForBoth() {
        let s = situation(.watching)
        XCTAssertEqual(SyncPlan.interval(.mobile, s), AppConfig.netWatchInterval)
        XCTAssertEqual(SyncPlan.interval(.traffic, s), AppConfig.netWatchInterval,
                       "один ритм на экране: отметки и пробки вместе")
        let plan = SyncPlan.plan(situation(.watching, at: 150), tracks: tracks([.mobile: 0, .traffic: 0]),
                                 trigger: .tick)
        XCTAssertEqual(plan.jobs, [.mobile, .traffic])
    }

    /// Машина подключена, поездки нет (ручной старт или до автостарта), едем
    /// (40I): отметки — лестницей поездки, а не тактом экрана 150 с; пробки
    /// идут в те же окна. Стоя — верхняя ступень, тот же такт экрана.
    func testConnectedCarWithoutTripPollsOnTheTripLadder() {
        func car(_ speed: Double, at seconds: TimeInterval = 0,
                 remote: TimeInterval? = AppConfig.mobilePollInterval) -> SyncPlan.Situation {
            var s = situation(.watching, at: seconds, speed: speed, remote: remote)
            s.carConnected = true
            return s
        }
        XCTAssertEqual(SyncPlan.interval(.mobile, car(50)), AppConfig.mobilePollTripCity)
        XCTAssertEqual(SyncPlan.interval(.mobile, car(110)), AppConfig.mobilePollTripFast)
        XCTAssertEqual(SyncPlan.interval(.mobile, car(0)), AppConfig.mobilePollTripIdle)
        XCTAssertEqual(SyncPlan.interval(.mobile, situation(.watching, speed: 50)), AppConfig.netWatchInterval,
                       "телефон без машины — прежний такт экрана")
        XCTAssertEqual(SyncPlan.interval(.mobile, car(110, remote: 600)), 600, "разреженный пультом не сужаем")
        // Пульт ужал до 60 с — с машиной не реже, чем без неё; на трассе
        // лестница чаще — она и остаётся.
        XCTAssertEqual(SyncPlan.interval(.mobile, car(0, remote: 60)), 60)
        XCTAssertEqual(SyncPlan.interval(.mobile, car(50, remote: 60)), 60)
        XCTAssertEqual(SyncPlan.interval(.mobile, car(110, remote: 60)), AppConfig.mobilePollTripFast)
        var hot = car(0, remote: 60)
        hot.thermal = .reduced
        XCTAssertEqual(SyncPlan.interval(.mobile, hot), 60 * AppConfig.mobilePollThermalFactor,
                       "на жаре — как у экрана без машины")
        XCTAssertEqual(SyncPlan.interval(.traffic, car(50)), AppConfig.trafficRefreshInterval)
        // Город: отметки 70 с назад — окно открывается; пробкам срок — едут в нём.
        let plan = SyncPlan.plan(car(50, at: 150), tracks: tracks([.mobile: 80, .traffic: 0]), trigger: .tick)
        XCTAssertEqual(plan.jobs, [.mobile, .traffic])
        let early = SyncPlan.plan(car(50, at: 100), tracks: tracks([.mobile: 80, .traffic: 0]), trigger: .tick)
        XCTAssertEqual(early.jobs, [], "20 с из 70 — рано")
    }

    func testIdleHasNoTimerAndOnlyRareFilesOnActivation() {
        let idle = situation(.idle, screenOn: false, due: [.remoteConfig, .roadWeather, .cameraDB])
        let tick = SyncPlan.plan(idle, tracks: [:], trigger: .tick)
        XCTAssertNil(tick.nextCheck, "без поездки и экрана своих тактов нет")
        XCTAssertEqual(tick.jobs, [])
        let activation = SyncPlan.plan(idle, tracks: [:], trigger: .activation)
        XCTAssertEqual(activation.jobs, [.remoteConfig, .cameraDB],
                       "погода на перевалах нужна тому, кто смотрит или едет")
    }

    func testStepIsShortEnoughToNoticeTheCarMovingAgain() {
        // Встали: интервал 150 — но цикл смотрит не реже шага, иначе проспал
        // бы, что машина уже полторы минуты как едет по трассе.
        let plan = SyncPlan.plan(situation(.trip, at: 10, speed: 0), tracks: tracks([.mobile: 0, .traffic: 0]),
                                 trigger: .tick)
        XCTAssertEqual(plan.nextCheck, AppConfig.netSchedulerStepSeconds)
        let soon = SyncPlan.plan(situation(.trip, at: 65, speed: 50), tracks: tracks([.mobile: 0, .traffic: 0]),
                                 trigger: .tick)
        XCTAssertEqual(soon.nextCheck ?? 0, 5, accuracy: 0.001, "к сроку ведущей, а не шагом мимо него")
    }

    /// Без связи попыток нет, срок ведущей не сдвигается: цикл не должен
    /// просыпаться каждую секунду всё время, пока связи нет.
    func testOfflineLoopSleepsAFullStep() {
        var offline = situation(.trip, at: 600, speed: 50)
        offline.isOnline = false
        let plan = SyncPlan.plan(offline, tracks: tracks([.mobile: 0, .traffic: 0]), trigger: .tick)
        XCTAssertEqual(plan.jobs, [])
        XCTAssertEqual(plan.nextCheck, AppConfig.netSchedulerStepSeconds)
        var never = situation(.watching, at: 600)
        never.isOnline = false
        XCTAssertEqual(SyncPlan.plan(never, tracks: [:], trigger: .tick).nextCheck,
                       AppConfig.netSchedulerStepSeconds, "и когда попыток не было вовсе")
    }

    // MARK: - Пульт

    func testRemoteWidenedIntervalIsNeverNarrowed() {
        XCTAssertEqual(SyncPlan.interval(.mobile, situation(.trip, speed: 110, remote: 600)), 600)
        XCTAssertEqual(SyncPlan.interval(.mobile, situation(.watching, remote: 600)), 600)
        // Пульт разредил опрос, а пробкам срок — окно ради пробок не тащит
        // отметки раньше срока пульта.
        let plan = SyncPlan.plan(situation(.watching, at: 300, remote: 600),
                                 tracks: tracks([.mobile: 0, .traffic: 150]), trigger: .tick)
        XCTAssertEqual(plan.jobs, [.traffic])
    }

    func testRemoteDisabledFeatureIsNotRequestedEvenOnTripStart() {
        let s = situation(.trip, disabled: [.mobile, .roadWeather], due: [.roadWeather, .remoteConfig])
        let plan = SyncPlan.plan(s, tracks: [:], trigger: .tripStart)
        XCTAssertFalse(plan.jobs.contains(.mobile))
        XCTAssertFalse(plan.jobs.contains(.roadWeather))
        XCTAssertEqual(plan.jobs.first, .remoteConfig, "пульт — первым в окне")
    }

    func testTripStartForcesDriverReportsEvenRightAfterAPoll() {
        let plan = SyncPlan.plan(situation(.trip, at: 10), tracks: tracks([.mobile: 0, .traffic: 0]),
                                 trigger: .tripStart)
        XCTAssertEqual(plan.jobs, [.mobile], "отметка двухминутной давности нужна сейчас")
    }

    // MARK: - Связь и сбои

    func testOfflineSpendsNoWindow() {
        for trigger in [SyncPlan.Trigger.tick, .activation, .tripStart, .background] {
            let plan = SyncPlan.plan(situation(.trip, online: false, due: [.remoteConfig]), tracks: [:],
                                     trigger: trigger)
            XCTAssertEqual(plan.jobs, [], "\(trigger)")
        }
    }

    // MARK: - Своя очередь отметок (ловец багов, 39)

    func testReportQueueLeavesWithoutTripOnActivationOnlineAndBackground() {
        // «Отправлю позже» → автостоп → связь вернулась с телефоном в кармане:
        // очередь уходит без поездки и экрана, а не ждёт следующего открытия.
        let idle = situation(.idle, screenOn: false, due: [.reports])
        for trigger in [SyncPlan.Trigger.activation, .online, .background] {
            XCTAssertEqual(SyncPlan.plan(idle, tracks: [:], trigger: trigger).jobs, [.reports], "\(trigger)")
        }
        XCTAssertEqual(SyncPlan.plan(idle, tracks: [:], trigger: .tick).jobs, [], "своих тактов без поездки нет")
    }

    func testReportQueueRidesTheTripTick() {
        let plan = SyncPlan.plan(situation(.trip, at: 140, due: [.reports]),
                                 tracks: tracks([.mobile: 70, .traffic: 70]), trigger: .tick)
        XCTAssertEqual(plan.jobs, [.mobile, .reports])
    }

    func testReportQueueIsOffWhenCrowdsourcingIs() {
        let s = situation(.idle, screenOn: false, disabled: [.mobile, .reports], due: [.reports])
        XCTAssertEqual(SyncPlan.plan(s, tracks: [:], trigger: .online).jobs, [])
    }

    func testReturningNetworkForgivesReportFailures() {
        // Три таймаута при «связь есть»: пауза 70 × 8. Связь пропала и
        // вернулась — пауза мерила мёртвую сеть, опрос и досылка идут сразу.
        let failed = tracks([.mobile: 0, .traffic: 0, .reports: 0],
                            failures: [.mobile: 3, .reports: 2, .traffic: 1])
        let s = situation(.trip, at: 100, due: [.reports])
        XCTAssertEqual(SyncPlan.plan(s, tracks: failed, trigger: .online).jobs, [],
                       "без прощения: пауза ведущих и попутной")
        let forgiven = SyncPlan.forgiven(failed, trigger: .online)
        XCTAssertEqual(forgiven[.mobile]?.failures, 0)
        XCTAssertEqual(forgiven[.reports]?.failures, 0)
        XCTAssertEqual(SyncPlan.plan(s, tracks: forgiven, trigger: .online).jobs, [.mobile, .reports])
        XCTAssertEqual(SyncPlan.forgiven(failed, trigger: .activation)[.mobile]?.failures, 0)
    }

    func testTimerTickForgivesNothing() {
        let failed = tracks([.mobile: 0, .cameraDB: 0], failures: [.mobile: 3, .cameraDB: 2])
        XCTAssertEqual(SyncPlan.forgiven(failed, trigger: .tick), failed)
        XCTAssertEqual(SyncPlan.forgiven(failed, trigger: .background), failed)
        XCTAssertEqual(SyncPlan.forgiven(failed, trigger: .online)[.cameraDB]?.failures, 2,
                       "редкие файлы прощение не трогает: их сбой — сервер, а не сеть")
    }

    func testDriverFailurePausesOnlyThatService() {
        // Отметки дважды не ответили: пауза 70 × 4 = 280 с; пробки идут своим сроком.
        let t = tracks([.mobile: 0, .traffic: 0], failures: [.mobile: 2])
        let plan = SyncPlan.plan(situation(.trip, at: 150), tracks: t, trigger: .tick)
        XCTAssertEqual(plan.jobs, [.traffic])
        XCTAssertEqual(SyncPlan.driverPause(interval: 70, failures: 2), 280)
        XCTAssertEqual(SyncPlan.driverPause(interval: 70, failures: 9), 560, "потолок 2^3")
        let later = SyncPlan.plan(situation(.trip, at: 280), tracks: t, trigger: .tick)
        XCTAssertTrue(later.jobs.contains(.mobile))
    }

    func testRiderFailureBacksOffAndHeavyBacksOffLonger() {
        XCTAssertEqual(SyncPlan.riderPause(.remoteConfig, failures: 1), 300)
        XCTAssertEqual(SyncPlan.riderPause(.remoteConfig, failures: 3), 1200)
        XCTAssertEqual(SyncPlan.riderPause(.remoteConfig, failures: 30), AppConfig.netRiderRetryMaxSeconds)
        XCTAssertEqual(SyncPlan.riderPause(.speedLimits, failures: 1), AppConfig.netHeavyRetryBaseSeconds)
        XCTAssertEqual(SyncPlan.riderPause(.speedLimits, failures: 30), AppConfig.netHeavyRetryMaxSeconds)
        // Пульт не ответил 100 с назад — в такте поездки его нет.
        var t = tracks([.mobile: 0, .traffic: 0, .remoteConfig: 100], failures: [.remoteConfig: 1])
        let plan = SyncPlan.plan(situation(.trip, at: 200, due: [.remoteConfig]), tracks: t, trigger: .tick)
        XCTAssertFalse(plan.jobs.contains(.remoteConfig))
        t[.remoteConfig]?.lastAttempt = at(-200)
        let later = SyncPlan.plan(situation(.trip, at: 200, due: [.remoteConfig]), tracks: t, trigger: .tick)
        XCTAssertEqual(later.jobs.first, .remoteConfig)
    }

    // MARK: - Попутные

    func testRidersNeverOpenAWindowWhileDriversExist() {
        let s = situation(.trip, at: 30, due: [.roadWeather, .hotspots])
        let plan = SyncPlan.plan(s, tracks: tracks([.mobile: 0, .traffic: 0]), trigger: .tick)
        XCTAssertEqual(plan.jobs, [], "погода и треноги ждут ближайшего такта отметок")
        let ride = SyncPlan.plan(situation(.trip, at: 70, due: [.roadWeather, .hotspots]),
                                 tracks: tracks([.mobile: 0, .traffic: 0]), trigger: .tick)
        XCTAssertEqual(ride.jobs, [.mobile, .roadWeather, .hotspots])
    }

    func testRidersOpenTheWindowThemselvesWhenBothDriversAreOff() {
        let s = situation(.watching, disabled: [.mobile, .traffic], due: [.roadWeather])
        XCTAssertEqual(SyncPlan.plan(s, tracks: [:], trigger: .tick).jobs, [.roadWeather])
    }

    func testRidersDoNotRideAPausedDriverWindow() {
        // Обе ведущие на паузе после сбоя — радио ради одних попутных не будим.
        let t = tracks([.mobile: 0, .traffic: 0], failures: [.mobile: 3, .traffic: 3])
        let plan = SyncPlan.plan(situation(.trip, at: 100, due: [.roadWeather]), tracks: t, trigger: .tick)
        XCTAssertEqual(plan.jobs, [])
    }

    func testSystemBackgroundWindowTakesOnlyLightFiles() {
        let s = situation(.idle, screenOn: false,
                          due: [.remoteConfig, .cameraDB, .hotspots, .speedLimits, .roads, .laneOverlay,
                                .offlineGraph, .trafficProfile])
        let plan = SyncPlan.plan(s, tracks: [:], trigger: .background)
        XCTAssertEqual(plan.jobs, [.remoteConfig, .cameraDB, .hotspots])
    }

    // MARK: - Окна радио

    func testRadioWindowsCountWakesNotRequests() {
        var radio = RadioWindows(tail: 10)
        radio.began(at: at(0)); radio.began(at: at(0.1))      // одно окно, два запроса
        radio.ended(at: at(0.4)); radio.ended(at: at(0.5))
        radio.began(at: at(5)); radio.ended(at: at(5.3))       // хвост ещё горячий
        radio.began(at: at(70)); radio.ended(at: at(70.3))     // новое пробуждение
        XCTAssertEqual(radio.requests, 4)
        XCTAssertEqual(radio.windows, 2)
    }

    // MARK: - Замер на фальшивых часах (до / после)

    /// Запросы службы за один её выход в сеть.
    private func requests(_ job: Job, trip: Bool) -> Int {
        switch job {
        case .mobile: 2               // api/mobile + api/road
        case .traffic: trip ? 2 : 1   // в поездке — ещё POST кусков
        default: 1
        }
    }

    private struct Tally { var windows = 0; var requests = 0 }

    private func count(_ starts: [(TimeInterval, Int)]) -> Tally {
        var radio = RadioWindows(tail: AppConfig.radioTailSeconds)
        for (start, n) in starts.sorted(by: { $0.0 < $1.0 }) {
            for _ in 0..<n { radio.began(at: at(start)) }
            for _ in 0..<n { radio.ended(at: at(start + 0.4)) }
        }
        return Tally(windows: radio.windows, requests: radio.requests)
    }

    /// До 28.10: свои циклы. Отметки — шаг 20 с, опрос при «прошло ≥
    /// интервала» и затем «радио проснулось» для пробок (≥ интервал − 30);
    /// пробки — свой цикл с шагом 15 с; погода — свой сон до срока (30 мин);
    /// профиль пробок — цикл 5 мин с проверкой срока (6 ч, первый раз сразу).
    private func simulateOld(duration: TimeInterval, trip: Bool, mobileInterval: TimeInterval,
                             trafficInterval: TimeInterval, eta: Bool = false) -> Tally {
        var starts: [(TimeInterval, Int)] = []
        var mobileLast = -TimeInterval.infinity, trafficLast = -TimeInterval.infinity
        var nextMobileCheck: TimeInterval = 0, nextTrafficCheck: TimeInterval = 0
        var weatherDue: TimeInterval = 0, profileFetched = false
        var t: TimeInterval = 0
        while t < duration {
            if t >= nextMobileCheck {
                if t - mobileLast >= mobileInterval {
                    mobileLast = t
                    starts.append((t, requests(.mobile, trip: trip)))
                    if t - trafficLast >= trafficInterval - AppConfig.radioJoinSlackSeconds {
                        trafficLast = t
                        starts.append((t, requests(.traffic, trip: trip)))
                    }
                }
                nextMobileCheck = t + min(mobileInterval, 20)
            }
            if t >= nextTrafficCheck {
                if t - trafficLast >= trafficInterval {
                    trafficLast = t
                    starts.append((t, requests(.traffic, trip: trip)))
                }
                nextTrafficCheck = t + 15
            }
            if t >= weatherDue { starts.append((t, 1)); weatherDue = t + 1800 }
            if !profileFetched { starts.append((t, 1)); profileFetched = true }
            // «Поделиться прибытием»: свой цикл, POST раз в минуту (в городе
            // 500 м остатка проезжаются за 36 с — шлёт почти каждый раз).
            if eta, Int(t) % Int(AppConfig.etaShareIntervalSeconds) == 0 { starts.append((t, 1)) }
            t += 1
        }
        return count(starts)
    }

    /// После: SyncPlan и исполнитель на тех же часах.
    private func simulateNew(duration: TimeInterval, mode: SyncPlan.Mode, speed: Double,
                             screenOn: Bool, start: SyncPlan.Trigger, eta: Bool = false) -> Tally {
        var starts: [(TimeInterval, Int)] = []
        var tracks: [Job: SyncPlan.Track] = [:]
        var weatherDue: TimeInterval = 0, profileDue = true
        func s(_ t: TimeInterval) -> SyncPlan.Situation {
            var due: Set<Job> = []
            if t >= weatherDue { due.insert(.roadWeather) }
            if profileDue { due.insert(.trafficProfile) }
            if eta { due.insert(.etaShare) }   // цифры сдвигаются к каждому такту
            return situation(mode, at: t, speed: speed, screenOn: screenOn, due: due)
        }
        func window(_ t: TimeInterval, _ trigger: SyncPlan.Trigger) {
            for job in SyncPlan.plan(s(t), tracks: tracks, trigger: trigger).jobs {
                tracks[job] = SyncPlan.Track(lastAttempt: at(t), failures: 0)
                starts.append((t, requests(job, trip: mode == .trip)))
                if job == .roadWeather { weatherDue = t + 1800 }
                if job == .trafficProfile { profileDue = false }
            }
        }
        window(0, start)
        var t: TimeInterval = 0
        while t < duration {
            window(t, .tick)
            t += SyncPlan.plan(s(t), tracks: tracks, trigger: .tick).nextCheck ?? AppConfig.netSchedulerStepSeconds
        }
        return count(starts)
    }

    func testMeasuredTenMinutesOfTripAndOfOpenScreen() {
        let ten: TimeInterval = 600
        // Поездка по городу, экран погашен, без маршрута (телефон в кармане).
        let tripOld = simulateOld(duration: ten, trip: true, mobileInterval: AppConfig.mobilePollTripCity,
                                  trafficInterval: AppConfig.trafficQuietInterval)
        let tripNew = simulateNew(duration: ten, mode: .trip, speed: 50, screenOn: false, start: .tripStart)
        // Поездка по городу с экраном (карта на держателе) — пробки до 28.10 раз в 120 с.
        let screenTripOld = simulateOld(duration: ten, trip: true, mobileInterval: AppConfig.mobilePollTripCity,
                                        trafficInterval: 120)
        let screenTripNew = simulateNew(duration: ten, mode: .trip, speed: 50, screenOn: true, start: .tripStart)
        // Трасса, экран на держателе.
        let highwayOld = simulateOld(duration: ten, trip: true, mobileInterval: AppConfig.mobilePollTripFast,
                                     trafficInterval: 120)
        let highwayNew = simulateNew(duration: ten, mode: .trip, speed: 110, screenOn: true, start: .tripStart)
        // Поездка по городу по маршруту и с живой ссылкой прибытия.
        let etaOld = simulateOld(duration: ten, trip: true, mobileInterval: AppConfig.mobilePollTripCity,
                                 trafficInterval: 120, eta: true)
        let etaNew = simulateNew(duration: ten, mode: .trip, speed: 50, screenOn: true, start: .tripStart, eta: true)
        // Открытый экран без поездки.
        let watchOld = simulateOld(duration: ten, trip: false, mobileInterval: AppConfig.mobilePollInterval,
                                   trafficInterval: 120)
        let watchNew = simulateNew(duration: ten, mode: .watching, speed: 0, screenOn: true, start: .activation)

        for (name, old, new) in [("поездка, экран погашен", tripOld, tripNew),
                                 ("поездка, экран на держателе", screenTripOld, screenTripNew),
                                 ("трасса, экран на держателе", highwayOld, highwayNew),
                                 ("поездка со ссылкой прибытия", etaOld, etaNew),
                                 ("экран без поездки", watchOld, watchNew)] {
            print("ЗАМЕР 36B \(name): окна \(old.windows) → \(new.windows), запросы \(old.requests) → \(new.requests)")
            XCTAssertLessThanOrEqual(new.windows, old.windows, name)
        }
        XCTAssertLessThan(screenTripNew.windows, screenTripOld.windows)
        XCTAssertLessThan(watchNew.windows, watchOld.windows)
        XCTAssertLessThan(etaNew.windows, etaOld.windows)
    }
}
