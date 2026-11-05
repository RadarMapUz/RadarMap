//
//  CarPlayScenarioControlsTests.swift
//  RadarMapTests
//
//  Кнопки и баннеры машины — цепочкой событий, как их присылает шаблон:
//  осмотр через настоящую CarPlayMapModel (CarPlayBrowse внутри) и
//  CarPlayMapButtons; щипок — теми же долями кадра, что делит делегат
//  (`scale / pinchLast`); двойное касание «Дом» с экрана машины и с плитки —
//  через общий CarPlayTapGuard; очередь баннеров — через CarPlayBannerPolicy
//  с правилом «вытесненный вид возвращается сам». Строки матрицы —
//  docs/carplay_test_matrix.md, разделы «Кнопки» и «Оповещения».
//

import AVFoundation
import CoreGraphics
import XCTest
@testable import RadarMap

@MainActor
final class CarPlayScenarioControlsTests: XCTestCase {

    /// Одна модель на класс: освобождение @MainActor-класса посреди теста
    /// роняет рантайм (как в CarPlayEngineTests).
    private static let shared = CarPlayMapModel()
    private var closedPanning = 0

    private func freshModel() -> CarPlayMapModel {
        let model = Self.shared
        model.isPreviewing = false
        model.setFollowingForTesting(true)
        model.zoomBias = 0
        closedPanning = 0
        model.onClosePanning = { [weak self] in self?.closedPanning += 1 }
        return model
    }

    private func buttons(_ model: CarPlayMapModel, trip: Bool = true, panning: Bool) -> [CarPlayMapButtons.Kind] {
        CarPlayMapButtons.layout(tripActive: trip, following: model.isFollowing,
                                 panning: panning, previewing: model.isPreviewing)
    }

    /// Щипок так, как его разбирает делегат: начало жеста сбрасывает
    /// `pinchLast`, каждый кадр отдаёт модели долю к прошлому кадру.
    private func pinch(_ model: CarPlayMapModel, scales: [Double]) {
        model.pinchBegan()
        var last = 1.0
        for scale in scales where scale > 0 {
            model.pinch(scale: scale / last)
            last = scale
        }
    }

    // MARK: - Осмотр

    /// К-7: в поездке открыли осмотр, сдвинули карту, впереди камера. Осмотр
    /// закрывается сам (бар вернётся по событию шаблона), карта — у машины,
    /// и после события «осмотр закрыт» на месте весь набор поездки с
    /// «Радар!» первой (аудит 18.10, п. 1: «нет кнопок, где функционал»).
    func testCameraAheadClosesPanningAndBringsTheTripButtonsBack() {
        let model = freshModel()
        model.panningShown()
        XCTAssertEqual(buttons(model, panning: true), [.zoomIn, .zoomOut], "в осмотре — ровно зум")
        model.pan(by: CGSize(width: -30, height: 0))
        XCTAssertFalse(model.isFollowing)
        let recenters = model.recenterRequests
        model.returnOnAlert()
        XCTAssertEqual(closedPanning, 1, "осмотр закрыт возвратом, а не только карта")
        XCTAssertEqual(model.recenterRequests, recenters + 1)
        XCTAssertTrue(model.isFollowing)
        model.panningHidden()   // mapTemplateDidDismissPanningInterface
        XCTAssertEqual(buttons(model, panning: false), [.report, .zoomIn, .zoomOut, .pan])
        model.onClosePanning = nil
    }

    /// К-7б: осмотр без единого сдвига тоже закрывается камерой; карта и так
    /// у машины — лишнего «к себе» нет.
    func testUntouchedPanningIsClosedByACameraWithoutRecenter() {
        let model = freshModel()
        model.panningShown()
        let recenters = model.recenterRequests
        model.returnOnAlert()
        XCTAssertEqual(closedPanning, 1)
        XCTAssertEqual(model.recenterRequests, recenters)
        model.panningHidden()
        model.onClosePanning = nil
    }

    /// К-8: «Готово» после сдвига — карта стоит свободной, на четвёртом месте
    /// «к себе»; «к себе» — снова слежение и осмотр в один тап.
    func testDoneThenRecenterRestoresOneTapPanning() {
        let model = freshModel()
        model.panningShown()
        model.pan(by: CGSize(width: 0, height: 40))
        model.panningHidden()
        XCTAssertEqual(closedPanning, 0, "«Готово» — закрыла сама система")
        XCTAssertEqual(buttons(model, panning: false), [.report, .zoomIn, .zoomOut, .recenter(following: false)])
        model.recenter()
        XCTAssertTrue(model.isFollowing)
        XCTAssertEqual(buttons(model, panning: false), [.report, .zoomIn, .zoomOut, .pan])
        XCTAssertEqual(buttons(model, trip: false, panning: false),
                       [.zoomIn, .zoomOut, .pan, .recenter(following: true)], "без поездки — прежний набор")
        model.onClosePanning = nil
    }

    // MARK: - Щипок и зум

    /// К-9: щипок при слежении — поправка автозума шагами по удвоению, не
    /// больше потолка; остаток жеста не переходит в следующий (до 2.2.16
    /// накопленный масштаб умножался каждый кадр).
    func testPinchWhileFollowingShiftsAutoZoomByDoublings() {
        let model = freshModel()
        pinch(model, scales: [1.1, 1.4, 1.8, 2.2, 3.0, 4.1])
        XCTAssertEqual(model.zoomBias, 2, "×4,1 — два шага")
        XCTAssertTrue(model.isFollowing, "щипок при слежении — не осмотр")
        // Два неполных жеста по ×1,5 не складываются в шаг.
        model.zoomBias = 0
        pinch(model, scales: [1.2, 1.5])
        pinch(model, scales: [1.2, 1.5])
        XCTAssertEqual(model.zoomBias, 0)
        // Разведение пальцев в обратную сторону.
        pinch(model, scales: [0.8, 0.6, 0.45])
        XCTAssertEqual(model.zoomBias, -1)
        // Огромный жест упирается в потолок, а не уезжает в масштаб района.
        pinch(model, scales: [2, 4, 8, 16, 32, 64])
        XCTAssertEqual(model.zoomBias, AppConfig.carPlayZoomBiasLimit)
    }

    /// К-9б: щипок на свободной карте (после осмотра) двигает саму карту.
    func testPinchOnAFreeMapZoomsTheView() {
        let model = freshModel()
        model.pan(by: CGSize(width: 12, height: 0))
        let command = model.zoomCommand
        pinch(model, scales: [1.5, 2.5])
        XCTAssertEqual(model.zoomCommand, command + 1)
        XCTAssertEqual(model.zoomDelta, 1)
        XCTAssertEqual(model.zoomBias, 0, "поправка автозума не тронута")
        model.recenter()
    }

    // MARK: - Двойное касание

    /// К-3: «Дом» дважды — с экрана машины и сразу с плитки главного экрана:
    /// один запрос OSRM; «Работа» в эти секунды проходит; после постройки
    /// «Дом» снова доступен.
    func testDoubleTapHomeAcrossCarAndTileIsOneRequest() {
        var taps = CarPlayTapGuard()
        let home = SavedPlace(title: "Дом", lat: 41.3111, lon: 69.2797)
        let work = SavedPlace(title: "Работа", lat: 41.3400, lon: 69.3350)
        XCTAssertTrue(taps.begin(CarPlayTapGuard.routeKey(home)), "«Куда» → Дом")
        XCTAssertFalse(taps.begin(CarPlayTapGuard.routeKey(home)), "плитка → Дом, пока строится")
        XCTAssertTrue(taps.begin(CarPlayTapGuard.routeKey(work)), "передумал — другая цель")
        taps.end(CarPlayTapGuard.routeKey(home))
        XCTAssertTrue(taps.begin(CarPlayTapGuard.routeKey(home)))
    }

    // MARK: - Очередь баннеров

    /// Экран баннеров машины: CarPlay держит один, новый при видимом молча
    /// пропускает. Владельцы видов `comesBack` показывают своё снова, когда
    /// экран освободился, — в порядке `bannersFreed`.
    private struct Screen {
        typealias Kind = CarPlayBannerPolicy.Kind
        var showing: Kind?
        var waiting: [Kind] = []
        var lost: [Kind] = []
        /// Порядок, в котором делегат зовёт владельцев (bannersFreed).
        static let freedOrder: [Kind] = [.detour, .jam, .roadWeather, .question]

        mutating func offer(_ kind: Kind) {
            switch CarPlayBannerPolicy.decide(showing: showing, incoming: kind) {
            case .present:
                showing = kind
            case .replace:
                if let old = showing {
                    if old.comesBack { waiting.append(old) } else { lost.append(old) }
                }
                showing = kind
            case .wait:
                if !waiting.contains(kind) { waiting.append(kind) }
            case .drop:
                lost.append(kind)
            }
            waiting.removeAll { $0 == showing }
        }

        /// Баннер ушёл (камеру проехали, ответили, истёк): onIdle.
        mutating func dismiss() {
            showing = nil
            for kind in Self.freedOrder where waiting.contains(kind) {
                waiting.removeAll { $0 == kind }
                offer(kind)
            }
        }
    }

    /// О-4: одна поездка, все баннеры через одну очередь. Камера ни разу не
    /// ждёт и не теряется; объезд, пробка и вопрос, вытесненные камерой,
    /// возвращаются; опоздавшее подтверждение и устаревшее предложение — нет.
    func testOneTripThroughTheBannerQueue() {
        var screen = Screen()
        screen.offer(.suggestion)                 // «Куда едем?» стоя
        screen.offer(.camera)                     // тронулись — камера
        XCTAssertEqual(screen.showing, .camera)
        XCTAssertEqual(screen.lost, [.suggestion], "предложение одно на подключение — не возвращается")
        screen.offer(.detour)
        screen.offer(.jam)
        screen.offer(.info)                       // «Поездка началась» опоздала
        XCTAssertEqual(screen.showing, .camera)
        XCTAssertEqual(screen.waiting, [.detour, .jam])
        XCTAssertTrue(screen.lost.contains(.info))

        screen.dismiss()                          // камеру проехали
        XCTAssertEqual(screen.showing, .detour, "сначала объезд")
        XCTAssertEqual(screen.waiting, [.jam])

        screen.offer(.request)                    // водитель: «Завершить?»
        XCTAssertEqual(screen.showing, .request)
        XCTAssertEqual(Set(screen.waiting), [.detour, .jam], "вытесненный объезд вернётся")

        screen.offer(.camera)                     // следующая камера
        XCTAssertEqual(screen.showing, .camera)
        XCTAssertTrue(screen.lost.contains(.request), "устаревший ответ на касание не возвращается")

        screen.dismiss()
        XCTAssertEqual(screen.showing, .detour)
        screen.dismiss()                          // «Остаться»
        XCTAssertEqual(screen.showing, .jam)
        screen.offer(.question)                   // «радар ещё стоит?» стоя
        XCTAssertEqual(screen.showing, .jam, "пробка в сотнях метров важнее вопроса")
        XCTAssertEqual(screen.waiting, [.question])
        screen.dismiss()
        XCTAssertEqual(screen.showing, .question, "вопрос дождался")
        XCTAssertEqual(screen.waiting, [])
    }

    /// О-4б: камера приходит при любом баннере — показана сразу, при любой
    /// предыстории очереди.
    func testCameraIsNeverQueuedWhateverIsOnScreen() {
        let all: [CarPlayBannerPolicy.Kind] = [.info, .suggestion, .question, .roadWeather, .jam, .detour,
                                               .request, .camera]
        for first in all {
            for second in all {
                var screen = Screen()
                screen.offer(first)
                screen.offer(second)
                screen.offer(.camera)
                XCTAssertEqual(screen.showing, .camera, "\(first) → \(second) → камера")
                XCTAssertFalse(screen.waiting.contains(.camera))
            }
        }
    }

    // MARK: - Камера впереди: чем видна в машине

    /// О-1 / Д-2: чужая камера на подъезде — баннер, подпись у значка и
    /// возврат карты; своя камера (голос молчит) — ни баннера, ни подписи.
    func testFamiliarCameraGetsNoBannerButAForeignOneDoes() {
        let foreign = CarPlayCameraCue.decide(cameraID: 501, approaching: true, familiar: false)
        XCTAssertTrue(foreign.banner)
        XCTAssertTrue(foreign.distanceLabel)
        XCTAssertEqual(foreign.mapAlertID, 501)
        let own = CarPlayCameraCue.decide(cameraID: 501, approaching: true, familiar: true)
        XCTAssertEqual(own, .none)
        XCTAssertEqual(CarPlayCameraCue.decide(cameraID: 501, approaching: false, familiar: false), .none,
                       "стоя у камеры — не подъезд")
    }

    /// О-1б: баннер камеры на нашем экране обновляет расстояние не чаще раза
    /// в секунду и переживает секундную потерю той же камеры (фикс отброшен
    /// фильтром), а смену камеры — нет.
    func testCameraBannerCountsDownAndSurvivesADropout() {
        let interval = AppConfig.carPlayCameraBannerUpdateSeconds
        var shown: CarPlayCameraBannerText.Text?
        var updates = 0
        var sinceLast = Double.infinity
        // 60 км/ч, фикс раз в 0,5 с, от 600 м до 0; на экране — метры кратно 10.
        var meters = 600.0
        while meters >= 0 {
            let distance = "\(Int((meters / 10).rounded() * 10)) м"
            let text = CarPlayCameraBannerText.text(name: "Камера", kind: "Радар", distance: distance, limit: 60)
            if CarPlayCameraBannerText.shouldUpdate(shown: shown, new: text, sinceLast: sinceLast, interval: interval) {
                XCTAssertTrue(text.titles.allSatisfy { $0.contains(distance) }, distance)
                shown = text
                updates += 1
                sinceLast = 0
            }
            sinceLast += 0.5
            meters -= 60 / 3.6 * 0.5
        }
        let seconds = 600 / (60 / 3.6)
        XCTAssertLessThanOrEqual(Double(updates), seconds / interval + 1, "не чаще раза в секунду")
        XCTAssertGreaterThanOrEqual(updates, Int(seconds / interval) - 1, "и не реже")
        XCTAssertTrue(CarPlayCameraBannerText.keepsThroughDropout(sameCamera: true, lostFor: 1))
        XCTAssertFalse(CarPlayCameraBannerText.keepsThroughDropout(sameCamera: false, lostFor: 0.1))
        XCTAssertFalse(CarPlayCameraBannerText.keepsThroughDropout(
            sameCamera: true, lostFor: AppConfig.carPlayCameraBannerGraceSeconds))
    }

    /// О-5: голос в машине по promptStyle — звонок: тон вместо фразы; Siri
    /// слушает: тишина; иначе фраза.
    func testVoiceFollowsThePromptStyle() {
        XCTAssertEqual(VoicePrompt.mode(for: .short), .tone)
        XCTAssertEqual(VoicePrompt.mode(for: .none), .silent)
        XCTAssertEqual(VoicePrompt.mode(for: .normal), .speech)
    }

    /// О-6: GPS пропал во время ведения — пауза «ищу сигнал» (iOS 27),
    /// перестроение важнее; сигнал вернулся — пауза снята; чип «Нет сигнала
    /// GPS» уступает карточке системы и возвращается, когда она снята.
    func testSignalLossAndRerouteChainNeverLeavesTheCardStuck() {
        typealias P = CarPlayGuidancePause
        var current: P.Reason?
        var steps: [P.Step] = []
        let ticks: [(rerouting: Bool, stale: Bool)] = [
            (false, false), (false, true), (true, true), (true, false), (false, false), (false, false),
        ]
        for tick in ticks {
            let wanted = P.wanted(rerouting: tick.rerouting, signalStale: tick.stale, hasManeuver: true,
                                  locatingEnabled: true)
            let step = P.step(current: current, wanted: wanted)
            steps.append(step)
            switch step {
            case .none: break
            case .pause(let reason): current = reason
            case .resume: current = nil
            }
            XCTAssertEqual(P.showsGPSChip(signalStale: tick.stale, systemLocating: current == .locating),
                           tick.stale && current != .locating)
        }
        XCTAssertEqual(steps, [.none, .pause(.locating), .pause(.rerouting), .none, .resume, .none])
        XCTAssertNil(current, "карточка не застряла на паузе")
    }
}
