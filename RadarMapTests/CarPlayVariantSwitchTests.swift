//
//  CarPlayVariantSwitchTests.swift
//  RadarMapTests
//
//  Смена варианта посреди пути в машине (ревью 51, №1): `selectVariant` обнуляет
//  прогресс, а стоя его некому вернуть. Остаток до камеры и манёвр верны сразу.
//  Плюс: что происходит со списком из баннера при уходе с экрана и новом показе,
//  и отзвук нашей отмены навигации.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class CarPlayVariantSwitchTests: XCTestCase {
    private let start = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.20)

    /// Точка на меридиане в `meters` к северу от старта.
    private func north(_ meters: Double) -> CLLocationCoordinate2D {
        GeoMath.destination(from: start, bearing: 0, distanceMeters: meters)
    }

    /// Два варианта: общие 4 км на север, дальше расходятся.
    private func seeded() async -> RouteService {
        let route = RouteService()
        let shared = stride(from: 0.0, through: 4_000, by: 200).map(north)
        let east = shared + (1...5).map { GeoMath.destination(from: north(4_000), bearing: 90, distanceMeters: Double($0) * 400) }
        let west = shared + (1...5).map { GeoMath.destination(from: north(4_000), bearing: 270, distanceMeters: Double($0) * 300) }
        await route.seedRoutes(name: "Цель", variants: [(east, 400), (west, 300)])
        return route
    }

    /// Посреди маршрута сменили вариант — стоя, без единого фикса после.
    func testSwitchingMidRouteKeepsProgressAtOnce() async {
        let route = await seeded()
        let here = north(3_000)
        route.updateProgress(coordinate: here, cameras: [], announce: false)
        XCTAssertEqual(route.progressAlong, 3_000, accuracy: 15)
        let other = route.variants.first { $0.id != route.selectedID }!.id

        CarPlaySceneDelegate.switchVariant(other, route: route, at: here, cameras: [], course: -1, speedKmh: 0)

        XCTAssertEqual(route.selectedID, other)
        XCTAssertEqual(route.progressAlong, 3_000, accuracy: 15, "прогресс — сразу, не с нуля")
        XCTAssertNotNil(route.nextStep, "манёвр есть: сессия не висит на «загружаю»")
        // Камера на отметке 3300 м — настоящая в 300 м, а не в 3300.
        let ahead = LocationGates.routeRemaining(cameraAlong: 3_300, progressAlong: route.progressAlong,
                                                 isOffRoute: route.isOffRoute, isProgressFrozen: false)
        XCTAssertEqual(ahead ?? .infinity, 300, accuracy: 15)
        // Проеханная на отметке 300 м — позади дальше допуска, а не «наша через 300 м».
        let behind = LocationGates.routeRemaining(cameraAlong: 300, progressAlong: route.progressAlong,
                                                  isOffRoute: route.isOffRoute, isProgressFrozen: false)
        XCTAssertLessThan(behind ?? 0, -AppConfig.routePassedToleranceMeters)
    }

    /// Причина правки: голый `selectVariant` оставляет прогресс на нуле.
    func testPlainSelectVariantLosesProgress() async {
        let route = await seeded()
        route.updateProgress(coordinate: north(3_000), cameras: [], announce: false)
        let other = route.variants.first { $0.id != route.selectedID }!.id
        route.selectVariant(other)
        XCTAssertEqual(route.progressAlong, 0, "если это изменится в сервисе, обёртка не нужна")
    }

    /// Тот же вариант — прогресс не трогаем и не пересчитываем.
    func testSameVariantIsANoOp() async {
        let route = await seeded()
        route.updateProgress(coordinate: north(3_000), cameras: [], announce: false)
        let along = route.progressAlong
        CarPlaySceneDelegate.switchVariant(route.selectedID, route: route, at: north(100), cameras: [],
                                           course: -1, speedKmh: 0)
        XCTAssertEqual(route.progressAlong, along)
    }

    // MARK: - Список из баннера

    /// Ушли с экрана при открытом списке из баннера — закрыт и ведение вернётся;
    /// обычный список — как был.
    func testLeavingClosesOnlyTheOfferedList() {
        let offered = CarPlaySceneDelegate()
        offered.model.isPreviewing = true
        offered.previewOffer = (route: 1, origin: 0, ids: [0, 1])
        offered.closeOfferedPreviewOnLeaving()
        XCTAssertFalse(offered.model.isPreviewing)
        XCTAssertNil(offered.previewOffer)

        let ordinary = CarPlaySceneDelegate()
        ordinary.model.isPreviewing = true
        ordinary.closeOfferedPreviewOnLeaving()
        XCTAssertTrue(ordinary.model.isPreviewing)
    }

    /// Новый показ без баннера — обычный список: старый флаг не живёт, и его
    /// «Отмена» снимает маршрут, а не «остаётся на прежнем варианте».
    func testPlainShowForgetsTheOffer() {
        let delegate = CarPlaySceneDelegate()
        delegate.previewOffer = (route: 1, origin: 0, ids: [0, 1])
        delegate.showPreview(name: "Цель", destination: start)
        XCTAssertNil(delegate.previewOffer)
    }

    // MARK: - Отмена навигации

    /// Окно отзвука — только после отмены ради списка и только один раз.
    func testOwnCancelEchoIsOnlyForThePreviewAndOnce() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var echo = CarPlayGuidanceMapping.PreviewCancelEcho()
        XCTAssertFalse(echo.consume(now: at), "своей отмены не было — решение системы")
        echo.note(.preview, now: at)
        XCTAssertTrue(echo.consume(now: at.addingTimeInterval(1)), "сразу после отмены ради списка")
        XCTAssertFalse(echo.consume(now: at.addingTimeInterval(1.1)), "второе событие — уже настоящая отмена")
        echo.note(.preview, now: at)
        XCTAssertFalse(echo.consume(now: at.addingTimeInterval(AppConfig.carPlayOwnCancelEchoSeconds)), "окно вышло")
    }

    /// Отмена при обычном конце поездки или `restartSession`: окно на неё не
    /// действует, настоящая отмена системы снимает маршрут как раньше.
    func testRegularCancelsOpenNoEchoWindow() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        for reason in [CarPlayGuidanceMapping.OwnCancel.tripEnded, .restart] {
            var echo = CarPlayGuidanceMapping.PreviewCancelEcho()
            echo.note(reason, now: at)
            XCTAssertFalse(echo.consume(now: at.addingTimeInterval(0.5)), "\(reason)")
            // И окно списка они закрывают: сессия после него уже другая.
            echo.note(.preview, now: at)
            echo.note(reason, now: at.addingTimeInterval(0.2))
            XCTAssertFalse(echo.consume(now: at.addingTimeInterval(0.5)), "\(reason) после списка")
        }
    }

    // MARK: - «Отмена» в списке

    func testCancelKeepsTheRouteOnlyWhenTheDriverDidNotCancelIt() {
        typealias Preview = CarPlayTripPreview
        XCTAssertFalse(Preview.cancelKeepsRoute(offered: false, tripActive: false, askedInCar: false),
                       "вне поездки — как было")
        XCTAssertFalse(Preview.cancelKeepsRoute(offered: false, tripActive: false, askedInCar: true))
        XCTAssertTrue(Preview.cancelKeepsRoute(offered: false, tripActive: true, askedInCar: false),
                      "поездка идёт, цель сменили на телефоне: водитель маршрут не отменял")
        XCTAssertFalse(Preview.cancelKeepsRoute(offered: false, tripActive: true, askedInCar: true),
                       "«Куда» поверх поездки: «Отмена» и значит «не туда»")
        XCTAssertTrue(Preview.cancelKeepsRoute(offered: true, tripActive: false, askedInCar: false), "из баннера")
    }
}
