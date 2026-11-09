//
//  CarPlaySceneDelegate+ChoiceOffer.swift
//  RadarMap
//
//  «Другой путь быстрее…» — баннер после устойчивой стоянки для
//  маршрута, построенного на ходу. Решение — CarPlayRouteChoiceOffer (чистое),
//  здесь — входы, баннер и открытие списка по касанию.
//
//  Ведение баннер не трогает. Сессия навигации закрывается только по касанию
//  «Показать» (CarPlayGuidance.yieldToPreview — до показа списка), и после его
//  закрытия к той же цели начинается заново: ни двух сессий, ни сессии без
//  манёвров.
//

import CarPlay
import CoreLocation
import MapKit
import os

extension CarPlaySceneDelegate {

    /// Опознание набора вариантов маршрута; nil — маршрута нет. Перестроение
    /// и объезд дают новый набор из одного варианта и предложения не вызывают.
    func choiceOfferKey() -> Int? {
        let variants = env.route.variants
        return variants.isEmpty ? nil : CarPlayTripPreview.identity(variants).hashValue
    }

    /// Скорость читается, только пока вопрос открыт или баннер на экране: для
    /// маршрута без вариантов и после ответа фиксы сюда не доходят.
    func observeChoiceOffer() {
        let session = session
        evaluateChoiceOffer()
        withObservationTracking {
            _ = env.route.variants
            _ = model.isPreviewing
            _ = model.isOnScreen
            _ = env.location.isSignalStale
            if env.route.variants.count >= 2, Self.choiceOffer.isOpen || choiceOfferAlert != nil {
                _ = env.location.speedKmh
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                self.observeChoiceOffer()
            }
        }
    }

    func evaluateChoiceOffer() {
        guard Self.activeDelegate === self else { return }
        let route = env.route
        let location = env.location
        let key = choiceOfferKey()
        // Тронулись, маршрут сменился или снят (отмена системой) — баннер
        // больше не о том: списка на ходу не бывает.
        if let alert = choiceOfferAlert,
           key != choiceOfferRoute || !CarPlayTripPreview.shouldPreview(speedKmh: location.speedKmh) {
            choiceOfferAlert = nil
            banners?.dismiss(alert)
        }
        let phase = NavigationFlow.phase(hasRoute: route.isActive, isTripActive: location.isTripActive)
        let situation = CarPlayRouteChoiceOffer.Situation(
            route: key, variantCount: route.variants.count, speedKmh: location.speedKmh,
            along: route.progressAlong, length: route.selected?.distance ?? 0,
            cameraAhead: CarPlayCameraCue.current(location).banner,
            screenFree: rootShown && model.isOnScreen && shownTemplate == nil && !model.isPreviewing
                && choiceOfferAlert == nil,
            phonePanelOpen: phase == .choosing && env.isPhoneSceneActive && env.phoneMapOverride,
            busy: route.isBuilding || route.isRerouting || route.isOffRoute || route.detourOffer != nil,
            signalLost: location.isSignalStale)
        let decision = Self.choiceOffer.update(situation, inJam: choiceOfferInJam(), now: Date())
        choiceOfferCheck?.cancel()
        choiceOfferCheck = nil
        switch decision {
        case .none:
            break
        case .check(let seconds):
            scheduleChoiceOfferCheck(after: seconds)
        case .ready:
            presentChoiceOffer(key: key)
        }
    }

    private func scheduleChoiceOfferCheck(after seconds: TimeInterval) {
        choiceOfferCheck = Task { @MainActor [weak self] in
            await Task.pause(seconds: seconds)
            guard let self, !Task.isCancelled else { return }
            self.evaluateChoiceOffer()
        }
    }

    /// Стоим в пробке на своём пути (те же данные, что у вида на остановке).
    private func choiceOfferInJam() -> Bool {
        guard env.traffic.isShown, let snapshot = env.traffic.snapshot,
              let here = env.location.displayCoordinate ?? env.location.currentCoordinate,
              let path = env.route.pathAhead(from: here, meters: AppConfig.stopViewJamMaxMeters
                                                + AppConfig.stopViewJamGapMeters) else { return false }
        return StopView.jamEnd(path: path) { point, course in
            snapshot.matchingEdge(at: point, course: course)?.level
        } != nil
    }

    private func presentChoiceOffer(key: Int?) {
        // Занятый экран — сначала: дальше проекции всех вариантов на главном.
        switch CarPlayBannerPolicy.decide(showing: banners?.showingKind, incoming: .suggestion) {
        case .wait, .drop:
            scheduleChoiceOfferCheck(after: AppConfig.carPlayChoiceOfferRecheckSeconds)
            return
        case .present, .replace:
            break
        }
        let route = env.route
        let here = env.location.currentCoordinate ?? env.location.displayCoordinate
        let variants = route.variants.map { variant -> CarPlayRouteChoiceOffer.Variant in
            let spot = here.map { Self.project($0, on: variant) }
            return CarPlayRouteChoiceOffer.variant(
                id: variant.id, shownSeconds: variant.shownTime, distance: variant.distance,
                along: spot?.along ?? 0, deviation: spot?.deviation ?? .infinity,
                cameraAlongs: variant.cameras.filter(\.countsAsOurs).map(\.distanceAlong),
                labeled: !variant.assessment.labels.isEmpty)
        }
        let choices = CarPlayRouteChoiceOffer.choices(selected: route.selectedID, variants: variants)
        guard choices.count >= 2, let key else {
            Log.carplay.notice("выбор после остановки: выбирать не из чего, вариантов \(variants.count, privacy: .public)")
            Self.choiceOffer.spend(route: key)
            return
        }
        let gain = CarPlayRouteChoiceOffer.gain(selected: route.selectedID, variants: variants, choices: choices,
                                                trafficKnown: env.traffic.snapshot?.isFresh(now: Date()) == true)
        let titles = switch gain {
        case .faster(let minutes): [String(format: String(localized: "Другой путь быстрее на %lld мин"), minutes),
                                    String(format: String(localized: "Быстрее на %lld мин"), minutes)]
        case .fewerCameras(let count): [String(format: String(localized: "На другом пути камер меньше на %lld"), count),
                                        String(format: String(localized: "Камер меньше на %lld"), count)]
        case .other: [String(localized: "Можно выбрать другой путь"), String(localized: "Другой путь")]
        }
        let alert = CPNavigationAlert(
            titleVariants: titles,
            subtitleVariants: [String(localized: "Пока стоим — покажу варианты")],
            image: CarPlayGuidance.symbol("arrow.triangle.branch", pointSize: 30,
                                          onDark: model.carIsDark ?? !model.isDaylight),
            primaryAction: CPAlertAction(title: String(localized: "Показать"), style: .default) { [weak self] _ in
                self?.showOfferedChoice(key: key, ids: Set(choices))
            },
            secondaryAction: CPAlertAction(title: String(localized: "Остаться"), style: .cancel) { _ in
                Log.carplay.notice("выбор после остановки: остаёмся")
            },
            duration: AppConfig.carPlayChoiceOfferSeconds)
        // Занятый экран (вопрос, объезд, камера) — попытка не тратится.
        guard banners?.show(alert, kind: .suggestion) == true else {
            scheduleChoiceOfferCheck(after: AppConfig.carPlayChoiceOfferRecheckSeconds)
            return
        }
        choiceOfferAlert = alert
        choiceOfferRoute = key
        Self.choiceOffer.spend(route: key)
        Log.carplay.notice("выбор после остановки: предлагаю, вариантов \(choices.count, privacy: .public)")
    }

    /// Где машина на линии варианта и как далеко от неё.
    private static func project(_ coordinate: CLLocationCoordinate2D,
                                on variant: RouteService.Variant) -> (along: Double, deviation: Double) {
        var hint = 0
        return RouteService.project(MKMapPoint(coordinate), onto: variant.points,
                                    cum: RouteService.cumulative(of: variant.points), hint: &hint)
    }

    /// Сменить вариант посреди пути. `selectVariant` обнуляет прогресс, а обратно
    /// его считает только сдвиг на 2 м: стоя при ровном GPS этого может не быть
    /// всю стоянку. Пока прогресс 0, камера в 300 м считается за 1300 м и молчит,
    /// проеханная становится «нашей», новая сессия висит на «загружаю» без манёвра.
    /// Поэтому прогресс — сразу от текущей точки, без голоса.
    static func switchVariant(_ id: Int, route: RouteService, at coordinate: CLLocationCoordinate2D?,
                              cameras: [Camera], course: CLLocationDirection, speedKmh: Double) {
        let changed = id != route.selectedID
        route.selectVariant(id)
        guard changed, let coordinate else { return }
        route.updateProgress(coordinate: coordinate, cameras: cameras, announce: false,
                             course: course, speedKmh: speedKmh)
    }

    func switchVariant(_ id: Int) {
        let location = env.location
        Self.switchVariant(id, route: env.route, at: location.currentCoordinate ?? location.displayCoordinate,
                           cameras: env.cameras.cameras, course: location.routeHeading ?? -1,
                           speedKmh: location.speedKmh)
    }

    /// «Показать»: только теперь — список. За секунды показа могли и тронуться,
    /// и сменить маршрут: тогда касание ничего не открывает.
    private func showOfferedChoice(key: Int, ids: Set<Int>) {
        let route = env.route
        guard key == choiceOfferKey(), !model.isPreviewing,
              CarPlayTripPreview.shouldPreview(speedKmh: env.location.speedKmh),
              // Без сигнала скорость 0 ничего не значит: может, мы едем.
              !env.location.isSignalStale,
              let destination = route.destinationCoordinate else {
            Log.carplay.notice("выбор после остановки: касание устарело")
            return
        }
        Log.carplay.notice("выбор после остановки: открываю список")
        model.isPreviewing = true
        guidance.yieldToPreview()
        showPreview(name: route.destinationName, destination: destination,
                    offer: (key, route.selectedID, ids))
    }

    /// Какие варианты в списке: из баннера — заметно другие и выбранный, иначе все.
    var previewVariants: [RouteService.Variant] {
        let all = env.route.variants
        guard let offer = previewOffer, offer.route == choiceOfferKey() else { return all }
        return all.filter { offer.ids.contains($0.id) || $0.id == env.route.selectedID }
    }

    /// «Отмена» в списке из баннера: едем тем же вариантом, что до него, если
    /// маршрут за это время не заменили.
    func closeOfferedPreview() {
        if let offer = previewOffer, offer.route == choiceOfferKey() {
            switchVariant(offer.origin)
        }
        endPreview(start: false, keepRoute: true, reason: "остаёмся на прежнем варианте")
    }

    /// Ушли с экрана машины при открытом списке из баннера. Сессию до него
    /// закрыли мы; система нас не отменит, а когда машина тронется, MovingWatch
    /// начал бы её заново — поверх чужого навигатора (правило D1). Ведение
    /// возвращается сейчас, и чужой навигатор снимет его обычной отменой.
    /// Обычный список — без сессии до него — остаётся как был.
    func closeOfferedPreviewOnLeaving() {
        guard previewOffer != nil else { return }
        closeOfferedPreview()
    }
}
