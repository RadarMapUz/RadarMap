//
//  CarPlayScenarioConnectTests.swift
//  RadarMapTests
//
//  Подключение машины и фаза маршрута — цепочкой решений, как на живом
//  подключении: CarPlayRootWatch решает, когда корень на экране, после этого
//  NavigationFlow решает выбор и ведение, CarPlayTripPreview — порог «на
//  ходу». Каждый шаг — настоящая чистая функция; между шагами переносится
//  только то, что делегат сцены хранит у себя (rootShown, rootSet,
//  rootRetried, flowPhase, isPreviewing). Строки матрицы —
//  docs/carplay_test_matrix.md, раздел «Подключение» и «Маршрут».
//

import XCTest
@testable import RadarMap

final class CarPlayScenarioConnectTests: XCTestCase {

    /// Состояние одного подключения — ровно поля CarPlaySceneDelegate, по
    /// которым принимаются решения, и те же правила их смены.
    private struct Connection {
        var rootShown = false
        var rootSet: Bool?
        var rootRetried = false
        var flowPhase: NavigationFlow.Phase?
        var previewing = false
        /// Сколько раз корень ставили (didConnect — первый).
        var rootSets = 1
        var choices: [NavigationFlow.CarChoice] = []

        /// Ответ системы на setRootTemplate.
        mutating func rootConfirmed(_ ok: Bool) { rootSet = ok }

        /// Сцена активна, пауза на анимацию прошла (applyRootWatch).
        @discardableResult
        mutating func checkRoot(timedOut: Bool) -> CarPlayRootWatch.Action {
            let action = CarPlayRootWatch.action(rootShown: rootShown, rootSet: rootSet,
                                                 retried: rootRetried, timedOut: timedOut)
            switch action {
            case .none: break
            case .markShown: rootShown = true
            case .setAgain:
                rootRetried = true
                rootSet = nil
                rootSets += 1
            }
            return action
        }

        /// syncChoice: решения о выборе — только на показанном корне.
        @discardableResult
        mutating func sync(route: Bool, trip: Bool, building: Bool = false,
                           speedKmh: Double = 0) -> NavigationFlow.CarChoice {
            guard rootShown else { return .none }
            let phase = NavigationFlow.phase(hasRoute: route, isTripActive: trip)
            let moving = !CarPlayTripPreview.shouldPreview(speedKmh: speedKmh)
            let decision = NavigationFlow.carChoice(from: flowPhase, to: phase, showing: previewing,
                                                    building: building, moving: moving)
            if !building { flowPhase = phase }
            switch decision {
            case .none: break
            case .show: previewing = true
            case .close: previewing = false
            }
            choices.append(decision)
            return decision
        }

        func guides(route: Bool, trip: Bool) -> Bool {
            NavigationFlow.carGuides(phase: NavigationFlow.phase(hasRoute: route, isTripActive: trip),
                                     choosing: previewing)
        }
    }

    // MARK: - Подключение

    /// П-1: приложение на переднем плане, на экране машины — мы. Корень
    /// подтверждён, templateDidAppear пришёл или нет — корень признан один раз,
    /// повторной установки нет.
    func testForegroundConnectShowsTheRootOnce() {
        var car = Connection()
        car.rootConfirmed(true)
        XCTAssertEqual(car.checkRoot(timedOut: false), .markShown)
        XCTAssertEqual(car.checkRoot(timedOut: true), .none, "второй проверки нет — корень уже показан")
        XCTAssertEqual(car.rootSets, 1)
    }

    /// П-2 / П-3: машина подключилась, пока на её экране Яндекс или главный
    /// экран (сцена в фоне), шла поездка по маршруту. Ведение уже идёт
    /// (guidingAtConnect), затем водитель открывает RadarMap: корень признан
    /// без templateDidAppear (carplay10), ведение остаётся, выбор не всплывает
    /// поверх идущего маршрута.
    func testBackgroundConnectDuringGuidingThenDriverOpensRadarMap() {
        let guidingAtConnect = NavigationFlow.phase(hasRoute: true, isTripActive: true) == .guiding
        XCTAssertTrue(guidingAtConnect, "фон: сессия разрешена только при ведении на момент подключения")
        var car = Connection()
        car.rootConfirmed(true)
        // Пока сцена в фоне, решений о выборе нет: flowPhase остаётся nil.
        XCTAssertEqual(car.sync(route: true, trip: true), .none)
        XCTAssertNil(car.flowPhase)
        // Водитель открыл RadarMap: сцена активна, templateDidAppear не пришёл.
        XCTAssertEqual(car.checkRoot(timedOut: false), .markShown)
        XCTAssertEqual(car.sync(route: true, trip: true, speedKmh: 50), .none,
                       "ведение при подключении — выбор не открывается")
        XCTAssertTrue(car.guides(route: true, trip: true))
        XCTAssertEqual(car.rootSets, 1, "подтверждённый корень заново не ставится")
    }

    /// П-4: несколько раз туда-обратно (Яндекс ↔ RadarMap) без
    /// templateDidAppear. Подтверждённый корень не ставится заново ни разу —
    /// повторная установка сбрасывала всё поверх него каждые 3 с (2.2.14).
    func testRepeatedForegroundCyclesNeverResetAConfirmedRoot() {
        var car = Connection()
        car.rootConfirmed(true)
        for cycle in 0..<6 {
            let first = car.checkRoot(timedOut: false)
            let late = car.checkRoot(timedOut: true)
            XCTAssertEqual(first, cycle == 0 ? .markShown : .none, "показ \(cycle)")
            XCTAssertEqual(late, .none, "показ \(cycle)")
        }
        XCTAssertEqual(car.rootSets, 1)
    }

    /// П-5: установка корня потерялась (ответа системы нет). Ждём таймаут,
    /// ставим заново ОДИН раз за подключение; новое подключение — снова может.
    func testLostRootIsRetriedOncePerConnection() {
        var car = Connection()
        XCTAssertEqual(car.checkRoot(timedOut: false), .none, "до таймаута — ждём")
        XCTAssertEqual(car.checkRoot(timedOut: true), .setAgain)
        // Повтор тоже не подтвердился — больше не мигаем экраном.
        for _ in 0..<5 { XCTAssertEqual(car.checkRoot(timedOut: true), .none) }
        XCTAssertEqual(car.rootSets, 2)
        XCTAssertFalse(car.rootShown)
        // Повтор подтвердился позже — корень признан.
        car.rootConfirmed(true)
        XCTAssertEqual(car.checkRoot(timedOut: false), .markShown)

        // Отключили и подключили (моргание кабеля) — счёт повторов с нуля.
        var next = Connection()
        XCTAssertEqual(next.checkRoot(timedOut: true), .setAgain)
    }

    /// П-6: отключение и подключение посреди поездки по маршруту. Новое
    /// подключение начинает с flowPhase = nil — и всё равно не открывает
    /// выбор поверх ведения, сессия продолжается.
    func testReconnectMidTripKeepsGuidingWithoutAChoice() {
        var before = Connection()
        before.rootConfirmed(true)
        before.checkRoot(timedOut: false)
        before.sync(route: true, trip: true, speedKmh: 60)
        XCTAssertTrue(before.guides(route: true, trip: true))

        var after = Connection()
        after.rootConfirmed(true)
        after.checkRoot(timedOut: false)
        XCTAssertEqual(after.sync(route: true, trip: true, speedKmh: 60), .none)
        XCTAssertFalse(after.previewing)
        XCTAssertTrue(after.guides(route: true, trip: true))
    }

    /// П-7: подключились стоя, а на телефоне уже построен маршрут (выбор) —
    /// в машине тот же выбор; подключились на ходу — выбора нет, решает телефон.
    func testConnectWithAPhoneRouteParkedAndMoving() {
        var parked = Connection()
        parked.rootConfirmed(true)
        parked.checkRoot(timedOut: false)
        XCTAssertEqual(parked.sync(route: true, trip: false, speedKmh: 0), .show)
        XCTAssertFalse(parked.guides(route: true, trip: false), "до «Поехали» сессии нет")

        var moving = Connection()
        moving.rootConfirmed(true)
        moving.checkRoot(timedOut: false)
        XCTAssertEqual(moving.sync(route: true, trip: false, speedKmh: 40), .none)
        XCTAssertFalse(moving.guides(route: true, trip: false))
    }

    // MARK: - Маршрут

    /// М-2: маршрут построен на телефоне стоя → выбор в машине; «Поехали» на
    /// телефоне → выбор в машине закрывается, начинается ведение.
    func testPhoneRouteThenGoOnThePhone() {
        var car = Connection()
        car.rootConfirmed(true)
        car.checkRoot(timedOut: false)
        XCTAssertEqual(car.sync(route: false, trip: false), .none)
        XCTAssertEqual(car.sync(route: true, trip: false, building: true), .none, "пока строится — ничего")
        XCTAssertEqual(car.sync(route: true, trip: false), .show)
        XCTAssertEqual(car.sync(route: true, trip: true), .close)
        XCTAssertTrue(car.guides(route: true, trip: true))
    }

    /// М-5: выбор на экране машины, водитель тронулся без «Поехали» — выбор
    /// принимается только после устойчивого движения (MovingWatch), а не от
    /// одного рывка на светофоре.
    func testMovingOffDuringTheChoiceAcceptsItOnlyWhenSustained() {
        var watch = CarPlayTripPreview.MovingWatch()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let kmh = AppConfig.carPlayPreviewAutoStartKmh + 5
        XCTAssertFalse(watch.update(speedKmh: kmh, at: start))
        XCTAssertFalse(watch.update(speedKmh: 3, at: start.addingTimeInterval(1)), "встали — счёт сначала")
        XCTAssertFalse(watch.update(speedKmh: kmh, at: start.addingTimeInterval(2)))
        XCTAssertFalse(watch.update(speedKmh: kmh,
                                    at: start.addingTimeInterval(1 + AppConfig.carPlayPreviewAutoStartSeconds)))
        XCTAssertTrue(watch.update(speedKmh: kmh,
                                   at: start.addingTimeInterval(2 + AppConfig.carPlayPreviewAutoStartSeconds)))
        // Принятый выбор = поездка началась: фаза ведения, выбор закрыт машиной.
        var car = Connection()
        car.rootConfirmed(true)
        car.checkRoot(timedOut: false)
        car.sync(route: true, trip: false)
        car.previewing = false   // endPreview(start: true) — выбор закрыт самой машиной
        XCTAssertEqual(car.sync(route: true, trip: true, speedKmh: kmh), .none)
        XCTAssertTrue(car.guides(route: true, trip: true))
    }

    /// М-4: «Куда» стоя без поездки — машина строит сама: промежуточная фаза
    /// (маршрут есть, поездки нет) выбор не перебивает, свой выбор машины
    /// поверх идущей поездки (стоим на светофоре) не закрывается.
    func testCarOwnRouteOverARunningTrip() {
        var car = Connection()
        car.rootConfirmed(true)
        car.checkRoot(timedOut: false)
        car.sync(route: false, trip: true, speedKmh: 0)
        car.previewing = true   // showPreview: свой выбор машины
        XCTAssertEqual(car.sync(route: true, trip: true, building: true), .none)
        XCTAssertEqual(car.sync(route: true, trip: true), .none, "сценарий D1: свой выбор не мигает")
        XCTAssertTrue(car.previewing)
        XCTAssertFalse(car.guides(route: true, trip: true), "сессия — только после «Поехали»")
        car.previewing = false   // «Поехали» в машине
        XCTAssertTrue(car.guides(route: true, trip: true))
    }

    /// М-10: ручной «Стоп» (машина, телефон, Siri) — конец ведения целиком:
    /// маршрут снят, выбор не всплывает, сессии нет.
    func testManualStopEndsGuidingEverywhere() {
        var car = Connection()
        car.rootConfirmed(true)
        car.checkRoot(timedOut: false)
        car.sync(route: true, trip: true, speedKmh: 30)
        let keeps = NavigationFlow.keepsRoute(after: .manual)
        XCTAssertFalse(keeps)
        XCTAssertEqual(car.sync(route: keeps, trip: false), .none)
        XCTAssertFalse(car.previewing)
        XCTAssertFalse(car.guides(route: keeps, trip: false))
    }

    /// М-11: автостоп в пути (долгая стоянка) — маршрут остаётся, стоя в
    /// машине выбор с «Поехали»; автостарт — выбор закрывается, ведение
    /// продолжается к той же цели.
    func testAutoStopThenAutoStartResumesTheSameRoute() {
        var car = Connection()
        car.rootConfirmed(true)
        car.checkRoot(timedOut: false)
        car.sync(route: true, trip: true, speedKmh: 30)
        let keeps = NavigationFlow.keepsRoute(after: .auto)
        XCTAssertTrue(keeps)
        XCTAssertEqual(car.sync(route: keeps, trip: false, speedKmh: 0), .show)
        XCTAssertFalse(car.guides(route: true, trip: false))
        XCTAssertEqual(car.sync(route: true, trip: true, speedKmh: 20), .close, "автостарт закрывает выбор")
        XCTAssertTrue(car.guides(route: true, trip: true))
    }

    /// М-11б: «я пассажир» на ходу — маршрут остаётся, но в машине ни выбора,
    /// ни ведения: автостарт не делает пассажира водителем (аудит 19.10).
    func testPassengerOnTheMoveGetsNeitherChoiceNorGuidance() {
        var car = Connection()
        car.rootConfirmed(true)
        car.checkRoot(timedOut: false)
        car.sync(route: true, trip: true, speedKmh: 50)
        XCTAssertTrue(NavigationFlow.keepsRoute(after: .passenger))
        XCTAssertEqual(car.sync(route: true, trip: false, speedKmh: 50), .none)
        XCTAssertFalse(car.guides(route: true, trip: false))
    }

    /// М-7б: маршрут с телефона пришёл на ходу — выбора нет. Машина встала:
    /// полноэкранный выбор по-прежнему не всплывает (остановка — не смена фазы),
    /// а после устойчивой стоянки решение — предложить его баннером, один раз
    /// (CarPlayRouteChoiceOffer; решение владельца 06.11, до 51 выбора не было
    /// вовсе и начать маршрут из машины можно было только заново через «Куда»).
    func testPhoneRouteOnTheMoveOffersAChoiceOnceAfterASteadyStop() {
        var car = Connection()
        car.rootConfirmed(true)
        car.checkRoot(timedOut: false)
        car.sync(route: false, trip: false, speedKmh: 40)
        XCTAssertEqual(car.sync(route: true, trip: false, speedKmh: 40), .none)
        XCTAssertEqual(car.sync(route: true, trip: false, speedKmh: 0), .none,
                       "остановка — не смена фазы, полноэкранного выбора нет")
        XCTAssertFalse(car.previewing)

        var offer = CarPlayRouteChoiceOffer.Tracker()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func stand(_ seconds: TimeInterval) -> CarPlayRouteChoiceOffer.Decision {
            offer.update(.init(route: 1, variantCount: 2, speedKmh: 0, along: 200, length: 8_000),
                         now: start.addingTimeInterval(seconds))
        }
        XCTAssertEqual(stand(0), .check(after: AppConfig.carPlayChoiceOfferStandSeconds))
        XCTAssertEqual(stand(AppConfig.carPlayChoiceOfferStandSeconds), .ready)
        offer.spend(route: 1)
        XCTAssertEqual(stand(AppConfig.carPlayChoiceOfferStandSeconds + 60), .none, "один раз")
        XCTAssertFalse(car.previewing, "сам баннер выбор не открывает")
    }

    /// М-12: навигацию забрала система (Яндекс начал своё ведение). Мы
    /// уступаем: маршрут снят, поездка и камеры остаются; выбор не всплывает,
    /// сессии нет. Новый маршрут из «Куда» — снова выбор машины и ведение
    /// только после «Поехали».
    func testSystemCancelYieldsTheRouteKeepsTheTrip() {
        var car = Connection()
        car.rootConfirmed(true)
        car.checkRoot(timedOut: false)
        car.sync(route: true, trip: true, speedKmh: 60)
        // mapTemplateDidCancelNavigation → env.route.clear()
        XCTAssertEqual(car.sync(route: false, trip: true, speedKmh: 60), .none)
        XCTAssertEqual(car.flowPhase, .free)
        XCTAssertFalse(car.guides(route: false, trip: true), "своё ведение не возвращается само")
        // Водитель вернулся в RadarMap ради «Радар!» — фаза та же, ничего не
        // перезапускается (сценарий D1, до 20.10 ведение забиралось у Яндекса).
        XCTAssertEqual(car.sync(route: false, trip: true, speedKmh: 60), .none)
        // Новый маршрут стоя через «Куда».
        car.previewing = true
        XCTAssertEqual(car.sync(route: true, trip: true, speedKmh: 0), .none)
        XCTAssertFalse(car.guides(route: true, trip: true))
    }

    /// М-9: прибытие — маршрут снят, поездка ещё идёт: сессии нет, выбор не
    /// всплывает; затем автостоп — тишина.
    func testArrivalEndsGuidingWithoutAChoice() {
        var car = Connection()
        car.rootConfirmed(true)
        car.checkRoot(timedOut: false)
        car.sync(route: true, trip: true, speedKmh: 20)
        XCTAssertEqual(car.sync(route: false, trip: true, speedKmh: 5), .none)
        XCTAssertFalse(car.guides(route: false, trip: true))
        XCTAssertEqual(car.sync(route: false, trip: false, speedKmh: 0), .none)
        XCTAssertEqual(car.choices.filter { $0 == .show }.count, 0)
    }
}
