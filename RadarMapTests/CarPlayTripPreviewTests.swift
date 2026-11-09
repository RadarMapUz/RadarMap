//
//  CarPlayTripPreviewTests.swift
//  RadarMapTests
//
//  Выбор маршрута в машине: тексты вариантов не пустые и говорят главное,
//  цвет времени не утверждает «пробок нет» без данных, на ходу выбора нет.
//

import MapKit
import XCTest
@testable import RadarMap

final class CarPlayTripPreviewTests: XCTestCase {

    private func variant(id: Int, minutes: Double, km: Double, cameras: Int = 0,
                         labels: [RouteChoice.Label] = [], traffic: TimeInterval? = nil) -> RouteService.Variant {
        let points = [MKMapPoint(CLLocationCoordinate2D(latitude: 41.31, longitude: 69.24)),
                      MKMapPoint(CLLocationCoordinate2D(latitude: 41.33, longitude: 69.26))]
        let camera = Camera(id: 1, region: "", city: "", location: "тест", lat: 41.32, lon: 69.25,
                            type: "Стационар радар", violations: [], needsReview: nil)
        var v = RouteService.Variant(
            id: id, points: points, polyline: MKPolyline(points: points, count: 2),
            distance: km * 1000, travelTime: minutes * 60,
            cameras: (0..<cameras).map { RouteService.RouteCamera(camera: camera, distanceAlong: Double($0) * 100) },
            steps: [])
        v.assessment.labels = labels
        v.trafficDelay = traffic
        return v
    }

    func testEveryLineHasAtLeastOneVariantAndNoneIsEmpty() {
        // CPRouteChoice: «You must provide at least one variant».
        let fast = variant(id: 0, minutes: 25, km: 12, cameras: 3, labels: [.fastest])
        let calm = variant(id: 1, minutes: 27, km: 13, cameras: 1, labels: [.fewerCameras])
        for v in [fast, calm, variant(id: 2, minutes: 9, km: 4)] {
            let text = CarPlayTripPreview.text(for: v)
            for line in [text.summary, text.additional, text.selection] {
                XCTAssertFalse(line.isEmpty)
                XCTAssertFalse(line.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
    }

    func testLabelLeadsAndTimeIsAlwaysThere() {
        let fast = variant(id: 0, minutes: 25, km: 12, cameras: 3, labels: [.fastest])
        let calm = variant(id: 1, minutes: 27, km: 13, cameras: 1, labels: [.fewerCameras])
        let text = CarPlayTripPreview.text(for: calm)
        let title = RoutePanel.title(.fewerCameras, calm)
        XCTAssertTrue(text.summary[0].hasPrefix(title), text.summary[0])
        XCTAssertTrue(text.summary[0].contains(calm.etaText))
        XCTAssertEqual(text.summary.last, calm.etaText, "самый короткий вариант — время")
    }

    func testMyRoadSaysHowYouUsuallyDriveAndShowsOwnTime() {
        // «Моя дорога» (24.4): в машине тот же ярлык, что на телефоне, и время
        // по своим поездкам (39 мин обычно + 4 мин пробок сверх обычного).
        let fast = variant(id: 0, minutes: 35, km: 12, labels: [.fastest], traffic: 300)
        var mine = variant(id: 1, minutes: 36, km: 13, labels: [.myRoad, .familiar], traffic: 600)
        mine.assessment.myRoad = RouteChoice.Personal(direction: .toHome, trips: 14, seconds: 43 * 60,
                                                      jamSeconds: 4 * 60)
        XCTAssertEqual(mine.expectedTime, 43 * 60)
        XCTAssertEqual(mine.shownTrafficDelay, 4 * 60, "пробки — сверх своего обычного, не по линии")
        let text = CarPlayTripPreview.text(for: mine)
        XCTAssertTrue(text.summary[0].hasPrefix(RoutePanel.title(.myRoad, mine)), text.summary[0])
        XCTAssertTrue(text.summary[0].contains(mine.etaText))
        let reason = RoutePanel.reason(mine, among: [fast, mine]) ?? ""
        XCTAssertTrue(reason.contains(RoutePanel.myRoadReason(mine.assessment.myRoad!)), reason)
        XCTAssertTrue(reason.contains(Formatting.unbreakable(Formatting.duration(39 * 60))), reason)
        XCTAssertFalse(reason.contains(String(format: String(localized: "поездок этим путём: %lld"), 0)),
                       "«Знакомый» рядом со своей дорогой не повторяется")
        // Своё время без пробок сверх обычного — не «без пробок»: обычные в нём есть.
        mine.assessment.myRoad = RouteChoice.Personal(direction: .toHome, trips: 14, seconds: 39 * 60)
        XCTAssertNil(mine.trafficNote)
    }

    /// Подпись строки — километры и камеры: метка и время уже в заголовке
    /// (CPSRouteRowView: подпись — selection, заголовок — summary).
    func testLineBelowTheTitleIsDistanceAndCameras() {
        let fast = variant(id: 0, minutes: 25, km: 12, cameras: 3, labels: [.fastest], traffic: 420)
        let text = CarPlayTripPreview.text(for: fast)
        let cameras = String(format: String(localized: "камер: %lld"), 3)
        XCTAssertEqual(text.selection, ["\(fast.distanceText) · \(cameras)", fast.distanceText])
        XCTAssertEqual(text.additional, text.selection)
        XCTAssertFalse(text.selection[0].contains(RoutePanel.title(.fastest, fast)))
        XCTAssertFalse(text.selection[0].contains(fast.etaText))
    }

    func testTimeColorNeverClaimsFreeRoadWithoutData() {
        XCTAssertEqual(CarPlayTripPreview.timeColor(trafficDelay: nil), .standard)
        XCTAssertEqual(CarPlayTripPreview.timeColor(trafficDelay: 30), .green)
        XCTAssertEqual(CarPlayTripPreview.timeColor(trafficDelay: 300), .orange)
        XCTAssertEqual(CarPlayTripPreview.timeColor(trafficDelay: 900), .red)
    }

    func testNoChoiceWhileDriving() {
        XCTAssertTrue(CarPlayTripPreview.shouldPreview(speedKmh: 0))
        XCTAssertTrue(CarPlayTripPreview.shouldPreview(speedKmh: 6))
        XCTAssertFalse(CarPlayTripPreview.shouldPreview(speedKmh: 40))
    }

    func testMovingOffAcceptsTheChoiceOnlyWhenSustained() {
        var watch = CarPlayTripPreview.MovingWatch()
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(watch.update(speedKmh: 30, at: t0))
        XCTAssertFalse(watch.update(speedKmh: 0, at: t0 + 1), "всплеск GPS не считается")
        XCTAssertFalse(watch.update(speedKmh: 20, at: t0 + 2))
        XCTAssertFalse(watch.update(speedKmh: 22, at: t0 + 4))
        XCTAssertTrue(watch.update(speedKmh: 25, at: t0 + 2 + AppConfig.carPlayPreviewAutoStartSeconds))
    }

    // MARK: - Карточка выбора не расходится с линией (40I, дефект 35)

    private func ids(_ variants: [RouteService.Variant]) -> [ObjectIdentifier] {
        CarPlayTripPreview.identity(variants)
    }

    private func texts(_ variants: [RouteService.Variant]) -> [Int: CarPlayTripPreview.ChoiceText] {
        Dictionary(uniqueKeysWithValues: variants.map { ($0.id, CarPlayTripPreview.text(for: $0)) })
    }

    /// Пробки пришли поздно и сменили время в строках: пока водитель не
    /// трогал выбор — пересоздать (строки CPRouteChoice после показа не
    /// меняются); после его касания — только оценки, фокус крутилки не прыгает.
    func testLateTrafficRebuildsUntilTheDriverPicksInTheCar() {
        let fast = variant(id: 0, minutes: 25, km: 12, labels: [.fastest])
        let calm = variant(id: 1, minutes: 27, km: 13, labels: [.fewerCameras])
        var shown = CarPlayTripPreview.Shown(set: ids([fast, calm]), order: [0, 1], texts: texts([fast, calm]))
        XCTAssertEqual(CarPlayTripPreview.refresh(shown, selected: 0, set: ids([fast, calm]), texts: texts([fast, calm])), .estimates,
                       "ничего не сменилось — только минута прибытия")
        var jammed = fast
        jammed.trafficDelay = 9 * 60
        XCTAssertEqual(CarPlayTripPreview.refresh(shown, selected: 0, set: ids([jammed, calm]), texts: texts([jammed, calm])), .rebuild,
                       "«25 мин» на карточке при 34 в пути — устаревшая строка")
        shown.picked(1)
        shown.picked(0)
        XCTAssertEqual(CarPlayTripPreview.refresh(shown, selected: 0, set: ids([jammed, calm]), texts: texts([jammed, calm])), .estimates,
                       "водитель крутит выбор — время выделенного идёт оценками")
    }

    /// Выбор сменился не в машине (на телефоне) — карточка обязана выделить
    /// то, чем поедем, даже после касаний в машине.
    func testSelectionFromElsewhereAlwaysRebuilds() {
        let fast = variant(id: 0, minutes: 25, km: 12, labels: [.fastest])
        let calm = variant(id: 1, minutes: 27, km: 13, labels: [.fewerCameras])
        var shown = CarPlayTripPreview.Shown(set: ids([fast, calm]), order: [0, 1], texts: texts([fast, calm]))
        XCTAssertEqual(CarPlayTripPreview.refresh(shown, selected: 1, set: ids([fast, calm]), texts: texts([fast, calm])), .rebuild)
        shown.picked(1)
        XCTAssertEqual(CarPlayTripPreview.refresh(shown, selected: 1, set: ids([fast, calm]), texts: texts([fast, calm])), .estimates,
                       "выбрал в машине — карточка уже его выделяет")
        let third = variant(id: 2, minutes: 30, km: 14)
        XCTAssertEqual(CarPlayTripPreview.refresh(shown, selected: 1, set: ids([fast, calm, third]), texts: texts([fast, calm, third])), .rebuild,
                       "другой набор вариантов")
    }

    /// Номера вариантов — индексы и совпадают между наборами. Водитель
    /// отметил вариант 1, на телефоне ту же цель построили заново — новый
    /// набор из двух, выбран снова 1: карточка обязана пересоздаться, иначе
    /// в машине строки старого набора, а «Поехали» выберет вариант нового.
    func testNewSetWithTheSameNumbersAlwaysRebuilds() {
        let fast = variant(id: 0, minutes: 25, km: 12, labels: [.fastest])
        let calm = variant(id: 1, minutes: 27, km: 13, labels: [.fewerCameras])
        var shown = CarPlayTripPreview.Shown(set: ids([fast, calm]), order: [0, 1], texts: texts([fast, calm]))
        shown.picked(1)
        let again = [variant(id: 0, minutes: 25, km: 12, labels: [.fastest]),
                     variant(id: 1, minutes: 27, km: 13, labels: [.fewerCameras])]
        XCTAssertEqual(texts(again), texts([fast, calm]), "строки те же — отличает только опознание набора")
        XCTAssertEqual(CarPlayTripPreview.refresh(shown, selected: 1, set: ids(again), texts: texts(again)), .rebuild)
    }

    /// Система может сообщить выделенный вариант при первом показе — это не
    /// выбор водителя, время в строках по-прежнему обновляется пересозданием.
    func testSystemEchoOfTheHighlightedChoiceIsNotAPick() {
        let fast = variant(id: 0, minutes: 25, km: 12, labels: [.fastest])
        let calm = variant(id: 1, minutes: 27, km: 13, labels: [.fewerCameras])
        var shown = CarPlayTripPreview.Shown(set: ids([fast, calm]), order: [0, 1], texts: texts([fast, calm]))
        shown.picked(0)
        XCTAssertFalse(shown.pickedInCar)
        var jammed = fast
        jammed.trafficDelay = 9 * 60
        XCTAssertEqual(CarPlayTripPreview.refresh(shown, selected: 0, set: ids([jammed, calm]), texts: texts([jammed, calm])), .rebuild)
    }
}

/// Показ выбора в машине замораживает метки и выбор на настоящем
/// RouteService: поздние пробки меняют время вариантов, но не «Быстрый» и не
/// вариант, которым поведёт автостарт на ходу (40I, дефект 35).
@MainActor
final class CarPlayChoiceFreezeTests: XCTestCase {

    /// Две параллельные прямые на север по ~6 км.
    private func line(longitude: Double) -> [CLLocationCoordinate2D] {
        (0...60).map { CLLocationCoordinate2D(latitude: 41.30 + Double($0) * 0.0009, longitude: longitude) }
    }

    /// Пробка «стоим» по всей первой прямой, в нашу сторону.
    private func jam(on path: [CLLocationCoordinate2D]) -> TrafficSnapshot {
        TrafficSnapshot(generated: Date(), edges: zip(path, path.dropFirst()).map {
            TrafficEdge(a: $0.0, b: $0.1, level: 3, kmh: 5, modelKmh: 60)
        })
    }

    private func seeded() async -> (RouteService, [CLLocationCoordinate2D]) {
        let route = RouteService()
        let first = line(longitude: 69.24)
        await route.seedRoutes(name: "Работа", variants: [(first, 24 * 60), (line(longitude: 69.30), 27 * 60)])
        return (route, first)
    }

    private func waitForTraffic(_ route: RouteService) async {
        for _ in 0..<200 where route.variants.first?.trafficDelay == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testShownInTheCarLateJamKeepsLabelsAndChoiceButUpdatesTime() async {
        let (route, first) = await seeded()
        XCTAssertEqual(route.variants.count, 2)
        XCTAssertEqual(route.selectedID, 0)
        let labels = route.variants.map(\.assessment)
        // Выбор встал на экран машины.
        route.noteChoiceTouched()
        let snapshot = jam(on: first)
        route.trafficSnapshot = { snapshot }
        route.liveTrafficArrived()
        await waitForTraffic(route)
        XCTAssertNotNil(route.variants[0].trafficDelay, "время вариантов живёт дальше")
        XCTAssertEqual(route.selectedID, 0, "выбор не уходит из-под карточки машины")
        XCTAssertEqual(route.variants.map(\.assessment), labels, "метки заморожены")
    }

    /// Выбор открыт в машине, на телефоне ту же цель построили заново: новый
    /// набор замерзает уже в `apply`, до того как машина его покажет.
    func testNewSetBuiltWhileTheCarShowsTheChoiceIsFrozenAtOnce() async {
        let (route, _) = await seeded()
        route.choiceShownInCar = true
        let first = line(longitude: 69.25)
        await route.seedRoutes(name: "Работа", variants: [(first, 24 * 60), (line(longitude: 69.31), 27 * 60)])
        XCTAssertEqual(route.selectedID, 0)
        let snapshot = jam(on: first)
        route.trafficSnapshot = { snapshot }
        route.liveTrafficArrived()
        await waitForTraffic(route)
        XCTAssertNotNil(route.variants[0].trafficDelay)
        XCTAssertEqual(route.selectedID, 0, "новый набор при открытом выборе в машине — заморожен")
    }

    /// Контроль: без показа в машине тот же поздний затор переносит выбор —
    /// значит, тест выше проверяет именно заморозку.
    func testUntouchedChoiceStillFollowsLateJam() async {
        let (route, first) = await seeded()
        let snapshot = jam(on: first)
        route.trafficSnapshot = { snapshot }
        route.liveTrafficArrived()
        await waitForTraffic(route)
        for _ in 0..<200 where route.selectedID == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(route.selectedID, 1)
    }
}
