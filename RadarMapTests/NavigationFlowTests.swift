//
//  NavigationFlowTests.swift
//  RadarMapTests
//
//  Телефон и машина в одной фазе: стоп рукой снимает маршрут, выбор на
//  телефоне — выбор и в машине, ведение — только в поездке.
//

import XCTest
@testable import RadarMap

final class NavigationFlowTests: XCTestCase {

    private typealias Flow = NavigationFlow

    func testPhases() {
        XCTAssertEqual(Flow.phase(hasRoute: false, isTripActive: false), .free)
        XCTAssertEqual(Flow.phase(hasRoute: false, isTripActive: true), .free, "едем без маршрута — ведения нет")
        XCTAssertEqual(Flow.phase(hasRoute: true, isTripActive: false), .choosing)
        XCTAssertEqual(Flow.phase(hasRoute: true, isTripActive: true), .guiding)
    }

    func testManualStopEndsTheRouteAutoStopKeepsIt() {
        // 12.10: «Стоп» в машине — «поездка завершена», а ведение осталось.
        XCTAssertFalse(Flow.keepsRoute(after: .manual))
        XCTAssertTrue(Flow.keepsRoute(after: .auto), "долгая стоянка в пути — тронулись и едем дальше")
        XCTAssertTrue(Flow.keepsRoute(after: .passenger))
    }

    func testCarNeverGuidesWithoutATrip() {
        // 12.10: телефон показывал «Поехали», машина — «поверните налево».
        XCTAssertFalse(Flow.carGuides(phase: .choosing, choosing: false))
        XCTAssertFalse(Flow.carGuides(phase: .free, choosing: false))
        XCTAssertTrue(Flow.carGuides(phase: .guiding, choosing: false))
        XCTAssertFalse(Flow.carGuides(phase: .guiding, choosing: true), "сессия — только после «Поехали»")
    }

    func testCarFollowsThePhoneChoice() {
        // Маршрут построен на телефоне — в машине тот же выбор с «Поехали».
        XCTAssertEqual(Flow.carChoice(from: .free, to: .choosing, showing: false, building: false), .show)
        // Машина подключилась, а на телефоне уже выбор.
        XCTAssertEqual(Flow.carChoice(from: nil, to: .choosing, showing: false, building: false), .show)
        // Автостоп посреди маршрута: тронемся — поедем дальше, пока — выбор.
        XCTAssertEqual(Flow.carChoice(from: .guiding, to: .choosing, showing: false, building: false), .show)
        // «Поехали» на телефоне или автостарт — выбор в машине закрывается.
        XCTAssertEqual(Flow.carChoice(from: .choosing, to: .guiding, showing: true, building: false), .close)
        // Крестик на телефоне — тоже.
        XCTAssertEqual(Flow.carChoice(from: .choosing, to: .free, showing: true, building: false), .close)
        XCTAssertEqual(Flow.carChoice(from: .guiding, to: .free, showing: true, building: false), .close)
    }

    /// Маршрут с телефона на ходу: в машине ни списка вариантов, ни старта
    /// без «Поехали» — решает телефон (аудит CarPlay 19.10; «я пассажир» на
    /// ходу оставляет маршрут, и автостарт сделал бы пассажира водителем).
    func testPhoneRouteOnTheMoveIsNotPreviewedNorStarted() {
        XCTAssertEqual(Flow.carChoice(from: .free, to: .choosing, showing: false,
                                      building: false, moving: true), .none)
        XCTAssertEqual(Flow.carChoice(from: .guiding, to: .choosing, showing: false,
                                      building: false, moving: true), .none, "«я пассажир» на ходу")
        // Свою постройку машина не перебивает и на ходу.
        XCTAssertEqual(Flow.carChoice(from: .free, to: .choosing, showing: false,
                                      building: true, moving: true), .none)
        // Выбор уже на экране — его судьбу решает MovingWatch, не переход.
        XCTAssertEqual(Flow.carChoice(from: .choosing, to: .choosing, showing: true,
                                      building: false, moving: true), .none)
    }

    func testCarOwnChoiceOverARunningTripStays() {
        // Стоя на светофоре, водитель выбирает в машине новый путь: поездка
        // идёт, фаза — ведение, но выбор закрывать не за что.
        XCTAssertEqual(Flow.carChoice(from: .guiding, to: .guiding, showing: true, building: false), .none)
        // Сценарий D1 (20.10): поездка без маршрута, водитель на светофоре
        // выбирает путь в машине — достроилось, фаза «свободно → ведение», а
        // выбор на экране его собственный. Не закрываем: до 20.10 он мигал и
        // пропадал, а ведение шло по первому варианту.
        XCTAssertEqual(Flow.carChoice(from: .free, to: .guiding, showing: true, building: false), .none)
        XCTAssertEqual(Flow.carChoice(from: nil, to: .guiding, showing: true, building: false), .none)
        // Закрытый выбор в той же фазе не открывается заново сам по себе.
        XCTAssertEqual(Flow.carChoice(from: .choosing, to: .choosing, showing: false, building: false), .none)
        XCTAssertEqual(Flow.carChoice(from: .guiding, to: .guiding, showing: false, building: false), .none)
        XCTAssertEqual(Flow.carChoice(from: .free, to: .free, showing: false, building: false), .none)
    }

    func testCarOwnBuildIsNotInterrupted() {
        // Машина строит маршрут на ходу «едем сразу»: маршрут уже есть, поездки
        // ещё нет — выбор в эту секунду перебил бы решение.
        let phases: [Flow.Phase?] = [nil, .free, .choosing, .guiding]
        for previous in phases {
            for phase in [Flow.Phase.free, .choosing, .guiding] {
                for showing in [false, true] {
                    XCTAssertEqual(Flow.carChoice(from: previous, to: phase, showing: showing, building: true), .none)
                }
            }
        }
    }
}
