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
        movingList?.updateSections([movingSection()])
    }

    /// Ограничение — сейчас, а не с момента подключения: сразу после
    /// создания конфигурации значение бывает ещё пустым (форум Apple 741142).
    func currentKeyboardLimited() -> Bool {
        keyboardLimited = sessionConfiguration?.limitedUserInterfaces.contains(.keyboard) ?? keyboardLimited
        return keyboardLimited
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
        interfaceController?.pushTemplate(grid, animated: true) { [weak self] _, error in
            Task { @MainActor [weak self] in self?.endPush() }
            if let error {
                Log.carplay.error("pushTemplate(куда): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func destinationButtons() -> [CPGridButton] {
        let slots = PlaceSlot.allCases
        let stops = env.settings.vehicleEnergy.stops
        let recent = recentsBesidesPinned()
        let tiles = CarPlaySearchEntry.grid(routeActive: env.route.isActive, slots: slots.count,
                                            stops: stops.count, recents: recent.count,
                                            limit: AppConfig.carPlayGridLimit)
        return tiles.map { tile in
            switch tile {
            case .search: searchTile()
            case .cancelRoute: cancelRouteTile()
            case .overview: overviewTile()
            case .cameras: camerasTile()
            case .slot(let index): placeButton(slot: slots[index])
            case .stop(let index): nearestTile(stops[index])
            case .recent(let index): recentTile(recent[index])
            }
        }
    }

    /// Всегда нажимается: на ходу ответит причиной и альтернативой. Серая
    /// плитка на светофоре читалась как «поиска нет» (владелец, 09.11).
    private func searchTile() -> CPGridButton {
        gridButton(symbol: "magnifyingglass", titles: [String(localized: "Поиск")]) { [weak self] in
            self?.openSearch()
        }
    }

    func openSearch() {
        switch CarPlaySearchEntry.searchTap(keyboardLimited: currentKeyboardLimited()) {
        case .keyboard: presentSearch()
        case .alternatives: presentMovingAlternatives()
        }
    }

    private func cancelRouteTile() -> CPGridButton {
        gridButton(symbol: "xmark.circle.fill",
                   titles: [String(localized: "Отменить маршрут"), String(localized: "Стоп")]) { [weak self] in
            guard let self else { return }
            env.route.clear()
            popToMap()
        }
    }

    /// Весь маршрут и камеры на нём (10.4): во время ведения число камер
    /// впереди не было видно нигде.
    private func overviewTile() -> CPGridButton {
        gridButton(symbol: "map",
                   titles: [String(localized: "Весь маршрут"), String(localized: "Обзор")]) { [weak self] in
            self?.popToMap { [weak self] in self?.model.showOverview() }
        }
    }

    private func camerasTile() -> CPGridButton {
        let ahead = RouteCamerasAhead.list(env.route.camerasOnRoute, progress: env.route.progressAlong)
        return gridButton(symbol: "camera.fill",
                          titles: ahead.isEmpty
                            ? [String(localized: "Камер впереди нет")]
                            : [String(format: String(localized: "Камер впереди: %lld"), ahead.count),
                               String(format: String(localized: "Камеры: %lld"), ahead.count)]) { [weak self] in
            self?.presentRouteCameras()
        }
    }

    /// АЗС или зарядка — по машине (Настройки → Поездка → «Машина»).
    private func nearestTile(_ kind: Venue.Kind) -> CPGridButton {
        gridButton(symbol: kind.symbol, titles: [kind.title]) { [weak self] in
            self?.presentNearest(kind)
        }
    }

    private func recentTile(_ place: SavedPlace) -> CPGridButton {
        gridButton(symbol: "clock.arrow.circlepath",
                   titles: [place.title, Self.shortTitle(place.title)]) { [weak self] in
            self?.route(to: place)
        }
    }

    /// Недавние без Дома и Работы: те стоят своими плитками. Сравниваем по
    /// координате: одно место может называться по-разному.
    private func recentsBesidesPinned() -> [SavedPlace] {
        let pinned = PlaceSlot.allCases.compactMap { slotPlace($0)?.saved.coordinate }
        return env.settings.recentPlaces.filter { place in
            !pinned.contains { GeoMath.fastDistance($0.latitude, $0.longitude,
                                                    place.coordinate.latitude,
                                                    place.coordinate.longitude)
                < AppConfig.carPlayRecentDuplicateMeters }
        }
    }

    // MARK: - Поиск на ходу

    /// Клавиатуры нет — причина и то, что можно сделать без неё.
    private func presentMovingAlternatives() {
        guard beginPush("поиск на ходу") else { return }
        let list = CPListTemplate(title: String(localized: "Поиск на ходу"), sections: [movingSection()])
        movingList = list
        interfaceController?.pushTemplate(list, animated: true) { [weak self] _, error in
            Task { @MainActor [weak self] in self?.endPush() }
            if let error {
                Log.carplay.error("pushTemplate(поиск на ходу): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func movingSection() -> CPListSection {
        let slots = PlaceSlot.allCases.compactMap { slot in slotPlace(slot).map { (slot, $0) } }
        let recent = recentsBesidesPinned()
        var categories = env.settings.vehicleEnergy.stops
        for kind in [Venue.Kind.pharmacy, .atm, .parking, .food] where !categories.contains(kind) {
            categories.append(kind)
        }
        let limit = CarPlaySearchEntry.listLimit(own: AppConfig.carPlayMovingListLimit,
                                                 maximumItemCount: Int(CPListTemplate.maximumItemCount))
        let rows = CarPlaySearchEntry.movingRows(keyboardLimited: keyboardLimited, slots: slots.count,
                                                 recents: recent.count, categories: categories.count, limit: limit)
        let items: [CPListItem] = rows.map { row in
            switch row {
            case .typeAddress:
                return movingItem(String(localized: "Ввести адрес"), symbol: "keyboard") { [weak self] in
                    self?.presentSearch()
                }
            case .voice:
                let hint = String(localized: "Скажите Siri: «Найди адрес в RadarMap»")
                return movingItem(String(localized: "Сказать адрес"), detail: hint, symbol: "mic.fill") { [weak self] in
                    self?.env.alerts.speak(hint)
                }
            case .slot(let index):
                let (slot, target) = slots[index]
                return movingItem(slot.name, detail: target.saved.title, symbol: slot.symbol) { [weak self] in
                    self?.route(to: target.saved, remember: target.remembers)
                }
            case .recent(let index):
                let place = recent[index]
                return movingItem(place.title, symbol: "clock.arrow.circlepath") { [weak self] in
                    self?.route(to: place)
                }
            case .category(let index):
                let kind = categories[index]
                return movingItem(kind.title, symbol: kind.symbol) { [weak self] in
                    self?.presentNearest(kind)
                }
            }
        }
        let header = keyboardLimited ? String(localized: "На ходу клавиатуры нет — выберите или скажите")
                                     : String(localized: "Машина стоит — можно ввести адрес")
        return CPListSection(items: items, header: header, sectionIndexTitle: nil)
    }

    private func movingItem(_ text: String, detail: String? = nil, symbol: String,
                            action: @escaping () -> Void) -> CPListItem {
        let item = CPListItem(text: text, detailText: detail, image: gridImage(symbol))
        item.handler = { _, completion in
            action()
            completion()
        }
        return item
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
        guard beginPush("результаты поиска") else { return }
        interfaceController?.pushTemplate(template, animated: true) { [weak self] _, error in
            Task { @MainActor [weak self] in self?.endPush() }
            if let error {
                Log.carplay.error("pushTemplate(результаты поиска): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func presentAssign(_ slot: PlaceSlot) {
        guard CarPlaySearchEntry.slotTap(hasPlace: false, keyboardLimited: currentKeyboardLimited()) == .assign else {
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
        guard CarPlaySearchEntry.pushAllowed(startedAt: pushStartedAt, now: Date(),
                                             guardSeconds: AppConfig.carPlayPushGuardSeconds) else {
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
        let usual = CarPlaySlotTarget.usual(slot, commute: env.commute)
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
            // Выученное место в «недавние» не пишем (CarPlaySlotTarget.remembers).
            route(to: place.saved, remember: place.remembers)
        }
    }

    /// Куда ведёт слот: заданный руками адрес или выученное по поездкам место.
    func slotPlace(_ slot: PlaceSlot) -> CarPlaySlotTarget? {
        CarPlaySlotTarget.resolve(slot, manual: env.settings.place(for: slot), learned: env.learnedPlaces)
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
    /// Само построение и защита от двойного касания — общие с плиткой
    /// главного экрана (CarPlayRouteRequest).
    func route(to place: SavedPlace, allowPreview: Bool = true, remember: Bool = true) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var preview = false
            let outcome = await CarPlayRouteRequest.run(
                env: env, to: place, remember: remember,
                prepare: {
                    popToMap()
                    // Выбор маршрута — только стоя (CarPlayTripPreview): на ходу
                    // ведём рекомендованным, как раньше. Флаг — ДО построения: иначе
                    // сессия навигации стартовала бы на первом варианте раньше выбора.
                    preview = allowPreview && CarPlayTripPreview.shouldPreview(speedKmh: env.location.speedKmh)
                    if previewTrip != nil { mapTemplate?.hideTripPreviews() }
                    previewTrip = nil
                    previewOffer = nil
                    previewAskedInCar = preview
                    // Карточки на экране больше нет; новая поставит флаг сама.
                    self.env.route.choiceShownInCar = false
                    model.isPreviewing = preview
                    return preview
                },
                startsTrip: {
                    switch CarPlayBuiltChoice.decide(wantedChoice: preview, stillChoosing: model.isPreviewing,
                                                     hasRoute: env.route.isActive,
                                                     failed: env.route.errorMessage != nil) {
                    case .showChoice:
                        showPreview(name: place.title, destination: place.coordinate)
                        return false
                    case .nothing:
                        Log.carplay.notice("маршрут достроился после «Отмены» — поездку не начинаю")
                        return false
                    case .startTrip:
                        if preview { endPreview(start: false, keepRoute: true, reason: "маршрут не построен") }
                        return true
                    }
                })
            switch outcome {
            case .built:
                // Цель подтверждена касанием («куда едем?») — второго экрана
                // выбора водитель не просил и после остановки не получит.
                if !allowPreview { Self.choiceOffer.spend(route: choiceOfferKey()) }
            case .busy:
                break
            case .noFix:
                showAlert(title: String(localized: "Ждём спутники"),
                          message: String(localized: "Положение ещё не определено — попробуйте через несколько секунд."))
            case .failed(let error):
                showAlert(title: String(localized: "Маршрут не построен"), message: error)
            }
        }
    }

    /// Варианты с нашими метками и временем с пробками; рекомендованный —
    /// первым и выбранным. Линия — целиком на экране.
    /// `offer` — список открыт из баннера «Есть другие варианты»; любой другой
    /// показ (новый маршрут при открытом списке) — обычный: его «Отмена» снимает
    /// маршрут.
    func showPreview(name: String, destination: CLLocationCoordinate2D,
                     offer: (route: Int, origin: Int, ids: Set<Int>)? = nil) {
        previewOffer = offer
        guard mapTemplate != nil else {
            return endPreview(start: true, keepRoute: true, reason: "шаблона нет")
        }
        previewDestination = destination
        previewName = name
        presentChoices(reason: "показ")
        model.showOverview()
        watchMovingOff()
    }

    /// Строки вариантов сейчас — по ним видно, устарела ли карточка.
    private func previewTexts() -> [Int: CarPlayTripPreview.ChoiceText] {
        let variants = previewVariants
        return Dictionary(variants.map { ($0.id, CarPlayTripPreview.text(for: $0, among: variants)) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Поставить карточку выбора по текущим вариантам: выбранный — первым и
    /// выделенным. Обзор и слежение за «тронулись» — у `showPreview`:
    /// пересоздание из-за времени не должно ни двигать карту, ни обнулять
    /// отсчёт автостарта.
    private func presentChoices(reason: String) {
        guard let mapTemplate, let destination = previewDestination else { return }
        let route = env.route
        // Выбор на экране машины — касание (40I, дефект 35): поздние пробки
        // больше не двигают метки и выбранный вариант, а то карточка машины
        // (её строки после показа не меняются) расходилась бы с линией и с
        // тем, чем поведёт автостарт. Время вариантов обновляется дальше.
        // Здесь, а не в showPreview: новый набор к той же цели (перестроили
        // на телефоне) приходит сюда пересозданием. Сам такой набор
        // замерзает ещё в `apply` (`choiceShownInCar`), до поздних пробок.
        route.noteChoiceTouched()
        route.choiceShownInCar = true
        // Список показан — предлагать его баннером больше незачем.
        Self.choiceOffer.spend(route: choiceOfferKey())
        let variants = previewVariants
        let texts = previewTexts()
        let ordered = variants.filter { $0.id == route.selectedID } + variants.filter { $0.id != route.selectedID }
        let choices = ordered.compactMap { variant -> CPRouteChoice? in
            guard let text = texts[variant.id] else { return nil }
            let choice = CPRouteChoice(summaryVariants: text.summary,
                                       additionalInformationVariants: text.additional,
                                       selectionSummaryVariants: text.selection)
            choice.userInfo = variant.id
            return choice
        }
        let origin = MKMapItem(placemark: MKPlacemark(coordinate: env.location.currentCoordinate ?? destination))
        let target = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        target.name = previewName
        let trip = CarPlayGuidance.makeTrip(origin: origin, destination: target, choices: choices)
        if previewTrip != nil { mapTemplate.hideTripPreviews() }
        previewTrip = trip
        // Опознание — по всему набору маршрута (его же сверяет refresh), а не
        // по показанным: список из баннера показывает не все варианты.
        previewShown = CarPlayTripPreview.Shown(set: CarPlayTripPreview.identity(route.variants),
                                                order: ordered.map(\.id), texts: texts)
        previewEstimateKey = nil
        let text = CPTripPreviewTextConfiguration(startButtonTitle: String(localized: "Поехали"),
                                                  additionalRoutesButtonTitle: String(localized: "Варианты"),
                                                  overviewButtonTitle: String(localized: "Обзор"))
        mapTemplate.showTripPreviews([trip], selectedTrip: trip, textConfiguration: text)
        updatePreviewEstimates(route.selected)
        Log.carplay.notice("выбор маршрута (\(reason, privacy: .public)): вариантов \(variants.count, privacy: .public), выбран \(route.selectedID, privacy: .public)")
        observePreview(trip)
    }

    /// Пока выбор на экране: смена минуты прибытия (37, ArrivalClock), время
    /// вариантов по поздним пробкам, выбор на телефоне — машина узнаёт сразу,
    /// а не только при показе и при смене варианта.
    private func observePreview(_ trip: CPTrip) {
        withObservationTracking {
            _ = env.route.arrival
            _ = env.route.variants
            _ = env.route.selectedID
            _ = env.route.isBuilding
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.previewTrip === trip else { return }
                self.refreshPreview()
                // Пересоздание завело слежение за новой карточкой само.
                if self.previewTrip === trip { self.observePreview(trip) }
            }
        }
    }

    private func refreshPreview() {
        guard model.isPreviewing, let shown = previewShown else { return }
        let route = env.route
        // Маршрут сняли, он строится или цель другая — закроет или покажет
        // заново syncChoice.
        guard route.isActive, !route.isBuilding, !route.variants.isEmpty,
              let destination = route.destinationCoordinate, let shownAt = previewDestination,
              CarPlayGuidance.same(shownAt, destination) else { return }
        switch CarPlayTripPreview.refresh(shown, selected: route.selectedID,
                                          set: CarPlayTripPreview.identity(route.variants),
                                          texts: previewTexts()) {
        case .estimates:
            updatePreviewEstimates(route.selected)
        case .rebuild:
            presentChoices(reason: "обновление")
        }
    }

    func updatePreviewEstimates(_ variant: RouteService.Variant?) {
        guard let trip = previewTrip, let variant, let mapTemplate else { return }
        // Показанное время — с личным темпом, как на телефоне (решение 28.10).
        // Машина прибавляет остаток к своим часам — остаток до той же минуты,
        // что на панели телефона (ArrivalClock, 37): выбранный вариант — по
        // `route.arrival`, остальные — тем же правилом минуты.
        let now = Date()
        let arrival = variant.id == env.route.selectedID ? env.route.arrival : nil
        let target = arrival ?? ArrivalClock.rounded(ArrivalClock.raw(now: now, remaining: variant.shownTime))
        let tone = CarPlayTripPreview.timeColor(trafficDelay: variant.shownTrafficDelay)
        // Та же минута, путь и цвет — не слать: каждая отправка перерисовывает
        // карточку на головном устройстве.
        let key = "\(variant.id)|\(target.timeIntervalSince1970)|\(Int(variant.distance))|\(tone)"
        guard key != previewEstimateKey else { return }
        previewEstimateKey = key
        let seconds = ArrivalClock.secondsUntil(target, now: now)
        let estimates = CarPlayGuidance.tripEstimates(meters: variant.distance, seconds: seconds)
        let color: CPTimeRemainingColor = switch tone {
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
        previewShown = nil
        previewEstimateKey = nil
        previewOffer = nil
        previewAskedInCar = false
        env.route.choiceShownInCar = false
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
        guard CarPlaySearchEntry.pick(routeActive: env.route.isActive, previewing: model.isPreviewing)
                == .askStopOrReplace else { return route(to: place) }
        guard beginPush("заезд или цель") else { return }
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
        interfaceController?.presentTemplate(sheet, animated: true) { [weak self] _, error in
            Task { @MainActor [weak self] in self?.endPush() }
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
}
