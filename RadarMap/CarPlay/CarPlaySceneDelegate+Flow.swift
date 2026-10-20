//
//  CarPlaySceneDelegate+Flow.swift
//  RadarMap
//
//  Наблюдатели фазы маршрута: ведение, объезд, итог поездки, «куда едем?», баннеры.
//

import CarPlay
import SwiftUI
import os

extension CarPlaySceneDelegate {

    func attachGuidance(background: Bool) {
        guard !guidanceAttached, let mapTemplate, let banners else { return }
        guidanceAttached = true
        guidanceAttachedInBackground = background
        // В фоне сессию начинаем, только если ведение уже шло, когда машина
        // подключилась (водитель ехал по нашему маршруту): иначе автостарт
        // поездки при старом маршруте молча забрал бы ведение у Яндекса на
        // экране машины (ревью 20.10). Показ корня это ограничение снимает.
        guidance.mayStartSession = !background || guidingAtConnect
        Log.carplay.notice("ведение подключено \(background ? "в фоне" : "на экране", privacy: .public)")
        guidance.attach(to: mapTemplate, banners: banners)
    }

    /// Машина подключилась, а на её экране не мы (главный экран, Яндекс):
    /// корень установлен — ведение подключаем, не дожидаясь, пока водитель
    /// откроет RadarMap (сценарий D1, 20.10). Иначе до этого не было ни
    /// манёвра на плитке приборки, ни камер баннером поверх чужого
    /// приложения — только голос. Алерт о разрешении и «куда едем?» — по-
    /// прежнему только на экране; сессию первый показ корня перезапустит.
    func attachGuidanceInBackground() {
        let session = session
        Task { @MainActor [weak self] in
            await Task.pause(seconds: AppConfig.carPlayRootSettleDelay)
            // Сцена успела выйти на экран — подключит показ корня, не фон.
            guard let self, self.session == session, !self.rootShown, !self.model.isOnScreen else { return }
            self.attachGuidance(background: true)
        }
    }

    /// Телефон и машина — в одной фазе: маршрут, построенный на телефоне,
    /// здесь — тот же выбор с «Поехали»; «Поехали» или крестик там закрывают
    /// выбор здесь. Ведение (сессия) следует за той же фазой в CarPlayGuidance.
    func observeFlow() {
        let session = session
        syncChoice()
        withObservationTracking {
            _ = env.route.isActive
            _ = env.route.isBuilding
            _ = env.route.destinationCoordinate
            _ = env.location.isTripActive
            _ = model.isPreviewing
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                self.observeFlow()
            }
        }
    }

    func syncChoice() {
        guard mapTemplate != nil, rootShown else { return }
        let route = env.route
        let phase = NavigationFlow.phase(hasRoute: route.isActive, isTripActive: env.location.isTripActive)
        let building = route.isBuilding
        let moving = !CarPlayTripPreview.shouldPreview(speedKmh: env.location.speedKmh)
        let decision = NavigationFlow.carChoice(from: flowPhase, to: phase,
                                                showing: model.isPreviewing, building: building,
                                                moving: moving)
        // Пока строится, фаза промежуточная — прошлой её не считаем: иначе
        // маршрут, достроенный на телефоне, не открыл бы выбор здесь.
        if !building { flowPhase = phase }
        switch decision {
        case .none:
            // Тот же выбор, но маршрут заменили на телефоне — показать новый.
            if model.isPreviewing, !building, phase == .choosing,
               let destination = route.destinationCoordinate, let shown = previewDestination,
               !CarPlayGuidance.same(shown, destination) {
                showPreview(name: route.destinationName, destination: destination)
            }
        case .show:
            guard let destination = route.destinationCoordinate else { return }
            Log.carplay.notice("выбор маршрута — с телефона или после автостопа")
            model.isPreviewing = true
            showPreview(name: route.destinationName, destination: destination)
        case .close:
            endPreview(start: false, keepRoute: true,
                       reason: phase == .free ? "маршрут снят не в машине" : "поехали не из машины")
        }
    }

    /// Одно состояние на два экрана: предложение живёт в RouteService,
    /// ответ на телефоне снимает баннер здесь, и наоборот.
    func observeDetour() {
        let session = session
        withObservationTracking {
            _ = env.route.detourOffer
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                self.syncDetourAlert()
                self.observeDetour()
            }
        }
    }

    func syncDetourAlert() {
        guard let banners else { return }
        let offer = env.route.detourOffer
        if let shownID = detourAlertID, offer?.id != shownID {
            // Ответили на телефоне или истекло — снять своё. Пришло другое —
            // новое заменит прежнее само (show): два снятия подряд CarPlay
            // мог бы сложить так, что новое не встало бы.
            let shown = detourAlert
            detourAlertID = nil
            detourAlert = nil
            if offer == nil, let shown { banners.dismiss(shown) }
        }
        guard let offer, detourAlertID == nil else { return }
        let alert = CPNavigationAlert(
            titleVariants: [offer.title],
            subtitleVariants: [offer.subtitle, String(localized: "Объезд пробки")],
            image: CarPlayGuidance.symbol("arrow.triangle.branch", pointSize: 30,
                                          onDark: model.carIsDark ?? !model.isDaylight),
            primaryAction: CPAlertAction(title: String(localized: "Объехать"), style: .default) { [weak self] _ in
                guard let self else { return }
                self.env.route.acceptDetour(cameras: self.env.cameras.cameras)
            },
            secondaryAction: CPAlertAction(title: String(localized: "Остаться"), style: .cancel) { [weak self] _ in
                self?.env.route.declineDetour()
            },
            duration: AppConfig.detourOfferSeconds)
        // Впереди камера — объезд подождёт её и вернётся сам (bannersFreed):
        // до 18.10 он снимал баннер камеры.
        guard banners.show(alert, kind: .detour) else { return }
        detourAlertID = offer.id
        detourAlert = alert
        env.route.noteDetourShown(id: offer.id)
        Log.carplay.notice("объезд: баннер в машине")
    }

    // MARK: - Баннеры: что снято и что вернуть

    /// Экран баннеров освободился — показать ждущих: объезд и вопрос.
    func bannersFreed() {
        syncDetourAlert()
        presentPendingConfirmIfNeeded()
    }

    /// Баннер снят приложением или так и не встал (CarPlayBanners.onDropped):
    /// объезд и вопрос забывают, что были показаны, и вернутся, когда экран
    /// освободится.
    func forgetBanner(_ alert: CPNavigationAlert) {
        if alert === detourAlert {
            // Вытеснен камерой — время на ответ начнётся снова, когда вернётся.
            if let id = detourAlertID { env.route.noteDetourHidden(id: id) }
            detourAlertID = nil
            detourAlert = nil
        }
        if alert === confirmBanner {
            confirmBanner = nil
            confirmBannerID = nil
        }
    }

    /// Поездка сохранилась — итог одной строкой, пока машина стоит и экран
    /// наш (CarPlayTripSummary). Подробности — на телефоне.
    func observeTripSaved() {
        let session = session
        withObservationTracking {
            _ = env.trip.lastSavedAt
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                self.showTripSummaryIfFresh()
                self.observeTripSaved()
            }
        }
    }

    func showTripSummaryIfFresh() {
        guard let saved = env.trip.lastSavedAt, saved != summarizedSave,
              Date().timeIntervalSince(saved) < AppConfig.tripEndCardFreshSeconds,
              Self.activeDelegate === self, model.isOnScreen, shownTemplate == nil,
              env.location.speedKmh < AppConfig.carPlayPreviewMaxKmh,
              let record = env.trip.history.first else { return }
        summarizedSave = saved
        Log.carplay.notice("итог поездки в машине")
        showToast(CarPlayTripSummary.lines(for: record)[0], variants: CarPlayTripSummary.lines(for: record))
    }

    /// Одноразовые показы ждут экрана (10.9): итог поездки и «Куда едем?»
    /// проверяли «экран наш и шаблон свободен» один раз и, не застав этого
    /// (на экране машины другое приложение, сверху «Куда»), пропадали до
    /// следующего раза. Теперь их пробуют снова, когда карта снова на экране
    /// — у каждого свои условия свежести.
    func retryOneTimeShows() {
        guard Self.activeDelegate === self, model.isOnScreen, shownTemplate == nil else { return }
        showTripSummaryIfFresh()
        // «Сели и поехали» — первые минуты подключения (`connectedAt`).
        if rootShown, !offeredDestination, let connectedAt,
           Date().timeIntervalSince(connectedAt) < AppConfig.carPlayDestinationOfferWindow {
            offerDestinationIfUseful()
        }
    }

    /// Сев в машину, водитель чаще всего едет туда же, куда всегда: утром из
    /// дома — на работу, вечером — домой (DestinationGuess — та же догадка,
    /// что строка на телефоне). Одно касание вместо «Куда → Работа».
    /// Пауза — на первый точный фикс: догадка смотрит, где мы стоим.
    func offerDestinationSoon() {
        guard !offeredDestination else { return }
        // «Сейчас ~44 мин» в баннере — свежий, а не тот, что строка на
        // телефоне посчитала утром (телефон в кармане, строки нет).
        env.refreshDepartureEstimates()
        offerTask?.cancel()
        offerTask = Task { @MainActor [weak self] in
            await Task.pause(seconds: AppConfig.carPlayDestinationOfferDelay)
            guard let self, !Task.isCancelled else { return }
            self.offerDestinationIfUseful()
        }
    }

    func offerDestinationIfUseful() {
        guard !offeredDestination, Self.activeDelegate === self, model.isOnScreen,
              shownTemplate == nil, !model.isPreviewing, !env.route.isActive,
              env.location.speedKmh < AppConfig.carPlayPreviewMaxKmh,
              let guess = env.destinationGuess(now: Date()) else { return }
        offeredDestination = true
        let title = guess.kind.suggestionTitle
        let place = SavedPlace(title: guess.placeTitle ?? guess.kind.title,
                               lat: guess.coordinate.latitude, lon: guess.coordinate.longitude)
        let alert = CPNavigationAlert(
            // Время — один раз, в подзаголовке (как на телефоне): до 20.10
            // «сейчас ~52 мин, пробки +8» стояло и в заголовке, и под ним.
            titleVariants: [title],
            subtitleVariants: [guess.subtitle],
            image: CarPlayGuidance.symbol(guess.kind.symbol, pointSize: 30,
                                          onDark: model.carIsDark ?? !model.isDaylight),
            primaryAction: CPAlertAction(title: String(localized: "Поехали"), style: .default) { [weak self] _ in
                Log.carplay.notice("«куда едем?»: принято — \(guess.kind.rawValue, privacy: .public)")
                // Цель подтверждена этим касанием — второй экран выбора не нужен:
                // ведём рекомендованным с учётом пробок.
                self?.route(to: place, allowPreview: false)
            },
            secondaryAction: CPAlertAction(title: String(localized: "Не сейчас"), style: .cancel) { _ in
                Log.carplay.notice("«куда едем?»: отказ")
            },
            duration: AppConfig.carPlayDestinationOfferSeconds)
        guard banners?.show(alert, kind: .suggestion) == true else { return }
        Log.carplay.notice("«куда едем?»: предлагаю \(guess.kind.rawValue, privacy: .public)")
    }

    /// Навигацию забрала система (другое приложение, встроенный навигатор
    /// машины). Ведущий может быть один: уступаем совсем — маршрут снимаем,
    /// поездка и камеры остаются (RadarMap рядом с Яндексом). До 20.10
    /// маршрут жил: телефон говорил свои повороты поверх чужих, перестраивал
    /// путь под чужую линию, а открытие RadarMap ради «Радар!» забирало
    /// ведение у Яндекса (сценарий D1). Вернуть ведение — новый маршрут
    /// (цель — в «Недавних»).
    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        // Только владелец экрана машины и только наша живая сессия: событие
        // старой сцены после «моргания» кабеля или отмена сессии, которой у
        // нас нет, не вправе снимать общий маршрут (ревью 20.10).
        let hadSession = model.hasSystemGuidance
        guidance.systemCancelled()
        guard Self.activeDelegate === self, hadSession else {
            Log.carplay.notice("CarPlay: отмена навигации без нашей сессии — маршрут не трогаю")
            return
        }
        Log.carplay.notice("CarPlay: навигацию отменила система — уступаем, маршрут снят")
        if env.route.isActive { env.route.clear() }
    }

    /// Метаданные манёвра для приборки и проекции на стекло — ВЫКЛЮЧЕНЫ.
    ///
    /// Включили их в 2.2.4, и с тех пор карточка манёвра на экране машины
    /// показывала одно расстояние — без стрелки и текста (CarPlay Simulator,
    /// 11.10, 2.2.5–2.2.7). Руководство CarPlay (июнь 2026) требует для
    /// метаданных тип манёвра, ТИП ПЕРЕКРЁСТКА и сторону движения плюс
    /// состояние манёвра по ходу подъезда — типа перекрёстка и состояния у нас
    /// нет. Навигатор Mapbox метаданные не включает и карточку собирает только
    /// из стрелки, текста и начальной оценки. Вернём, когда будут все поля
    /// и проверка в машине с приборкой.
    /// С 2.2.16 поля есть все (тип перекрёстка, угол съезда, состояние
    /// манёвра — CarPlayGuidanceMapping), но включение — флагом
    /// `carPlayNavigationMetadata`: проверить сначала в CarPlay Simulator на
    /// втором дисплее «приборка» (профиль Widescreen, showsInstruments).
    func mapTemplateShouldProvideNavigationMetadata(_ mapTemplate: CPMapTemplate) -> Bool {
        AppConfig.carPlayNavigationMetadata
    }

    /// Плитка главного экрана вышла на экран: сессии — свежий манёвр и оценки.
    static func refreshGuidance(reason: String) {
        activeDelegate?.guidance.refresh(reason: reason)
    }
}
