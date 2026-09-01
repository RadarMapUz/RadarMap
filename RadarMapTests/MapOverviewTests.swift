//
//  MapOverviewTests.swift
//  RadarMapTests
//
//  Обзор карты: осмотр, охват и то, что за него платится трафиком.
//
//  Три жалобы с живого телефона, и у каждой здесь свой тест:
//  «карта не уменьшается», «не рисует остальное место», «нам не нужны дома».
//

import CoreLocation
import XCTest
@testable import RadarMap

final class MapOverviewTests: XCTestCase {

    // MARK: - Камера больше не отнимает карту

    func testStandingNextToACameraDoesNotCancelInspecting() {
        // Главная поломка осмотра. Камера стоит у перекрёстка, у перекрёстка
        // же стоят на светофоре — `alertInRange` истинно постоянно, и возврат
        // срабатывал КАЖДЫЙ тик, то есть раз в секунду. Ни отодвинуть, ни
        // сдвинуть карту было нельзя вовсе.
        XCTAssertFalse(RoadSketch.alertInterruptsInspect(
            isTripActive: false, speedKmh: 0, alertInRange: true),
            "на стоянке камера в охвате не вправе отнимать карту")
        XCTAssertFalse(RoadSketch.alertInterruptsInspect(
            isTripActive: true, speedKmh: 0, alertInRange: true),
            "в поездке на светофоре — тоже: подъезда нет, машина стоит")
    }

    func testApproachingACameraStillWinsOverTheFinger() {
        // Обратная сторона: подъезд перебивает руку, и это не обсуждается.
        XCTAssertTrue(RoadSketch.alertInterruptsInspect(
            isTripActive: true, speedKmh: 60, alertInRange: true))
        XCTAssertFalse(RoadSketch.alertInterruptsInspect(
            isTripActive: true, speedKmh: 60, alertInRange: false),
            "камеры в охвате нет — перебивать нечем")
    }

    func testAutoReturnHappensOnlyOnATrip() {
        // Возврат существует ради одной опасности: за рулём экран не вправе
        // молча остаться не там, где машина. На стоянке этой опасности нет.
        XCTAssertNil(RoadSketch.inspectReturn(isTripActive: false),
                     "на стоянке карту не отнимают через шесть секунд")
        XCTAssertEqual(RoadSketch.inspectReturn(isTripActive: true),
                       RoadSketch.inspectReturnSeconds)
    }

    // MARK: - Охват

    func testInspectReachesFurtherThanAutomatic() {
        // Потолок автоматики отвечает на «что впереди», потолок осмотра — на
        // «а что там дальше». Это разные вопросы и разные числа.
        XCTAssertGreaterThan(RoadSketch.inspectMaxSpanMeters,
                             RoadSketch.maxSpanMeters * 10)
    }

    func testScaleBarKeepsUpWithTheSpan() {
        // Линейка застревала на «500 м» и на охвате в двадцать километров
        // врала масштабом в сорок раз — а это единственное на схеме, что
        // связывает картинку с землёй.
        XCTAssertEqual(RoadSketch.scaleBarMeters(forSpan: 140), 50)
        XCTAssertEqual(RoadSketch.scaleBarMeters(forSpan: 700), 300)
        var previous = 0.0
        for span in stride(from: 140.0, through: RoadSketch.inspectMaxSpanMeters,
                           by: 137) {
            let bar = RoadSketch.scaleBarMeters(forSpan: span)
            XCTAssertGreaterThanOrEqual(bar, previous, "линейка обязана расти")
            XCTAssertLessThanOrEqual(bar, span, "деление не бывает шире вида")
            XCTAssertGreaterThan(bar, span / 12, "деление не бывает волосом")
            previous = bar
        }
    }

    func testTheLadderOfClassesReachesTheRegion() {
        // Лестница кончалась ступенью «район» и держала её до бесконечности:
        // на обзорном охвате на экран лезли ВСЕ вторичные улицы области, и
        // трассы в этой сети было не найти.
        let district = RoadGeneralise.minimumRank(forSpan: 700, onMinorRoad: false)
        let city = RoadGeneralise.minimumRank(forSpan: 3_000, onMinorRoad: false)
        let region = RoadGeneralise.minimumRank(forSpan: 15_000, onMinorRoad: false)
        XCTAssertLessThan(city, district)
        XCTAssertLessThan(region, city)
        XCTAssertGreaterThanOrEqual(region, RoadGeneralise.rank(.trunk),
                                    "трассы обязаны остаться на любом охвате")
    }

    // MARK: - Бюджеты

    func testNetworkBudgetGrowsWithTheSpan() {
        // Восемьдесят линий — мера вида в двести метров. Тем же числом на
        // охвате района рисуется пятачок вокруг машины и пустота вокруг:
        // сцена, выйдя за бюджет, оставляет БЛИЖНИЕ линии.
        let base = 80
        XCTAssertEqual(RoadSketch.networkBudget(base: base,
                                                span: RoadSketch.minSpanMeters), base,
                       "на своём охвате бюджет обязан остаться прежним")
        XCTAssertGreaterThan(RoadSketch.networkBudget(base: base, span: 700), base)
        XCTAssertGreaterThan(RoadSketch.networkBudget(base: base, span: 10_000),
                             RoadSketch.networkBudget(base: base, span: 700))
        // Перегрев сильнее охвата: ноль остаётся нулём.
        XCTAssertEqual(RoadSketch.networkBudget(base: 0, span: 10_000), 0)
        XCTAssertEqual(RoadSketch.areaBudget(base: 0, span: 10_000), 0)
    }

    // MARK: - Покрытие тайлами

    func testCoverageFollowsTheSpanInsteadOfAFixedThreeByThree() {
        // 3×3 тайла по 0,05° — это ±5,5 км: под ближний план с запасом, а на
        // обзорном охвате пятно данных в середине пустого экрана.
        let near = RoadTiles.steps(forRadius: 300, tileDegrees: 0.05, latitude: 41.3)
        let wide = RoadTiles.steps(forRadius: 18_000, tileDegrees: 0.05, latitude: 41.3)
        XCTAssertEqual(near, 1, "ближний план обходится своим тайлом и соседями")
        XCTAssertGreaterThan(wide, near)
        // Потолок обязан быть: тайлов в окрестности (2n+1)².
        let absurd = RoadTiles.steps(forRadius: 4_000_000, tileDegrees: 0.05,
                                     latitude: 41.3)
        XCTAssertLessThanOrEqual(absurd, 4)
    }

    func testCoverageAsksForTheTileUnderTheCarFirst() {
        // Порядок ключей — он же порядок закачки. Пока он был построчным,
        // первым качался левый верхний угол окрестности, то есть угол экрана.
        let me = CLLocationCoordinate2D(latitude: 41.311, longitude: 69.240)
        let keys = RoadTiles.coverage(of: me, tileDegrees: 0.05, steps: 2)
        XCTAssertEqual(keys.count, 25)
        XCTAssertEqual(keys.first,
                       RoadTiles.tileKey(latitude: me.latitude,
                                         longitude: me.longitude, tileDegrees: 0.05),
                       "первым обязан ехать тайл, на котором стоит машина")
        XCTAssertEqual(Swift.Set(keys).count, keys.count, "дублей в окрестности нет")
        XCTAssertEqual(Swift.Set(RoadTiles.neighborhood(of: me, tileDegrees: 0.05)),
                       Swift.Set(RoadTiles.coverage(of: me, tileDegrees: 0.05, steps: 1)),
                       "прежняя окрестность 3×3 — частный случай нового покрытия")
    }

    func testDownloadQueuePutsTheSkeletonBeforeTheHouses() {
        // Очереди не было вовсе: все недостающие файлы уходили в сеть одним
        // залпом, и первым приезжал тот, кому повезло.
        XCTAssertLessThan(RoadTiles.Set.far.loadRank, RoadTiles.Set.houses.loadRank)
        XCTAssertLessThan(RoadTiles.Set.streets.loadRank, RoadTiles.Set.surface.loadRank)
        XCTAssertEqual(Swift.Set(RoadTiles.Set.allCases.map(\.loadRank)).count,
                       RoadTiles.Set.allCases.count, "очередь без ничьих")
    }

    // MARK: - Слои

    func testHousesAndSidewalksAreOffUnlessAsked() {
        // 78 МБ из 347 по стране и 6,72 МБ из 13,86 в одной окрестности —
        // половина всего трафика схемы ради вопроса последних двухсот метров.
        let quiet = RoadTiles.wantedSets(span: RoadSketch.minSpanMeters,
                                         minors: false, far: false,
                                         houses: false, sidewalks: false)
        XCTAssertFalse(quiet.contains(.houses))
        XCTAssertFalse(quiet.contains(.sidewalks))
        XCTAssertTrue(quiet.contains(.far), "костяк — всегда, без него схемы нет")
        XCTAssertTrue(quiet.contains(.streets))

        let asked = RoadTiles.wantedSets(span: RoadSketch.minSpanMeters,
                                         minors: false, far: false,
                                         houses: true, sidewalks: true)
        XCTAssertTrue(asked.contains(.houses))
        XCTAssertTrue(asked.contains(.sidewalks))
    }

    func testWideSpanStopsPayingForStreetsAndBlocks() {
        // На охвате двадцати километров окрестность — восемьдесят один тайл.
        // Набор улиц весит 6,4 КБ на тайл, кварталы 6,8 КБ: полмегабайта за
        // линии и фигуры мельче пикселя.
        let wide = RoadTiles.wantedSets(span: 12_000, minors: true, far: true,
                                        houses: true, sidewalks: true)
        XCTAssertFalse(wide.contains(.streets))
        XCTAssertFalse(wide.contains(.yards))
        XCTAssertFalse(wide.contains(.blocks))
        XCTAssertFalse(wide.contains(.houses))
        XCTAssertFalse(wide.contains(.surface))
        XCTAssertTrue(wide.contains(.far), "костяк района — то, ради чего смотрят")
        XCTAssertTrue(wide.contains(.water), "вода опознаётся быстрее любой формы")
    }

    func testStreetsSurviveWellPastTheSwitchToTheSkeleton() {
        // Запас над farNetworkSpan нарочный: возврат к ближнему плану должен
        // быть мгновенным, а не «подождите, качаю улицы обратно».
        XCTAssertGreaterThan(RoadSketch.streetsMaxSpan, RoadSketch.farNetworkSpan * 2)
        let district = RoadTiles.wantedSets(span: RoadSketch.farNetworkSpan + 10,
                                            minors: false, far: true,
                                            houses: false, sidewalks: false)
        XCTAssertTrue(district.contains(.streets))
    }
}
