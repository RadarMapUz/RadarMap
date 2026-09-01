//
//  ReportGuardTests.swift
//  RadarMapTests
//
//  Кнопка «Радар!» и вопрос «ещё стоял?» — два конца одной петли
//  краудсорсинга. Тесты здесь почти целиком про то, что НЕ должно уехать на
//  сервер: дубль от двойного нажатия, отметка из дома, вопрос без проезда,
//  голос за молчание. Каждая такая запись портит карту всем сразу, а
//  пропущенная стоит одного радара, который через минуту отметит следующий.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class ReportGuardTests: XCTestCase {

    private let me = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.25)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func point(metresEast: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: me.latitude,
                               longitude: me.longitude
                                   + metresEast / (111_320 * cos(me.latitude * .pi / 180)))
    }

    // MARK: - Кнопка «Радар!»

    /// Пост ДПС снова предлагается рукой — по прямой просьбе водителя.
    ///
    /// Тип был в коде, но не в пикере (риск по Guideline 1.4.4), и отметить
    /// пост было нечем: «радар» его не заменяет — у поста и время жизни
    /// другое, шесть часов против трёх.
    func testEveryKindTheServerKnowsCanBeTapped() {
        XCTAssertEqual(Set(ReportKind.offered), Set(ReportKind.allCases),
                       "тип есть на сервере, а нажать его негде")
    }

    func testReportGoesThroughWhileDriving() {
        XCTAssertNil(ReportGuard.check(kind: .radar, coordinate: me, speedKmh: 60,
                                       isTripActive: true, lastSent: nil, now: now))
    }

    func testDoubleTapIsRefusedAsDuplicate() {
        // Нажали дважды «на всякий случай» — вторая отметка не уедет.
        let sent = ReportGuard.Sent(kind: .radar, latitude: me.latitude,
                                    longitude: me.longitude, at: now.addingTimeInterval(-5))
        XCTAssertEqual(ReportGuard.check(kind: .radar, coordinate: me, speedKmh: 60,
                                         isTripActive: true, lastSent: sent, now: now),
                       .duplicate)
    }

    func testSamePlaceAfterWindowIsAllowed() {
        // Через полчаса на том же месте — уже новая информация: патруль мог
        // приехать снова, и молчать об этом неправильно.
        let sent = ReportGuard.Sent(kind: .radar, latitude: me.latitude,
                                    longitude: me.longitude, at: now.addingTimeInterval(-1800))
        XCTAssertNil(ReportGuard.check(kind: .radar, coordinate: me, speedKmh: 60,
                                       isTripActive: true, lastSent: sent, now: now))
    }

    func testFarEnoughIsANewReport() {
        // Проехали километр и увидели второй пост — это другая точка.
        let sent = ReportGuard.Sent(kind: .radar, latitude: me.latitude,
                                    longitude: me.longitude, at: now.addingTimeInterval(-30))
        XCTAssertNil(ReportGuard.check(kind: .radar, coordinate: point(metresEast: 1000),
                                       speedKmh: 60, isTripActive: true,
                                       lastSent: sent, now: now))
    }

    func testDifferentKindIsNotADuplicate() {
        // Радар и ДТП на одном месте — разные вещи, обе полезны.
        let sent = ReportGuard.Sent(kind: .radar, latitude: me.latitude,
                                    longitude: me.longitude, at: now.addingTimeInterval(-5))
        XCTAssertNil(ReportGuard.check(kind: .accident, coordinate: me, speedKmh: 60,
                                       isTripActive: true, lastSent: sent, now: now))
    }

    func testReportFromHomeIsRefused() {
        // Стоим, поездки нет — почти всегда это проверка «как оно работает».
        // Такая отметка ставит радар посреди двора для всех соседей.
        XCTAssertEqual(ReportGuard.check(kind: .radar, coordinate: me, speedKmh: 0,
                                         isTripActive: false, lastSent: nil, now: now),
                       .notDriving)
    }

    func testStandingInTrafficDuringTripIsAllowed() {
        // В пробке рядом с патрулём отметить НАДО — это самая ценная точка.
        XCTAssertNil(ReportGuard.check(kind: .radar, coordinate: me, speedKmh: 0,
                                       isTripActive: true, lastSent: nil, now: now))
    }

    func testNoPositionIsRefused() {
        XCTAssertEqual(ReportGuard.check(kind: .radar, coordinate: nil, speedKmh: 60,
                                         isTripActive: true, lastSent: nil, now: now),
                       .noPosition)
        // Нулевая координата — не Атлантика, а «фикса ещё нет».
        XCTAssertEqual(ReportGuard.check(kind: .radar,
                                         coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                         speedKmh: 60, isTripActive: true,
                                         lastSent: nil, now: now),
                       .noPosition)
    }

    // MARK: - Вопрос «радар ещё стоял?»

    private func mobileCamera(id: Int, metresEast: Double) -> Camera {
        let coordinate = point(metresEast: metresEast)
        return Camera(id: MobileCameraService.idOffset + id, region: "", city: "",
                      location: "Отмечен водителями", lat: coordinate.latitude,
                      lon: coordinate.longitude, type: "Мобильный радар",
                      violations: [], needsReview: nil)
    }

    func testAsksOnlyAfterActuallyPassingBy() {
        let camera = mobileCamera(id: 1, metresEast: 0)
        var tracks: [Int: MobilePassWatch.Track] = [:]

        // Подъезжаем — рано: водитель ещё не видел, что там.
        XCTAssertNil(MobilePassWatch.update(tracks: &tracks, mobileCameras: [camera],
                                            from: point(metresEast: -300)))
        // Вплотную — тоже рано: сейчас надо смотреть на дорогу.
        XCTAssertNil(MobilePassWatch.update(tracks: &tracks, mobileCameras: [camera],
                                            from: point(metresEast: -20)))
        // Отъехали — вот теперь ответ достоверен.
        XCTAssertEqual(MobilePassWatch.update(tracks: &tracks, mobileCameras: [camera],
                                              from: point(metresEast: 250)),
                       camera.id)
    }

    func testDoesNotAskWhenPassedFarAside() {
        // Проехали в трёхстах метрах по параллельной улице — видеть радар
        // водитель не мог, и его «нет» удалило бы честную точку.
        let camera = mobileCamera(id: 2, metresEast: 0)
        var tracks: [Int: MobilePassWatch.Track] = [:]
        _ = MobilePassWatch.update(tracks: &tracks, mobileCameras: [camera],
                                   from: point(metresEast: -320))
        XCTAssertNil(MobilePassWatch.update(tracks: &tracks, mobileCameras: [camera],
                                            from: point(metresEast: 320)))
    }

    func testAsksOnlyOncePerPoint() {
        let camera = mobileCamera(id: 3, metresEast: 0)
        var tracks: [Int: MobilePassWatch.Track] = [:]
        _ = MobilePassWatch.update(tracks: &tracks, mobileCameras: [camera],
                                   from: point(metresEast: -10))
        XCTAssertEqual(MobilePassWatch.update(tracks: &tracks, mobileCameras: [camera],
                                              from: point(metresEast: 200)), camera.id)
        // Дальше по дороге — второй раз о том же не спрашиваем.
        XCTAssertNil(MobilePassWatch.update(tracks: &tracks, mobileCameras: [camera],
                                            from: point(metresEast: 400)))
    }

    func testForgetsPointsThatExpired() {
        // Точка истекла на сервере — её наблюдение не должно жить в памяти
        // всю поездку.
        let camera = mobileCamera(id: 4, metresEast: 0)
        var tracks: [Int: MobilePassWatch.Track] = [:]
        _ = MobilePassWatch.update(tracks: &tracks, mobileCameras: [camera], from: me)
        XCTAssertEqual(tracks.count, 1)
        _ = MobilePassWatch.update(tracks: &tracks, mobileCameras: [], from: me)
        XCTAssertTrue(tracks.isEmpty)
    }

    func testAsksAboutOnePointPerTick() {
        // Две отметки рядом — два вопроса подряд за рулём это шум.
        let first = mobileCamera(id: 5, metresEast: 0)
        let second = mobileCamera(id: 6, metresEast: 30)
        var tracks: [Int: MobilePassWatch.Track] = [:]
        _ = MobilePassWatch.update(tracks: &tracks, mobileCameras: [first, second],
                                   from: point(metresEast: 10))
        let asked = MobilePassWatch.update(tracks: &tracks, mobileCameras: [first, second],
                                           from: point(metresEast: 260))
        XCTAssertNotNil(asked)
        // Обе отмечены как спрошенные — второй вопрос не выскочит следом.
        XCTAssertNil(MobilePassWatch.update(tracks: &tracks, mobileCameras: [first, second],
                                            from: point(metresEast: 300)))
    }
    // MARK: - Откуда взялась координата

    func testDeliberatePlacementIsAllowedWhileParked() {
        // Точку показали пальцем на карте и выбрали тип из списка — это не
        // слепой тап «а как оно работает», это осознанная постановка. Глушить
        // её проверкой на стоянку значит терять отметки пассажира и того, кто
        // отмечает на обочине сразу после проезда.
        let refusal = ReportGuard.check(kind: .tripod,
                                        coordinate: CLLocationCoordinate2D(latitude: 41.31,
                                                                           longitude: 69.25),
                                        speedKmh: 0, isTripActive: false,
                                        placement: .deliberate,
                                        lastSent: nil, now: Date())
        XCTAssertNil(refusal)
    }

    func testBlindTapWhileParkedIsStillRefused() {
        let refusal = ReportGuard.check(kind: .radar,
                                        coordinate: CLLocationCoordinate2D(latitude: 41.31,
                                                                           longitude: 69.25),
                                        speedKmh: 0, isTripActive: false,
                                        placement: .blind,
                                        lastSent: nil, now: Date())
        XCTAssertEqual(refusal, .notDriving, "тап из кресла дома рождает радар посреди двора")
    }

    func testDeliberatePlacementStillObeysTheDuplicateGuard() {
        // Осознанность снимает только проверку на стоянку. Дубли она не
        // легализует: пять отметок на один пост портят карту всем одинаково,
        // кто бы их ни поставил.
        let point = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.25)
        let sent = ReportGuard.Sent(kind: .radar, latitude: point.latitude,
                                    longitude: point.longitude, at: Date())
        let refusal = ReportGuard.check(kind: .radar, coordinate: point,
                                        speedKmh: 0, isTripActive: false,
                                        placement: .deliberate,
                                        lastSent: sent, now: Date())
        XCTAssertEqual(refusal, .duplicate)
    }

}
