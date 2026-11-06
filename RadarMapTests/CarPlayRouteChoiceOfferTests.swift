//
//  CarPlayRouteChoiceOfferTests.swift
//  RadarMapTests
//
//  Выбор маршрута после остановки (51): красный свет и пробка — не повод,
//  устойчивая стоянка — предложение, один раз; не из чего выбирать, поздно,
//  тронулись — нет; камера и занятый экран — ждём.
//

import XCTest
@testable import RadarMap

final class CarPlayRouteChoiceOfferTests: XCTestCase {
    private typealias Offer = CarPlayRouteChoiceOffer
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let stand = AppConfig.carPlayChoiceOfferStandSeconds

    private func situation(route: Int? = 1, count: Int = 2, speed: Double = 0, along: Double = 300,
                           length: Double = 10_000, camera: Bool = false, free: Bool = true,
                           phone: Bool = false, busy: Bool = false) -> Offer.Situation {
        Offer.Situation(route: route, variantCount: count, speedKmh: speed, along: along, length: length,
                        cameraAhead: camera, screenFree: free, phonePanelOpen: phone, busy: busy)
    }

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    // MARK: - Стоянка

    /// Красный 20 с и поехали — ни предложения, ни потраченной попытки.
    func testRedLightIsNotAReason() {
        var tracker = Offer.Tracker()
        XCTAssertEqual(tracker.update(situation(speed: 40), now: at(0)), .none)
        XCTAssertEqual(tracker.update(situation(), now: at(10)), .check(after: stand))
        XCTAssertEqual(tracker.update(situation(), now: at(30)), .check(after: stand - 20), "20 с на красном")
        XCTAssertEqual(tracker.update(situation(speed: 30, along: 340), now: at(32)), .none, "зелёный")
        XCTAssertTrue(tracker.isOpen, "попытка цела: следующая настоящая остановка ещё может предложить")
    }

    func testSteadyStopOffers() {
        var tracker = Offer.Tracker()
        _ = tracker.update(situation(), now: at(0))
        XCTAssertEqual(tracker.update(situation(), now: at(stand - 1)), .check(after: 1))
        XCTAssertEqual(tracker.update(situation(), now: at(stand)), .ready)
    }

    /// Шум GPS стоя счёт не сбрасывает, рывки пробки — сбрасывают.
    func testGpsNoiseKeepsTheCountCrawlingResetsIt() {
        var noisy = Offer.Tracker()
        _ = noisy.update(situation(), now: at(0))
        _ = noisy.update(situation(speed: 6, along: 305), now: at(30))
        XCTAssertEqual(noisy.update(situation(), now: at(stand)), .ready, "6 км/ч и 5 м — шум")

        var jam = Offer.Tracker()
        _ = jam.update(situation(along: 300), now: at(0))
        _ = jam.update(situation(speed: 6, along: 300 + AppConfig.carPlayChoiceOfferCrawlMeters), now: at(40))
        XCTAssertEqual(jam.update(situation(along: 320), now: at(60)), .check(after: stand),
                       "сдвинулись на 20 м — стоянка заново")
        XCTAssertNotEqual(jam.update(situation(along: 320), now: at(stand)), .ready)
    }

    /// Пробка по данным на нашем пути — не повод; считается только в момент решения.
    func testJamWaitsAndIsAskedOnlyAtTheDecision() {
        var tracker = Offer.Tracker()
        var asked = 0
        func jam() -> Bool { asked += 1; return true }
        _ = tracker.update(situation(), inJam: jam(), now: at(0))
        _ = tracker.update(situation(), inJam: jam(), now: at(stand - 1))
        XCTAssertEqual(asked, 0, "до конца счёта данные о пробках не трогаем")
        XCTAssertEqual(tracker.update(situation(), inJam: jam(), now: at(stand)),
                       .check(after: AppConfig.carPlayChoiceOfferRecheckSeconds))
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(tracker.update(situation(), inJam: false, now: at(stand + 10)), .ready, "пробка рассосалась")
    }

    // MARK: - Ждём

    func testCameraBusyScreenAndPhonePanelWait() {
        let wait = Offer.Decision.check(after: AppConfig.carPlayChoiceOfferRecheckSeconds)
        for blocked in [situation(camera: true), situation(free: false), situation(phone: true), situation(busy: true)] {
            var tracker = Offer.Tracker()
            _ = tracker.update(blocked, now: at(0))
            XCTAssertEqual(tracker.update(blocked, now: at(stand)), wait)
            XCTAssertTrue(tracker.isOpen, "ожидание попытку не тратит")
            XCTAssertEqual(tracker.update(situation(), now: at(stand + 10)), .ready, "помеха ушла")
        }
    }

    // MARK: - Один раз

    func testOncePerRouteAndNewDriverRouteAsksAgain() {
        var tracker = Offer.Tracker()
        _ = tracker.update(situation(), now: at(0))
        XCTAssertEqual(tracker.update(situation(), now: at(stand)), .ready)
        tracker.spend(route: 1)
        XCTAssertFalse(tracker.isOpen)
        XCTAssertEqual(tracker.update(situation(), now: at(stand + 300)), .none, "молчание и «Остаться» — всё")
        // Встали снова на том же маршруте — тоже нет.
        _ = tracker.update(situation(speed: 40, along: 500), now: at(stand + 310))
        XCTAssertEqual(tracker.update(situation(along: 500), now: at(stand * 3)), .none)

        // Новый набор из двух вариантов строит только водитель.
        _ = tracker.update(situation(route: 2, along: 0), now: at(1_000))
        XCTAssertEqual(tracker.update(situation(route: 2, along: 0), now: at(1_000 + stand)), .ready)
    }

    /// Перестроение и объезд дают один вариант — вопроса нет, сколько ни стой.
    func testRerouteAndDetourDoNotOffer() {
        var tracker = Offer.Tracker()
        tracker.spend(route: 1)
        for seconds in [0, stand, stand * 2] {
            XCTAssertEqual(tracker.update(situation(route: 3, count: 1, along: 0), now: at(seconds)), .none)
        }
    }

    func testNoRouteNoOffer() {
        var tracker = Offer.Tracker()
        XCTAssertEqual(tracker.update(situation(route: nil, count: 0), now: at(0)), .none)
        XCTAssertFalse(tracker.isOpen)
    }

    // MARK: - Поздно

    func testFarAlongIsTooLateForGood() {
        var tracker = Offer.Tracker()
        let far = situation(along: 3_000, length: 10_000)
        XCTAssertEqual(tracker.update(far, now: at(0)), .none)
        XCTAssertFalse(tracker.isOpen, "путь только растёт — не вернётся")
        XCTAssertEqual(tracker.update(far, now: at(stand)), .none)
    }

    func testStalenessRules() {
        let age = AppConfig.carPlayChoiceOfferMaxAgeSeconds, meters = AppConfig.carPlayChoiceOfferMaxMeters
        XCTAssertFalse(Offer.isStale(ageSeconds: age, along: 4_000, length: 20_000), "свежий, проехали 4 км")
        XCTAssertFalse(Offer.isStale(ageSeconds: 3_600, along: meters, length: 20_000), "час стоим на заправке")
        XCTAssertTrue(Offer.isStale(ageSeconds: age + 1, along: meters + 1, length: 20_000))
        XCTAssertTrue(Offer.isStale(ageSeconds: 10, along: 600, length: 2_000), "свежий, но треть пути позади")
    }

    /// Возраст — на начало стоянки: встали на четвёртой минуте, и ожидание
    /// подтверждения маршрут не состарило.
    func testAgeCountsToTheStartOfTheStop() {
        var tracker = Offer.Tracker()
        let there = situation(along: 2_000, length: 20_000)
        _ = tracker.update(situation(speed: 40, along: 100, length: 20_000), now: at(0))
        _ = tracker.update(there, now: at(AppConfig.carPlayChoiceOfferMaxAgeSeconds - 10))
        XCTAssertEqual(tracker.update(there, now: at(AppConfig.carPlayChoiceOfferMaxAgeSeconds - 10 + stand)), .ready)
    }

    // MARK: - Из чего выбирать

    private func variant(_ id: Int, minutes: Double, cameras: Int = 3, labeled: Bool = false,
                         near: Bool = true) -> Offer.Variant {
        Offer.Variant(id: id, seconds: minutes * 60, fullSeconds: minutes * 60, cameras: cameras,
                      labeled: labeled, nearCar: near)
    }

    func testAlmostTheSameIsNothingToChoose() {
        XCTAssertEqual(Offer.choices(selected: 0, variants: [variant(0, minutes: 30), variant(1, minutes: 29)]), [],
                       "минута — в пределах точности оценки")
        XCTAssertEqual(Offer.choices(selected: 0, variants: [variant(0, minutes: 30)]), [], "один вариант")
        XCTAssertEqual(Offer.choices(selected: 7, variants: [variant(0, minutes: 30)]), [], "выбранного нет")
    }

    func testNotableVariantsAreChoices() {
        XCTAssertEqual(Offer.choices(selected: 0, variants: [variant(0, minutes: 30), variant(1, minutes: 26)]), [0, 1],
                       "быстрее на 4 мин")
        XCTAssertEqual(Offer.choices(selected: 0, variants: [variant(0, minutes: 30, cameras: 5),
                                                             variant(1, minutes: 33, cameras: 2)]), [0, 1],
                       "чуть дольше, но камер меньше")
        XCTAssertEqual(Offer.choices(selected: 0, variants: [variant(0, minutes: 30),
                                                             variant(1, minutes: 31, labeled: true)]), [0, 1],
                       "своя метка")
        XCTAssertEqual(Offer.choices(selected: 0, variants: [variant(0, minutes: 30, cameras: 5),
                                                             variant(1, minutes: 45, cameras: 1)]), [],
                       "на 15 мин дольше — камер меньше, но выбирать незачем")
    }

    /// Вариант, на линии которого машины нет, обернулся бы перестроением.
    func testVariantAwayFromTheCarIsNotAChoice() {
        let variants = [variant(0, minutes: 30), variant(1, minutes: 20, near: false), variant(2, minutes: 25)]
        XCTAssertEqual(Offer.choices(selected: 0, variants: variants), [0, 2])
        XCTAssertEqual(Offer.choices(selected: 0, variants: [variant(0, minutes: 30),
                                                             variant(1, minutes: 20, near: false)]), [])
    }

    func testBannerSaysWhatIsBetter() {
        let faster = [variant(0, minutes: 30), variant(1, minutes: 24)]
        XCTAssertEqual(Offer.gain(selected: 0, variants: faster, choices: [0, 1]), .faster(minutes: 6))
        let calmer = [variant(0, minutes: 30, cameras: 5), variant(1, minutes: 31, cameras: 3)]
        XCTAssertEqual(Offer.gain(selected: 0, variants: calmer, choices: [0, 1]), .fewerCameras(2))
        let other = [variant(0, minutes: 30), variant(1, minutes: 31, labeled: true)]
        XCTAssertEqual(Offer.gain(selected: 0, variants: other, choices: [0, 1]), .other)
    }

    // MARK: - Ревью 51

    /// A и B сошлись: всё, чем B «быстрее», осталось на проеханном участке A.
    func testDifferenceOnlyBehindUsIsNoOffer() {
        let a = Offer.variant(id: 0, shownSeconds: 30 * 60, distance: 30_000, along: 15_000, deviation: 2,
                              cameraAlongs: [], labeled: false)
        let b = Offer.variant(id: 1, shownSeconds: 24 * 60, distance: 24_000, along: 9_000, deviation: 2,
                              cameraAlongs: [], labeled: false)
        XCTAssertEqual(a.seconds, 15 * 60, accuracy: 0.01)
        XCTAssertEqual(b.seconds, 15 * 60, accuracy: 0.01)
        XCTAssertEqual(Offer.choices(selected: 0, variants: [a, b]), [])
    }

    /// Вперёд и вправду быстрее — предложение, и в баннере разница по остатку.
    func testRemainingDifferenceIsAnOffer() {
        let a = Offer.variant(id: 0, shownSeconds: 30 * 60, distance: 30_000, along: 15_000, deviation: 2,
                              cameraAlongs: [], labeled: false)
        let b = Offer.variant(id: 1, shownSeconds: 20 * 60, distance: 20_000, along: 10_000, deviation: 2,
                              cameraAlongs: [], labeled: false)
        let choices = Offer.choices(selected: 0, variants: [a, b])
        XCTAssertEqual(choices, [0, 1])
        XCTAssertEqual(Offer.gain(selected: 0, variants: [a, b], choices: choices), .faster(minutes: 5))
    }

    /// Камеры позади не считаются; метка от старта не держится далеко от него.
    func testCamerasBehindAndOldLabelsDoNotCount() {
        let a = Offer.variant(id: 0, shownSeconds: 1_800, distance: 30_000, along: 5_000, deviation: 2,
                              cameraAlongs: [1_000, 2_000, 3_000], labeled: false)
        XCTAssertEqual(a.cameras, 0, "все три проехали")
        let b = Offer.variant(id: 1, shownSeconds: 1_800, distance: 30_000, along: 5_000, deviation: 2,
                              cameraAlongs: [], labeled: true)
        XCTAssertFalse(b.labeled, "«Спокойнее» сказано про путь от старта")
        XCTAssertEqual(Offer.choices(selected: 0, variants: [a, b]), [])
    }

    /// Соседняя улица (в 100 м) не вариант: порог — прижим к линии, не перестроение.
    func testVariantOnTheNextStreetIsNoOffer() {
        let a = Offer.variant(id: 0, shownSeconds: 1_800, distance: 30_000, along: 0, deviation: 2,
                              cameraAlongs: [], labeled: false)
        let next = Offer.variant(id: 1, shownSeconds: 1_200, distance: 30_000, along: 0, deviation: 100,
                                 cameraAlongs: [], labeled: false)
        XCTAssertFalse(next.nearCar)
        XCTAssertEqual(Offer.choices(selected: 0, variants: [a, next]), [])
        let same = Offer.variant(id: 1, shownSeconds: 1_200, distance: 30_000, along: 0,
                                 deviation: AppConfig.routeSnapMeters, cameraAlongs: [], labeled: false)
        XCTAssertEqual(Offer.choices(selected: 0, variants: [a, same]), [0, 1])
    }

    /// Тоннель: скорость доходит до 0, путь замирает. Баннера нет, счёт заново.
    func testLostSignalIsNotAStop() {
        var tracker = Offer.Tracker()
        var lost = situation()
        lost.signalLost = true
        for seconds in [0, stand, stand * 2] {
            XCTAssertEqual(tracker.update(lost, now: at(seconds)), .none, "\(seconds) с без сигнала")
        }
        XCTAssertTrue(tracker.isOpen, "попытка цела")
        XCTAssertEqual(tracker.update(situation(), now: at(stand * 2 + 1)), .check(after: stand), "сигнал вернулся")

        // Стояли 80 с, пропал сигнал на 20 с — считаем заново, а не 100 с.
        var stood = Offer.Tracker()
        _ = stood.update(situation(), now: at(0))
        _ = stood.update(lost, now: at(80))
        XCTAssertEqual(stood.update(situation(), now: at(100)), .check(after: stand))
    }

    /// Встал, вынул кабель, вернулся через час на то же место: не с порога.
    func testDisconnectRestartsTheCount() {
        var tracker = Offer.Tracker()
        _ = tracker.update(situation(), now: at(0))
        _ = tracker.update(situation(), now: at(80))
        tracker.interrupted()
        XCTAssertEqual(tracker.update(situation(), now: at(3_600)), .check(after: stand))
        XCTAssertTrue(tracker.isOpen)
        tracker.spend(route: 1)
        tracker.interrupted()
        XCTAssertFalse(tracker.isOpen, "отключение не возвращает потраченную попытку")
    }

    /// Неровная скорость: A — 25 мин на 25 км, B — 26 мин на 13 км, общие 4 км.
    /// По долям пути 21 и 18 мин, а B на деле на минуту медленнее — не «быстрее на 3».
    func testShareOfTheWayAloneDoesNotProveFaster() {
        let a = Offer.variant(id: 0, shownSeconds: 25 * 60, distance: 25_000, along: 4_000, deviation: 2,
                              cameraAlongs: [], labeled: false)
        let b = Offer.variant(id: 1, shownSeconds: 26 * 60, distance: 13_000, along: 4_000, deviation: 2,
                              cameraAlongs: [], labeled: false)
        XCTAssertEqual(a.seconds, 21 * 60, accuracy: 0.01)
        XCTAssertEqual(b.seconds, 18 * 60, accuracy: 0.01)
        XCTAssertEqual(Offer.saved(b, over: a), -60, accuracy: 0.01)
        XCTAssertEqual(Offer.choices(selected: 0, variants: [a, b]), [])
        XCTAssertNotEqual(Offer.gain(selected: 0, variants: [a, b], choices: [0, 1]), .faster(minutes: 3))
    }

    /// «Быстрее» — меньшая из двух разниц: по остатку 5 мин, по полному 3 — обещаем 3.
    func testFasterShowsTheSmallerDifference() {
        let a = Offer.Variant(id: 0, seconds: 20 * 60, fullSeconds: 30 * 60, cameras: 0, labeled: false, nearCar: true)
        let b = Offer.Variant(id: 1, seconds: 15 * 60, fullSeconds: 27 * 60, cameras: 0, labeled: false, nearCar: true)
        let choices = Offer.choices(selected: 0, variants: [a, b])
        XCTAssertEqual(choices, [0, 1])
        XCTAssertEqual(Offer.gain(selected: 0, variants: [a, b], choices: choices), .faster(minutes: 3))
    }
}
