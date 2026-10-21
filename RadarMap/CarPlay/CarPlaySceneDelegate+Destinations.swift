//
//  CarPlaySceneDelegate+Destinations.swift
//  RadarMap
//
//  «Куда»: сетка, поиск, ближайшие, назначение мест, выбор маршрута, заезд, отметка радара.
//

import CarPlay
import SwiftUI
import os

extension CarPlaySceneDelegate {

    /// Конфигурация значка с трейтами ЭКРАНА МАШИНЫ. Без них картинка несёт
    /// масштаб телефона: на головном устройстве с другим display scale растр
    /// пережимается уже там и приезжает не того размера и мыльным. Apple для
    /// изображений CarPlay прямо велит carTraitCollection.
    func carConfiguration(pointSize: CGFloat,
                                  weight: UIImage.SymbolWeight) -> UIImage.SymbolConfiguration {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let traits = interfaceController?.carTraitCollection else { return config }
        return config.applying(UIImage.SymbolConfiguration(traitCollection: traits))
    }

    // MARK: - Ограничения на ходу

    /// Машина тронулась или остановилась: клавиатура пропала или вернулась.
    func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration,
                              limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface) {
        let limited = limitedUserInterfaces.contains(.keyboard)
        guard limited != keyboardLimited else { return }
        keyboardLimited = limited
        Log.carplay.notice("клавиатура в машине: \(limited ? "недоступна" : "доступна", privacy: .public)")
        destinationsGrid?.updateGridButtons(destinationButtons())
    }

    // MARK: - «Куда»: горячие плитки

    /// Дом, Работа и недавние — маршрут в один тап. Сетка ограничена восемью
    /// плитками, поэтому недавние добираем тем, что осталось.
    func presentDestinations() {
        guard beginPush("куда") else { return }
        // Заголовок совпадает с кнопкой, которой сюда пришли: тап «Маршрут»,
        // открывший экран «Куда», читался как промах.
        let grid = CPGridTemplate(title: env.route.isActive ? String(localized: "Маршрут")
                                                            : String(localized: "Куда"),
                                  gridButtons: destinationButtons())
        destinationsGrid = grid
        interfaceController?.pushTemplate(grid, animated: true) { [weak self] _, error in
            Task { @MainActor [weak self] in self?.endPush() }
            if let error {
                Log.carplay.error("pushTemplate(куда): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func destinationButtons() -> [CPGridButton] {
        var buttons: [CPGridButton] = []

        // Активный маршрут: первым делом даём его сбросить — это самая частая
        // причина зайти сюда во время движения.
        if env.route.isActive {
            buttons.append(gridButton(symbol: "xmark.circle.fill",
                                      titles: [String(localized: "Отменить маршрут"),
                                               String(localized: "Стоп")]) { [weak self] in
                guard let self else { return }
                env.route.clear()
                popToMap()
            })
            // Весь маршрут и камеры на нём (10.4): во время ведения число
            // камер впереди не было видно нигде.
            buttons.append(gridButton(symbol: "map",
                                      titles: [String(localized: "Весь маршрут"),
                                               String(localized: "Обзор")]) { [weak self] in
                self?.popToMap { [weak self] in self?.model.showOverview() }
            })
            let ahead = RouteCamerasAhead.list(env.route.camerasOnRoute, progress: env.route.progressAlong)
            buttons.append(gridButton(symbol: "camera.fill",
                                      titles: ahead.isEmpty
                                        ? [String(localized: "Камер впереди нет")]
                                        : [String(format: String(localized: "Камер впереди: %lld"), ahead.count),
                                           String(format: String(localized: "Камеры: %lld"), ahead.count)]) { [weak self] in
                self?.presentRouteCameras()
            })
        }

        for slot in PlaceSlot.allCases {
            buttons.append(placeButton(slot: slot))
        }

        // Поиск — третьей плиткой, сразу за Домом и Работой: адрес, которого
        // нет в недавних, раньше можно было задать только на телефоне. На
        // ходу клавиатура в машине недоступна, и экран поиска был бы пустым
        // обещанием (аудит 18.10, п. 3): плитка стоит на своём месте, но
        // выключена и говорит, когда заработает.
        let search = gridButton(symbol: "magnifyingglass",
                                titles: keyboardLimited
                                    ? [String(localized: "Поиск на стоянке"), String(localized: "Поиск")]
                                    : [String(localized: "Поиск")]) { [weak self] in
            self?.presentSearch()
        }
        search.isEnabled = !keyboardLimited
        buttons.append(search)
        // АЗС или зарядка — частый вопрос в дороге, и ответ на него — одна
        // плитка. Какая — по машине (Настройки → Поездка → «Машина»): у
        // электромобиля «Зарядка» вместо «АЗС», у гибрида обе.
        for kind in env.settings.vehicleEnergy.stops {
            buttons.append(gridButton(symbol: kind.symbol, titles: [kind.title]) { [weak self] in
                self?.presentNearest(kind)
            })
        }

        // Дом и Работа уже стоят своими плитками выше — в «недавних» они
        // дублируются и съедают места из восьми, которые есть у сетки.
        // Сравниваем по координате, а не по названию: одно и то же место
        // может называться по-разному.
        let pinned = PlaceSlot.allCases.compactMap { slotPlace($0)?.saved.coordinate }
        let recent = env.settings.recentPlaces.filter { place in
            !pinned.contains { GeoMath.fastDistance($0.latitude, $0.longitude,
                                                    place.coordinate.latitude,
                                                    place.coordinate.longitude)
                < AppConfig.carPlayRecentDuplicateMeters }
        }
        for place in recent.prefix(max(0, AppConfig.carPlayGridLimit - buttons.count)) {
            buttons.append(gridButton(symbol: "clock.arrow.circlepath",
                                      titles: [place.title, Self.shortTitle(place.title)]) { [weak self] in
                self?.route(to: place)
            })
        }

        // Сетка держит не больше восьми: с маршрутом и двумя заправками
        // постоянных плиток ровно столько — лишняя не должна ронять шаблон.
        return Array(buttons.prefix(AppConfig.carPlayGridLimit))
    }

    /// Камеры впереди по маршруту — список с остатком пути до каждой.
    /// Справочный: строки не нажимаются, ведение не прерывается.
    func presentRouteCameras() {
        let ahead = RouteCamerasAhead.list(env.route.camerasOnRoute, progress: env.route.progressAlong,
                                           limit: Int(CPListTemplate.maximumItemCount))
        guard !ahead.isEmpty else {
            showToast(String(localized: "Камер впереди по маршруту нет"))
            return
        }
        let items = ahead.map { item in
            CPListItem(text: "\(Formatting.distance(item.meters)) · \(item.camera.kind.displayName)",
                       detailText: item.camera.displayTitle)
        }
        guard beginPush("камеры маршрута") else { return }
        let list = CPListTemplate(title: String(localized: "Камеры на маршруте"),
                                  sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(list, animated: true) { [weak self] _, error in
            Task { @MainActor [weak self] in self?.endPush() }
            if let error {
                Log.carplay.error("pushTemplate(камеры маршрута): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func presentNearest(_ kind: Venue.Kind) {
        let key = "nearest:\(kind.rawValue)"
        guard actionsInFlight.insert(key).inserted else {
            return Log.carplay.notice("повторное касание — список уже ищется")
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.actionsInFlight.remove(key) }
            let found = await search.nearest(kind)
            guard !found.isEmpty else {
                return showAlert(title: String(format: String(localized: "%@ рядом не нашлось"), kind.title),
                                 message: String(localized: "Без сети ищу только по своей карте."))
            }
            let items = found.map { place, detail, alongRoute -> CPListItem in
                let item = CPListItem(text: place.title, detailText: detail)
                item.handler = { [weak self] _, completion in
                    // Найдено впереди по маршруту — заезд, цель остаётся.
                    if alongRoute { self?.addStop(place) } else { self?.route(to: place) }
                    completion()
                }
                return item
            }
            let list = CPListTemplate(title: kind.title, sections: [CPListSection(items: items)])
            interfaceController?.pushTemplate(list, animated: true) { _, error in
                if let error {
                    Log.carplay.error("pushTemplate(\(kind.title, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Полный список найденного по «Найти» на клавиатуре — поверх поиска.
    func pushSearchResults(_ template: CPTemplate) {
        interfaceController?.pushTemplate(template, animated: true) { _, error in
            if let error {
                Log.carplay.error("pushTemplate(результаты поиска): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func presentAssign(_ slot: PlaceSlot) {
        guard !keyboardLimited else {
            return showAlert(title: String(format: String(localized: "«%@» — на стоянке"), slot.name),
                             message: String(localized: "Поиск адреса на ходу недоступен — задайте место, когда машина остановится."))
        }
        let search = CarPlaySearch { [weak self] place in
            guard let self else { return }
            env.settings.setPlace(place, for: slot)
            assignSearch = nil
            route(to: place)
        }
        search.present = { [weak self] template in self?.pushSearchResults(template) }
        guard beginPush("поиск для слота") else { return }
        assignSearch = search
        interfaceController?.pushTemplate(search.makeTemplate(), animated: true) { [weak self] _, error in
            Task { @MainActor [weak self] in self?.endPush() }
            if let error {
                Log.carplay.error("pushTemplate(поиск для слота): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Вход с приборной панели: касание её кнопки запускает основную сцену
    /// CarPlay, но обработчик кнопки приходит раньше, чем сцена подключилась.
    /// Ждём её коротко и открываем поиск для слота.
    static func presentAssignWhenReady(_ slot: PlaceSlot) {
        Task { @MainActor in
            for _ in 0..<AppConfig.carPlaySceneWaitAttempts {
                if let delegate = activeDelegate, delegate.interfaceController != nil {
                    delegate.presentAssign(slot)
                    return
                }
                await Task.pause(seconds: AppConfig.carPlaySceneWaitStep)
            }
            Log.carplay.notice("слот \(slot.rawValue, privacy: .public): основная сцена не подключилась вовремя")
        }
    }

    func presentSearch() {
        guard beginPush("поиск") else { return }
        interfaceController?.pushTemplate(search.makeTemplate(), animated: true) { [weak self] _, error in
            Task { @MainActor [weak self] in self?.endPush() }
            if let error {
                Log.carplay.error("pushTemplate(поиск): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func beginPush(_ label: String) -> Bool {
        guard interfaceController != nil else { return false }
        if let started = pushStartedAt,
           Date().timeIntervalSince(started) < AppConfig.carPlayPushGuardSeconds {
            Log.carplay.notice("второй тап, пока экран едет (\(label, privacy: .public)) — пропускаю")
            return false
        }
        pushStartedAt = Date()
        return true
    }

    func endPush() { pushStartedAt = nil }

    /// Плитка Дом/Работа. Место не задано — плитку всё равно показываем: она
    /// всегда на одном месте (мышечная память), а тап задаёт место поиском.
    ///
    /// Три состояния, как у плитки главного экрана машины (10.3): адрес
    /// задан — маршрут к нему; не задан, но выучен по поездкам
    /// (FrequentPlaces) — маршрут к выученному («по вашим поездкам»);
    /// ничего — поиск. До 20.10 выученный дом знала только плитка главного
    /// экрана, а «Куда» предлагал задать его заново. Ручной адрес всегда
    /// старше догадки.
    func placeButton(slot: PlaceSlot) -> CPGridButton {
        let place = slotPlace(slot)
        // «обычно 39 мин» — медиана своих поездок туда (Commute), без сети.
        let usual = env.commute
            .first { $0.direction == (slot == .work ? .toWork : .toHome) }?.usual
            .map { String(format: String(localized: "обычно %@"), Formatting.duration($0)) }
        let titles: [String]
        switch place {
        case .manual(let saved)?:
            titles = [usual.map { "\(slot.name) · \($0)" }, "\(slot.name) · \(saved.title)", slot.name]
                .compactMap { $0 }
        case .learned?:
            titles = [usual.map { "\(slot.name) · \($0)" },
                      "\(slot.name) · \(String(localized: "по вашим поездкам"))", slot.name].compactMap { $0 }
        case nil:
            titles = [slot.name]
        }
        return gridButton(symbol: slot.symbol, titles: titles) { [weak self] in
            guard let self else { return }
            // Не задано — задаём здесь же поиском, как с плитки главного
            // экрана: сценарий в машине обязан проходить без телефона
            // (Руководство CarPlay, стр. 5; аудит 18.10, п. 8).
            guard let place else { return presentAssign(slot) }
            // Выученное место в «недавние» не пишем: оно двигается с привычками
            // и забывается выключателем — а запись осталась бы вторым «Домом».
            if case .learned = place {
                route(to: place.saved, remember: false)
            } else {
                route(to: place.saved)
            }
        }
    }

    /// Куда ведёт слот: заданный руками адрес или выученное по поездкам место.
    enum SlotPlace {
        case manual(SavedPlace)
        case learned(SavedPlace)

        var saved: SavedPlace {
            switch self {
            case .manual(let place), .learned(let place): return place
            }
        }
    }

    func slotPlace(_ slot: PlaceSlot) -> SlotPlace? {
        if let place = env.settings.place(for: slot) { return .manual(place) }
        guard let learned = env.learnedPlaces.first(where: { $0.kind.rawValue == slot.rawValue }) else {
            return nil
        }
        return .learned(SavedPlace(title: slot.name, lat: learned.lat, lon: learned.lon))
    }

    func gridButton(symbol: String, titles: [String],
                            action: @escaping () -> Void) -> CPGridButton {
        CPGridButton(titleVariants: titles, image: gridImage(symbol)) { _ in action() }
    }

    /// Длинный адрес в плитку не влезает — короткий вариант для узких экранов.
    static func shortTitle(_ title: String) -> String {
        let head = title.split(separator: ",").first.map(String.init) ?? title
        let limit = AppConfig.carPlayTileTitleLimit
        return head.count > limit ? String(head.prefix(limit - 1)) + "…" : head
    }

    /// Строим маршрут и сразу едем: за рулём выбирать из альтернатив некогда.
    func route(to place: SavedPlace, allowPreview: Bool = true, remember: Bool = true) {
        let key = "route:\(place.lat),\(place.lon)"
        guard actionsInFlight.insert(key).inserted else {
            return Log.carplay.notice("повторное касание — маршрут уже строится")
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.actionsInFlight.remove(key) }
            // Грубая точка фонового режима сюда не годится: маршрут от неё
            // начинается за километры (plan_drive_complaints.md, Ж5).
            guard let from = await env.location.awaitPreciseCoordinate() else {
                showAlert(title: String(localized: "Ждём спутники"),
                          message: String(localized: "Положение ещё не определено — попробуйте через несколько секунд."))
                return
            }
            popToMap()
            // Выбор маршрута — только стоя (CarPlayTripPreview): на ходу
            // ведём рекомендованным, как раньше. Флаг — ДО построения: иначе
            // сессия навигации стартовала бы на первом варианте раньше выбора.
            let preview = allowPreview && CarPlayTripPreview.shouldPreview(speedKmh: env.location.speedKmh)
            if previewTrip != nil { mapTemplate?.hideTripPreviews() }
            previewTrip = nil
            model.isPreviewing = preview
            // На ходу — по курсу (20.9); стоя (выбор варианта) курса нет.
            await env.route.build(from: from, heading: env.location.routeHeading,
                                  to: place.coordinate,
                                  name: place.title, cameras: env.cameras.cameras,
                                  alternatives: preview)
            if remember { env.settings.addRecent(title: place.title, lat: place.lat, lon: place.lon) }
            if preview, env.route.isActive, env.route.errorMessage == nil {
                showPreview(name: place.title, destination: place.coordinate)
                return
            }
            if preview { endPreview(start: false, keepRoute: true, reason: "маршрут не построен") }
            // Едем уже с активной поездкой — не обнулять её накат.
            if !env.location.isTripActive { env.location.startTrip() }
            if let error = env.route.errorMessage {
                showAlert(title: String(localized: "Маршрут не построен"), message: error)
            }
        }
    }

    /// Варианты с нашими метками и временем с пробками; рекомендованный —
    /// первым и выбранным. Линия — целиком на экране.
    func showPreview(name: String, destination: CLLocationCoordinate2D) {
        guard let mapTemplate else {
            return endPreview(start: true, keepRoute: true, reason: "шаблона нет")
        }
        let route = env.route
        let variants = route.variants
        let ordered = variants.filter { $0.id == route.selectedID } + variants.filter { $0.id != route.selectedID }
        let choices = ordered.map { variant -> CPRouteChoice in
            let text = CarPlayTripPreview.text(for: variant, among: variants)
            let choice = CPRouteChoice(summaryVariants: text.summary,
                                       additionalInformationVariants: text.additional,
                                       selectionSummaryVariants: text.selection)
            choice.userInfo = variant.id
            return choice
        }
        let origin = MKMapItem(placemark: MKPlacemark(coordinate: env.location.currentCoordinate ?? destination))
        let target = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        target.name = name
        let trip = CarPlayGuidance.makeTrip(origin: origin, destination: target, choices: choices)
        if previewTrip != nil { mapTemplate.hideTripPreviews() }
        previewTrip = trip
        previewDestination = destination
        let text = CPTripPreviewTextConfiguration(startButtonTitle: String(localized: "Поехали"),
                                                  additionalRoutesButtonTitle: String(localized: "Варианты"),
                                                  overviewButtonTitle: String(localized: "Обзор"))
        mapTemplate.showTripPreviews([trip], selectedTrip: trip, textConfiguration: text)
        updatePreviewEstimates(route.selected)
        model.showOverview()
        Log.carplay.notice("выбор маршрута: вариантов \(variants.count, privacy: .public)")
        watchMovingOff()
    }

    func updatePreviewEstimates(_ variant: RouteService.Variant?) {
        guard let trip = previewTrip, let variant, let mapTemplate else { return }
        let estimates = CarPlayGuidance.tripEstimates(meters: variant.distance, seconds: variant.expectedTime)
        let color: CPTimeRemainingColor = switch CarPlayTripPreview.timeColor(trafficDelay: variant.shownTrafficDelay) {
        case .standard: .default
        case .green: .green
        case .orange: .orange
        case .red: .red
        }
        mapTemplate.update(estimates, for: trip, with: color)
    }

    /// Закрыть выбор. `keepRoute` — ехать выбранным; нет — маршрут снят
    /// («Отмена»). Сессия навигации начнётся сама, как только выбор закрыт.
    func endPreview(start: Bool, keepRoute: Bool, reason: String) {
        previewWatch?.cancel()
        previewWatch = nil
        if previewTrip != nil { mapTemplate?.hideTripPreviews() }
        previewTrip = nil
        previewDestination = nil
        guard model.isPreviewing else { return }
        if !keepRoute { env.route.clear() }
        model.isPreviewing = false
        model.recenter()
        if start, !env.location.isTripActive { env.location.startTrip() }
        Log.carplay.notice("выбор маршрута закрыт: \(reason, privacy: .public)")
    }

    func watchMovingOff() {
        previewWatch?.cancel()
        previewWatch = Task { @MainActor [weak self] in
            var watch = CarPlayTripPreview.MovingWatch()
            while !Task.isCancelled {
                guard let self, self.model.isPreviewing else { return }
                if watch.update(speedKmh: self.env.location.speedKmh, at: Date()) {
                    self.endPreview(start: true, keepRoute: true, reason: "тронулись — едем выбранным")
                    return
                }
                await Task.pause(seconds: 1)
            }
        }
    }

    /// Место из поиска (10.5). Без маршрута — цель. С маршрутом — спросить:
    /// «Заехать по пути» или «Новая цель». До 20.10 заезд был только у плитки
    /// «АЗС», а найденная поиском аптека молча заменяла цель — и маршрут
    /// домой пропадал, хотя хотели заскочить по дороге.
    func pickFromSearch(_ place: SavedPlace) {
        guard env.route.isActive, !model.isPreviewing else { return route(to: place) }
        let sheet = CPActionSheetTemplate(
            title: Self.shortTitle(place.title),
            message: nil,
            actions: [
                CPAlertAction(title: String(localized: "Заехать по пути"), style: .default) { [weak self] _ in
                    self?.dismissTopTemplate { [weak self] in self?.addStop(place) }
                },
                CPAlertAction(title: String(localized: "Новая цель"), style: .default) { [weak self] _ in
                    self?.dismissTopTemplate { [weak self] in self?.route(to: place) }
                },
                CPAlertAction(title: String(localized: "Отмена"), style: .cancel) { [weak self] _ in
                    self?.dismissTopTemplate()
                },
            ])
        interfaceController?.presentTemplate(sheet, animated: true) { _, error in
            if let error {
                Log.carplay.error("presentTemplate(заезд или цель): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Заезд по пути: маршрут к той же цели через `place`. Не вышло — прежний
    /// маршрут остаётся, и машина говорит почему.
    func addStop(_ place: SavedPlace) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let from = await env.location.awaitPreciseCoordinate() else {
                showAlert(title: String(localized: "Ждём спутники"),
                          message: String(localized: "Положение ещё не определено — попробуйте через несколько секунд."))
                return
            }
            popToMap()
            await env.route.addStop(place.coordinate, name: place.title,
                                    from: from, heading: env.location.routeHeading,
                                    cameras: env.cameras.cameras)
            if let error = env.route.errorMessage {
                showAlert(title: String(localized: "Не удалось заехать по пути"), message: error)
            }
        }
    }

    // MARK: - Отметка засады из машины

    /// «Радар!» одним касанием (10.2). Раньше касание открывало сетку
    /// «Что впереди?» — второй тап и взгляд на экран ровно там, где руки
    /// должны быть на руле. Теперь радар ставится сразу (он покрывает почти
    /// все случаи), а уточнить тип можно баннером: «Тренога» одним касанием,
    /// «Другое» — сетка. Молчание честно оставляет «радар», как на телефоне
    /// (`ReportRefineBar`). Та же дверь, что у плашки и часов
    /// (`remoteRadarReport`): защита от дублей и двойного нажатия, итог голосом.
    func quickRadar() {
        Task { @MainActor [weak self] in
            guard let self, let outcome = await env.remoteRadarReport() else { return }
            // Уточнять можно только свою свежесозданную точку — её и даёт
            // refineOffer (чужая merged-точка уточнением родила бы вторую).
            if case .sent(.created) = outcome, let offer = env.mobile.refineOffer {
                showRefineBanner(offer: offer)
            } else {
                showToast(outcome.spoken)
            }
        }
    }

    /// Баннер уточнения — ответ на касание водителя (`.request`): камера
    /// впереди его вытеснит, и тогда остаётся «радар», а голос итог уже сказал.
    func showRefineBanner(offer: ReportGuard.Sent) {
        let banner = CPNavigationAlert(
            titleVariants: [String(localized: "Радар отмечен — что это было?"),
                            String(localized: "Радар отмечен")],
            subtitleVariants: nil,
            image: nil,
            primaryAction: CPAlertAction(title: ReportKind.tripod.title, style: .default) { [weak self] _ in
                self?.refineReport(to: .tripod, offer: offer)
            },
            secondaryAction: CPAlertAction(title: String(localized: "Другое"), style: .default) { [weak self] _ in
                self?.presentRefineGrid(offer: offer)
            },
            duration: AppConfig.reportRefineSeconds)
        if banners?.show(banner, kind: .request) != true {
            Log.carplay.notice("уточнение отметки не показано: экран занят")
        }
    }

    /// «Другое»: пост, ДТП и «Отменить» — крупные плитки, один тап и обратно
    /// на карту. Набор типов — общий с телефоном (`ReportKind.offered`).
    func presentRefineGrid(offer: ReportGuard.Sent) {
        // Перекрытие и ремонт (12б.5) — когда сервер их знает.
        let road = env.mobile.roadEventsSupported ? ReportKind.roadOffered : []
        var buttons = (ReportKind.offered + road).filter { $0 != .radar && $0 != .tripod }.map { kind in
            // Действие — после возврата к карте: тост поверх летящего pop
            // CarPlay отклоняет, и быстрый отказ водитель не увидел бы.
            gridButton(symbol: kind.symbol, titles: [kind.title]) { [weak self] in
                self?.popToMap { [weak self] in self?.refineReport(to: kind, offer: offer) }
            }
        }
        if env.mobile.cancellableReportID() != nil {
            buttons.append(gridButton(symbol: "arrow.uturn.backward", titles: [String(localized: "Отменить")]) { [weak self] in
                self?.popToMap { [weak self] in self?.cancelOwnReport() }
            })
        }
        guard beginPush("уточнение") else { return }
        let grid = CPGridTemplate(title: String(localized: "Что это было?"), gridButtons: buttons)
        interfaceController?.pushTemplate(grid, animated: true) { [weak self] _, error in
            Task { @MainActor [weak self] in self?.endPush() }
            if let error {
                Log.carplay.error("pushTemplate(уточнение): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Второй тап: сервер переписывает тип ТОЙ ЖЕ точки (amend). Слова — те
    /// же, что у плашки уточнения на телефоне.
    func refineReport(to kind: ReportKind, offer: ReportGuard.Sent) {
        env.mobile.dismissRefine()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let text = await env.mobile.refine(to: kind, offer: offer)
                ? kind.title : String(localized: "Не отправилось, нет связи")
            env.alerts.speak(text)
            showToast(text)
        }
    }

    /// «Не то» — отзыв своей свежей, никем не подтверждённой отметки.
    func cancelOwnReport() {
        env.mobile.dismissRefine()
        guard let id = env.mobile.cancellableReportID() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let text = await env.mobile.cancelReport(id: id)
                ? String(localized: "Отметка убрана") : String(localized: "Не отправилось, нет связи")
            env.alerts.speak(text)
            showToast(text)
        }
    }
}
