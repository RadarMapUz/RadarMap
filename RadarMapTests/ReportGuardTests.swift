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
    /// Принятый фикс секунду назад, 8 м, поездка.
    private let good = ReportGuard.Fix(isCoarse: false, isSignalStale: false, accuracy: 8,
                                       age: 1, isContinuous: true)

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
        // Перекрытие и ремонт (12б.5) — вторым рядом, когда сервер их знает.
        XCTAssertEqual(Set(ReportKind.offered + ReportKind.roadOffered), Set(ReportKind.allCases),
                       "тип есть на сервере, а нажать его негде")
    }

    func testReportGoesThroughWhileDriving() {
        XCTAssertNil(ReportGuard.check(kind: .radar, coordinate: me, speedKmh: 60,
                                       isTripActive: true, fix: good, lastSent: nil, now: now))
    }

    func testDoubleTapIsRefusedAsDuplicate() {
        // Нажали дважды «на всякий случай» — вторая отметка не уедет.
        let sent = ReportGuard.Sent(kind: .radar, latitude: me.latitude,
                                    longitude: me.longitude, at: now.addingTimeInterval(-5))
        XCTAssertEqual(ReportGuard.check(kind: .radar, coordinate: me, speedKmh: 60,
                                         isTripActive: true, fix: good, lastSent: sent, now: now),
                       .duplicate)
    }

    func testSamePlaceAfterWindowIsAllowed() {
        // Через полчаса на том же месте — уже новая информация: патруль мог
        // приехать снова, и молчать об этом неправильно.
        let sent = ReportGuard.Sent(kind: .radar, latitude: me.latitude,
                                    longitude: me.longitude, at: now.addingTimeInterval(-1800))
        XCTAssertNil(ReportGuard.check(kind: .radar, coordinate: me, speedKmh: 60,
                                       isTripActive: true, fix: good, lastSent: sent, now: now))
    }

    func testFarEnoughIsANewReport() {
        // Проехали километр и увидели второй пост — это другая точка.
        let sent = ReportGuard.Sent(kind: .radar, latitude: me.latitude,
                                    longitude: me.longitude, at: now.addingTimeInterval(-30))
        XCTAssertNil(ReportGuard.check(kind: .radar, coordinate: point(metresEast: 1000),
                                       speedKmh: 60, isTripActive: true,
                                       fix: good, lastSent: sent, now: now))
    }

    func testDifferentKindIsNotADuplicate() {
        // Радар и ДТП на одном месте — разные вещи, обе полезны.
        let sent = ReportGuard.Sent(kind: .radar, latitude: me.latitude,
                                    longitude: me.longitude, at: now.addingTimeInterval(-5))
        XCTAssertNil(ReportGuard.check(kind: .accident, coordinate: me, speedKmh: 60,
                                       isTripActive: true, fix: good, lastSent: sent, now: now))
    }

    func testReportFromHomeIsRefused() {
        // Стоим, поездки нет — почти всегда это проверка «как оно работает».
        // Такая отметка ставит радар посреди двора для всех соседей.
        XCTAssertEqual(ReportGuard.check(kind: .radar, coordinate: me, speedKmh: 0,
                                         isTripActive: false, fix: good, lastSent: nil, now: now),
                       .notDriving)
    }

    func testStandingInTrafficDuringTripIsAllowed() {
        // В пробке рядом с патрулём отметить НАДО — это самая ценная точка.
        XCTAssertNil(ReportGuard.check(kind: .radar, coordinate: me, speedKmh: 0,
                                       isTripActive: true, fix: good, lastSent: nil, now: now))
    }

    func testNoPositionIsRefused() {
        XCTAssertEqual(ReportGuard.check(kind: .radar, coordinate: nil, speedKmh: 60,
                                         isTripActive: true, fix: good, lastSent: nil, now: now),
                       .noPosition)
        // Нулевая координата — не Атлантика, а «фикса ещё нет».
        XCTAssertEqual(ReportGuard.check(kind: .radar,
                                         coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                         speedKmh: 60, isTripActive: true,
                                         fix: good, lastSent: nil, now: now),
                       .noPosition)
    }

    // MARK: - Своя точка для слепой отметки (ловец багов, 39)

    func testCoarsePointIsNotAPlaceForAReport() {
        // Телефон под стеклом: фильтр бракует фиксы, на экране грубая точка
        // для картинки. Отметка по ней встала бы в сотнях метров от засады.
        var coarse = good
        coarse.isCoarse = true
        XCTAssertEqual(ReportGuard.check(kind: .radar, coordinate: me, speedKmh: 60, isTripActive: true,
                                         fix: coarse, lastSent: nil, now: now), .noPosition)
    }

    func testLostSignalAndPoorAccuracyAreRefused() {
        var lost = good
        lost.isSignalStale = true
        XCTAssertFalse(ReportGuard.isTrusted(lost))
        var poor = good
        poor.accuracy = AppConfig.reportMaxFixAccuracyMeters + 1
        XCTAssertFalse(ReportGuard.isTrusted(poor))
        var unknownAccuracy = good
        unknownAccuracy.accuracy = -1
        XCTAssertTrue(ReportGuard.isTrusted(unknownAccuracy), "неизвестная погрешность — не повод молчать")
        var never = good
        never.age = nil
        XCTAssertFalse(ReportGuard.isTrusted(never), "ни одного принятого фикса")
    }

    func testSiriInSilentModeNeedsAFreshFix() {
        // Тихий фон: последняя точка — значимое перемещение, может быть,
        // километры назад. Нужен свежий фикс, а не «последний известный».
        let silent = ReportGuard.Fix(isCoarse: false, isSignalStale: false, accuracy: 20,
                                     age: AppConfig.reportMaxFixAgeSeconds + 5, isContinuous: false)
        XCTAssertFalse(ReportGuard.isTrusted(silent))
        var fresh = silent
        fresh.age = 2
        XCTAssertTrue(ReportGuard.isTrusted(fresh))
    }

    func testStandingInAJamKeepsAMinuteOldFix() {
        // Непрерывный GPS, стоим у поста: фиксов нет из-за фильтра
        // расстояния, и минутная точка — всё ещё правда.
        var jam = good
        jam.age = 90
        XCTAssertTrue(ReportGuard.isTrusted(jam))
        jam.age = AppConfig.reportMaxFixAgeContinuousSeconds + 1
        XCTAssertFalse(ReportGuard.isTrusted(jam), "открыли после стоянки — фикса ещё не было")
    }

    func testDeliberatePlacementNeedsNoFix() {
        // Точку показали пальцем на карте — своя позиция тут ни при чём.
        XCTAssertNil(ReportGuard.check(kind: .tripod, coordinate: me, speedKmh: 0, isTripActive: false,
                                       placement: .deliberate, fix: nil, lastSent: nil, now: now))
        XCTAssertEqual(ReportGuard.check(kind: .radar, coordinate: me, speedKmh: 60, isTripActive: true,
                                         fix: nil, lastSent: nil, now: now), .noPosition,
                       "слепой тап без сведений о фиксе — не отправляем")
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

    func testDoesNotAskAboutOwnReport() {
        // Свою отметку водитель видел сам, а его голос сервер не засчитает
        // (тот же телефон) — вопрос о ней был бы пустым тапом за рулём.
        let own = mobileCamera(id: 5, metresEast: 0)
        let other = mobileCamera(id: 6, metresEast: 30)
        var tracks: [Int: MobilePassWatch.Track] = [:]
        _ = MobilePassWatch.update(tracks: &tracks, mobileCameras: [own, other],
                                   from: point(metresEast: -10), excluded: [own.id])
        XCTAssertEqual(MobilePassWatch.update(tracks: &tracks, mobileCameras: [own, other],
                                              from: point(metresEast: 250), excluded: [own.id]),
                       other.id)
        XCTAssertNil(MobilePassWatch.update(tracks: &tracks, mobileCameras: [own, other],
                                            from: point(metresEast: 300), excluded: [own.id]))
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

    func testBusyQuestionSlotDoesNotLoseTheNextPoint() {
        // Висит вопрос о прошлой точке — проехали вторую: о ней спросим,
        // когда слот освободится, а не никогда (ловец багов, 39).
        let camera = mobileCamera(id: 7, metresEast: 0)
        var tracks: [Int: MobilePassWatch.Track] = [:]
        _ = MobilePassWatch.update(tracks: &tracks, mobileCameras: [camera],
                                   from: point(metresEast: -10), canAsk: false)
        XCTAssertNil(MobilePassWatch.update(tracks: &tracks, mobileCameras: [camera],
                                            from: point(metresEast: 220), canAsk: false))
        XCTAssertEqual(MobilePassWatch.update(tracks: &tracks, mobileCameras: [camera],
                                              from: point(metresEast: 260), canAsk: true), camera.id)
    }

    func testDelayedQuestionRemembersWhenThePassHappened() {
        // Вопрос ждал занятого слота — ответ уходит с возрастом проезда, а не
        // тапа: старое «стоит» сервер не продлевает (ловец багов, 40a).
        let camera = mobileCamera(id: 8, metresEast: 0)
        var tracks: [Int: MobilePassWatch.Track] = [:]
        _ = MobilePassWatch.update(tracks: &tracks, mobileCameras: [camera],
                                   from: point(metresEast: -10), canAsk: false, now: now)
        _ = MobilePassWatch.update(tracks: &tracks, mobileCameras: [camera],
                                   from: point(metresEast: 220), canAsk: false, now: now.addingTimeInterval(20))
        _ = MobilePassWatch.update(tracks: &tracks, mobileCameras: [camera],
                                   from: point(metresEast: 900), canAsk: true, now: now.addingTimeInterval(300))
        XCTAssertEqual(tracks[camera.id]?.departedAt, now.addingTimeInterval(20))
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
                                        fix: good, lastSent: nil, now: Date())
        XCTAssertNil(refusal)
    }

    func testBlindTapWhileParkedIsStillRefused() {
        let refusal = ReportGuard.check(kind: .radar,
                                        coordinate: CLLocationCoordinate2D(latitude: 41.31,
                                                                           longitude: 69.25),
                                        speedKmh: 0, isTripActive: false,
                                        placement: .blind,
                                        fix: good, lastSent: nil, now: Date())
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
                                        fix: good, lastSent: sent, now: Date())
        XCTAssertEqual(refusal, .duplicate)
    }

}
