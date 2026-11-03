//
//  CarPlaySceneDelegate+Buttons.swift
//  RadarMap
//
//  Кнопки шаблона: панель, карта, поездка, звук, иконки.
//

import CarPlay
import SwiftUI
import os

extension CarPlaySceneDelegate {

    /// Единая пересборка кнопок: и бар, и кнопки карты зависят от состояния
    /// (идёт поездка, построен маршрут, включён звук). Читаем состояние внутри
    /// withObservationTracking — при любом изменении собираем заново.
    func syncTemplate() {
        guard let mapTemplate else { return }
        // Кнопки шаблона живут на головном устройстве: каждое присваивание —
        // сообщение туда, а не запись в память.
        MainWork.note(MainWork.Name.carButtons)
        defer { MainWork.note(MainWork.idle) }
        let session = session   // подписка живёт до первого изменения — привязываем к сессии
        syncGeneration &+= 1
        let generation = syncGeneration

        withObservationTracking {
            let tripActive = env.location.isTripActive
            let routeActive = env.route.isActive
            // Читает оба тумблера — оба и отслеживаем.
            let sound = CarPlaySoundChoice.current(soundEnabled: env.settings.soundEnabled,
                                                   voiceMode: env.settings.voiceMode)
            let following = model.isFollowing
            let panning = isPanning
            let previewing = model.isPreviewing

            // Осмотр по правилам CarPlay: система своей кнопки выхода не даёт
            // и требует её В БАРЕ (заголовок CPMapTemplate). Раньше «выйти»
            // было кнопкой карты, а бар после осмотра никто не возвращал — и
            // в 2.2.3 он исчезал насовсем: без «Поездки», «Куда» и «Радар!».
            let bar = [tripActive, routeActive, panning, previewing]
            if bar != sentBar || sound != sentSound {
                sentBar = bar
                sentSound = sound
                Log.carplay.notice("бар шаблона: поездка=\(tripActive), маршрут=\(routeActive), звук=\(String(describing: sound), privacy: .public), осмотр=\(panning), выбор=\(previewing)")
                if panning {
                    mapTemplate.leadingNavigationBarButtons = []
                    mapTemplate.trailingNavigationBarButtons = [panDoneButton]
                } else if previewing {
                    mapTemplate.leadingNavigationBarButtons = [cancelPreviewButton]
                    mapTemplate.trailingNavigationBarButtons = []
                } else {
                    mapTemplate.leadingNavigationBarButtons = [tripButton(active: tripActive),
                                                               soundButton(sound)]
                    mapTemplate.trailingNavigationBarButtons = [destinationsButton(routeActive: routeActive),
                                                                reportButton]
                }
            }
            // Набор — по состоянию (CarPlayMapButtons): в поездке первой
            // стоит «Радар!», в осмотре — ровно зум (система показывает там
            // не больше двух и прячет лишние с конца).
            let buttons = CarPlayMapButtons.layout(tripActive: tripActive, following: following,
                                                   panning: panning, previewing: previewing)
            if buttons != sentMapButtons {
                sentMapButtons = buttons
                Log.carplay.notice("кнопки карты: \(String(describing: buttons), privacy: .public)")
                mapTemplate.mapButtons = buttons.map(mapButton)
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session == session,
                      self.syncGeneration == generation else { return }
                self.syncTemplate()
            }
        }
    }

    // MARK: - Кнопки бара

    /// «Поездка» / «Завершить» — главный тумблер: включает активные оповещения.
    /// Кнопки бара — значками, как у Amap и Google на том же экране: в баре
    /// CarPlay с iOS 26 кнопка — стеклянная капсула, и слово в ней читалось
    /// мельче и дольше значка. Фолбэк — словом (`barButton`), а не пустой
    /// картинкой: невидимая нажимаемая кнопка хуже подписи.
    ///
    /// Значки — голые глифы, без своей подложки: капсулу рисует система, и
    /// ▶ в круге, ромб и пузырь внутри неё читались тяжёлыми чёрными кляксами
    /// разной формы («иконки красиво нужно», владелец, 12.10). И те же, что
    /// на телефоне: ▶ / ■ — «Начать поездку» и «Стоп», динамик — звук. Один
    /// глиф на одно действие на обоих экранах. Исключение — «Радар!»: она в
    /// баре словом (`reportButton`, 25.H3).
    func barButton(symbol: String, title: String,
                           handler: @escaping (CPBarButton) -> Void) -> CPBarButton {
        if let image = buttonImage(symbol) {
            return CPBarButton(image: image, handler: handler)
        }
        return CPBarButton(title: title, handler: handler)
    }

    func tripButton(active: Bool) -> CPBarButton {
        barButton(symbol: active ? "stop.fill" : "play.fill",
                  title: active ? String(localized: "Завершить")
                                : String(localized: "Поездка")) { [weak self] _ in
            guard let self else { return }
            let location = env.location
            // Без разрешения startTrip выходит первой строкой и молча ничего
            // не делает: заголовок кнопки остаётся «Поездка», водитель жмёт
            // ещё раз и решает, что приложение сломано. Говорим вслух.
            guard location.isAuthorized else { return self.showNoPermissionAlert() }
            // Второе нажатие сразу после переключения — это «нажалось ли?», а
            // не решение. Журнал 12.10 (carplay12): старт и через 0,6–0,9 с
            // конец «0 м, не сохранена», дважды подряд, — водитель не видел
            // ответа на первое нажатие и жал ещё раз, а стоя второе нажатие
            // завершает без вопроса. Кнопка «не работала».
            if let last = lastTripToggle,
               Date().timeIntervalSince(last) < AppConfig.carPlayTripToggleGuard {
                Log.carplay.notice("поездка: повторное нажатие через \(Date().timeIntervalSince(last), format: .fixed(precision: 1), privacy: .public) с — пропускаю")
                return
            }
            lastTripToggle = Date()
            guard location.isTripActive else {
                location.startTrip()
                // Ответ на нажатие — словами: смена значка в баре доходит до
                // машины не сразу, и одной её мало.
                if location.isTripActive {
                    showToast(String(localized: "Поездка началась — слежу за камерами"), speakIfHidden: true)
                }
                return
            }
            // На ходу — подтверждение: «Завершить» соседствует со звуком, и
            // промах слепого тапа молча выключал бы оповещения о камерах.
            // На стоянке тап осознанный — завершаем сразу, как раньше.
            if location.speedKmh >= AppConfig.carPlayEndTripConfirmKmh {
                confirmEndTrip()
            } else {
                endTripAndRoute()
            }
        }
    }

    /// «Стоп» в машине — конец ведения целиком, как «Завершить» в Apple Maps.
    /// До 12.10 маршрут переживал стоп, и машина продолжала по нему вести —
    /// карточка «Поверните налево», прибытие — под тостом «Поездка
    /// завершена» и кнопкой ▶ («пишет завершена, но не сбрасывается»).
    /// `toast` — ответ словами на слепой тап; после диалога «Завершить?»
    /// ответ уже дан, а второй модальный шаблон вслед закрывающемуся CarPlay
    /// отклоняет.
    func endTripAndRoute(toast: Bool = true) {
        let hadRoute = env.route.isActive
        env.location.endTrip()   // ручной стоп снимает и маршрут (NavigationFlow)
        Log.carplay.notice("стоп из машины: маршрут \(hadRoute ? "снят" : "не был", privacy: .public)")
        guard toast else { return }
        showToast(hadRoute ? String(localized: "Маршрут завершён")
                           : String(localized: "Поездка завершена"), speakIfHidden: true)
    }

    /// «Завершить поездку?» на ходу. Тот же паттерн, что у Apple Maps: конец
    /// маршрута не висит одним тапом на баре.
    ///
    /// С 19.10 — баннер навигатора, а не окно на весь экран: карта и манёвр
    /// под ним остаются (аудит CarPlay 18.10, P0-3; модальное окно на ходу
    /// Руководство оставляет только ошибкам). Окно — запасной путь, если
    /// баннер сейчас не встанет: на экране баннер камеры, он важнее.
    func confirmEndTrip() {
        let title = env.route.isActive ? String(localized: "Завершить маршрут?")
                                       : String(localized: "Завершить поездку?")
        if let banners {
            let banner = CPNavigationAlert(
                titleVariants: [title],
                subtitleVariants: [],
                image: nil,
                primaryAction: CPAlertAction(title: String(localized: "Завершить"),
                                             style: .destructive) { [weak self] _ in
                    self?.endTripAndRoute(toast: false)
                },
                secondaryAction: CPAlertAction(title: String(localized: "Продолжить"),
                                               style: .cancel) { _ in },
                duration: AppConfig.carPlayEndConfirmSeconds)
            if banners.show(banner, kind: .request) { return }
        }
        let alert = CPAlertTemplate(
            titleVariants: [title],
            actions: [
                CPAlertAction(title: String(localized: "Завершить"),
                              style: .destructive) { [weak self] _ in
                    self?.dismissTopTemplate()
                    self?.endTripAndRoute(toast: false)
                },
                CPAlertAction(title: String(localized: "Отмена"),
                              style: .cancel) { [weak self] _ in
                    self?.dismissTopTemplate()
                },
            ])
        interfaceController?.presentTemplate(alert, animated: true) { _, error in
            if let error {
                Log.carplay.error("presentTemplate(завершение): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Закрыть верхний модальный шаблон, не глотая ошибку.
    func dismissTopTemplate(then: (@MainActor () -> Void)? = nil) {
        interfaceController?.dismissTemplate(animated: true) { _, error in
            if let error {
                Log.carplay.error("dismissTemplate: \(error.localizedDescription, privacy: .public)")
            }
            guard let then else { return }
            Task { @MainActor in then() }
        }
    }

    /// Единственная причина, по которой экран машины может быть мёртв целиком.
    /// Настройки iOS с CarPlay не открыть, поэтому честно объясняем, что
    /// сделать на телефоне.
    func showNoPermissionAlert() {
        showAlert(title: String(localized: "Нет доступа к геопозиции"),
                  message: String(localized: "Откройте RadarMap на телефоне и разрешите доступ «Всегда» — без него я не вижу дорогу и молчу о камерах."))
    }

    /// «Куда» — сетка направлений (с маршрутом — и заезд, и «Завершить
    /// маршрут»). Лупа в обоих состояниях: кнопка на том же месте с тем же
    /// значком находится вслепую; ромб «маршрут» прежде менял её облик
    /// посреди поездки.
    func destinationsButton(routeActive: Bool) -> CPBarButton {
        barButton(symbol: "magnifyingglass",
                  title: routeActive ? String(localized: "Маршрут")
                                     : String(localized: "Куда")) { [weak self] _ in
            self?.presentDestinations()
        }
    }

    /// «Отметить» на ходу (вариант B, 02.11): касание запоминает точку и
    /// ставит баннер выбора — тренога сама через 3 с, пост и ДТП кнопкой,
    /// крестик — ничего (`beginReport`). Слово, а не значок (25.H3): значок
    /// волн без подписи в машине читался как AirPlay (владелец 21.10). Слово
    /// то же, что на кнопке телефона.
    var reportButton: CPBarButton {
        CPBarButton(title: String(localized: "Отметить")) { [weak self] _ in
            self?.beginReport(source: .carBar)
        }
    }

    // MARK: - Кнопки карты

    func mapButton(_ kind: CarPlayMapButtons.Kind) -> CPMapButton {
        switch kind {
        case .report: reportMapButton
        case .zoomIn: zoomInButton
        case .zoomOut: zoomOutButton
        case .pan: panButton
        case .recenter(let following): recenterButton(following: following)
        }
    }

    /// «Отметить» кнопкой карты в поездке (25.H3): крупная круглая цель у
    /// края, куда рука идёт вслепую, — бар для этого мелок. Картинка — жёлтый
    /// диск (`CarPlayReportImage`): со словом, если оно читается (≥ 9 pt), иначе
    /// значком треноги. Действие — то же, что у бара.
    var reportMapButton: CPMapButton {
        let button = CPMapButton { [weak self] _ in self?.beginReport(source: .carMap) }
        let title = String(localized: "Отметить")
        let scale = interfaceController?.carTraitCollection.displayScale ?? 2
        button.image = CarPlayReportImage.render(title: title, scale: scale)
        button.focusedImage = CarPlayReportImage.render(title: title, scale: scale, focused: true)
        return button
    }

    /// «К себе». Значок показывает СОСТОЯНИЕ, а не только действие: залитый —
    /// карта едет за машиной, контурный — водитель отпанорамировал в сторону и
    /// карта стоит. Раньше значок был один на оба случая, и единственный способ
    /// понять, следит ли карта, был подождать и посмотреть, уехала ли метка.
    func recenterButton(following: Bool) -> CPMapButton {
        let button = CPMapButton { [model] _ in model.recenter() }
        button.image = buttonImage(following ? "location.fill" : "location")
        return button
    }

    /// Вход в осмотр карты. Обязателен: на машинах без сенсора крутилкой
    /// панорамируют только из осмотра. Выход — «Готово» в баре (так требует
    /// CarPlay: своей кнопки выхода система не рисует). Значок — стрелки в
    /// четыре стороны, как у Apple Maps в машине: «рука» читалась как
    /// «рисовать».
    var panButton: CPMapButton {
        let button = CPMapButton { [weak self] _ in
            guard let self, let mapTemplate else { return }
            // Бар «Готово» — ДО входа: если отправка после DidShow потеряется,
            // из осмотра будет не выйти.
            if !isPanning {
                isPanning = true
                syncTemplate()
            }
            mapTemplate.showPanningInterface(animated: true)
            // Таймер бездействия — с открытия: осмотр, в котором ничего не
            // тронули, тоже закроется сам.
            model.panningShown()
        }
        button.image = buttonImage("arrow.up.and.down.and.arrow.left.and.right")
        return button
    }

    /// «Готово» — выход из осмотра, единственная кнопка бара на это время.
    var panDoneButton: CPBarButton {
        CPBarButton(title: String(localized: "Готово")) { [weak self] _ in
            self?.leavePanning(reason: "Готово")
        }
    }

    var zoomInButton: CPMapButton {
        let button = CPMapButton { [model] _ in
            model.zoom(in: true)
        }
        button.image = buttonImage("plus")
        return button
    }

    var zoomOutButton: CPMapButton {
        let button = CPMapButton { [model] _ in
            model.zoom(in: false)
        }
        button.image = buttonImage("minus")
        return button
    }

    /// Звук в машине (10.1): значок — нынешний выбор, нажатие — короткий
    /// список. Раньше кнопка только глушила всё разом; водителю с пассажиром
    /// нужна середина — «только при превышении» или «только сигнал».
    /// HUD по-прежнему пишет «Без звука» (CarPlayStatusChips) — в баре звук
    /// стоит рядом с «Поездкой», и промах слепого тапа заметен.
    func soundButton(_ sound: CarPlaySoundChoice) -> CPBarButton {
        barButton(symbol: sound.symbol, title: sound.shortTitle) { [weak self] _ in
            self?.presentSoundSheet()
        }
    }

    /// Список выбора: три строки, кроме нынешней (она — в заголовке), и
    /// «Отмена». Лист действий — разрешённый навигатору шаблон.
    func presentSoundSheet() {
        let current = CarPlaySoundChoice.current(soundEnabled: env.settings.soundEnabled,
                                                 voiceMode: env.settings.voiceMode)
        var actions = CarPlaySoundChoice.allCases.filter { $0 != current }.map { choice in
            CPAlertAction(title: choice.title, style: choice == .silent ? .destructive : .default) { [weak self] _ in
                // Применить, когда лист закрылся: смена настроек пересобирает
                // бар, а кнопки, отправленные под уходящим модальным
                // шаблоном, головное устройство теряет (2.2.1/2.2.3).
                self?.dismissTopTemplate { [weak self] in self?.applySound(choice) }
            }
        }
        actions.append(CPAlertAction(title: String(localized: "Отмена"), style: .cancel) { [weak self] _ in
            self?.dismissTopTemplate()
        })
        let sheet = CPActionSheetTemplate(
            title: String(localized: "Звук в машине"),
            message: String(format: String(localized: "Сейчас: %@"), current.shortTitle),
            actions: actions)
        interfaceController?.presentTemplate(sheet, animated: true) { _, error in
            if let error {
                Log.carplay.error("presentTemplate(звук): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Применить выбор (10.1). Первый за поездку в машине запоминает «до
    /// машины»; каждый — что поставила машина: при выходе вернём только то,
    /// что с тех пор никто не трогал (`restoreCarSound`).
    func applySound(_ choice: CarPlaySoundChoice) {
        let current = CarPlaySoundChoice.Sound(enabled: env.settings.soundEnabled,
                                               voice: env.settings.voiceMode)
        if !Storage.bool(.carPlayMuted) {
            Storage.set(current.enabled, for: .carPlaySoundBeforeMute)
            Storage.set(current.voice.rawValue, for: .carPlayVoiceBeforeMute)
            Storage.set(true, for: .carPlayMuted)
        }
        let next = CarPlaySoundChoice.applying(choice, to: current)
        Storage.set(next.enabled, for: .carPlaySoundSet)
        Storage.set(next.voice.rawValue, for: .carPlayVoiceSet)
        Log.carplay.info("звук в машине: \(String(describing: choice), privacy: .public)")
        env.settings.soundEnabled = next.enabled
        env.settings.voiceMode = next.voice
    }

    /// «Звук» из панели «…» (iOS 27): есть звук — тишина; тишина — то, что
    /// было до неё в этой машине (CarPlayOptionsPanelContent.soundToggle).
    func toggleSoundFromPanel() {
        let current = CarPlaySoundChoice.current(soundEnabled: env.settings.soundEnabled,
                                                 voiceMode: env.settings.voiceMode)
        let before = Storage.bool(.carPlayMuted)
            ? CarPlaySoundChoice.current(
                soundEnabled: Storage.bool(.carPlaySoundBeforeMute),
                voiceMode: Storage.string(.carPlayVoiceBeforeMute).flatMap(VoiceMode.init(rawValue:)) ?? .smart)
            : nil
        applySound(CarPlayOptionsPanelContent.soundToggle(current: current, before: before))
    }

    /// Вышли из машины: звук — атрибут поездки, а не настройка. Без отката
    /// телефон навсегда оставался бы в «Молча», и человек не связал бы это с
    /// кнопкой в машине. Откатываем только поля, которые и сейчас такие,
    /// какими их поставила машина: выбранное с тех пор руками не трогаем.
    func restoreCarSound() {
        defer { Storage.set(false, for: .carPlayMuted) }
        guard Storage.bool(.carPlayMuted) else { return }
        let before = CarPlaySoundChoice.Sound(
            enabled: Storage.bool(.carPlaySoundBeforeMute),
            voice: Storage.string(.carPlayVoiceBeforeMute).flatMap(VoiceMode.init(rawValue:)) ?? .smart)
        // Маркер прежней тишины (до 20.10) без «поставленного» — это тишина.
        let carSet = CarPlaySoundChoice.Sound(
            enabled: Storage.bool(.carPlaySoundSet),
            voice: Storage.string(.carPlayVoiceSet).flatMap(VoiceMode.init(rawValue:)) ?? .off)
        let current = CarPlaySoundChoice.Sound(enabled: env.settings.soundEnabled,
                                               voice: env.settings.voiceMode)
        let next = CarPlaySoundChoice.restoring(before: before, carSet: carSet, current: current)
        if next.enabled != current.enabled { env.settings.soundEnabled = next.enabled }
        if next.voice != current.voice { env.settings.voiceMode = next.voice }
    }

    /// Значок кнопки машины. 24 пункта, а не 20: систему кнопок рисует
    /// CarPlay, и круг под значком крупный — двадцатка сидела в нём мелкой
    /// точкой. Плитки сетки рядом идут на 36, так что 24 — это середина шкалы,
    /// а не выдуманное число.
    func buttonImage(_ symbol: String) -> UIImage? {
        UIImage(systemName: symbol,
                withConfiguration: carConfiguration(pointSize: 24, weight: .semibold))
    }

    /// Иконка плитки сетки: шаблонное изображение — CarPlay сам красит его под
    /// тему машины (днём тёмным по светлому, ночью наоборот).
    /// Значок плитки сетки — не больше `CPGridTemplate.maximumGridButtonImageSize`
    /// (40×40). Символ в 36 pt выходил 52×44 (проверено пробой, 12.10), и
    /// машина ужимала или обрезала его сама. Кегль подбирается по
    /// фактическому размеру: у разных символов разные пропорции.
    func gridImage(_ symbol: String) -> UIImage {
        let limit: CGSize
        if #available(iOS 26.0, *) {
            limit = CPGridTemplate.maximumGridButtonImageSize
        } else {
            limit = CGSize(width: AppConfig.carPlayGridImageMaxPoints, height: AppConfig.carPlayGridImageMaxPoints)
        }
        // Тип камеры — глифом камеры (29.C), шаблоном: цвет даёт система.
        if let camera = CameraGlyph(symbol: symbol) {
            let side = min(limit.width, limit.height, 36).rounded(.down)
            return CameraIconArt.glyph(camera, side: side, ink: .black, scale: AppConfig.carPlaySymbolScale)
                .withRenderingMode(.alwaysTemplate)
        }
        var pointSize: CGFloat = 36
        var image = UIImage(systemName: symbol,
                            withConfiguration: carConfiguration(pointSize: pointSize, weight: .semibold))
        if let size = image?.size, size.width > limit.width || size.height > limit.height,
           size.width > 0, size.height > 0 {
            pointSize *= min(limit.width / size.width, limit.height / size.height) * 0.98
            image = UIImage(systemName: symbol,
                            withConfiguration: carConfiguration(pointSize: pointSize, weight: .semibold))
        }
        return (image ?? UIImage()).withRenderingMode(.alwaysTemplate)
    }

    /// «Отмена» в баре на время выбора — единственная кнопка: выбор закрыт,
    /// маршрут снят, карта снова за машиной.
    var cancelPreviewButton: CPBarButton {
        CPBarButton(title: String(localized: "Отмена")) { [weak self] _ in
            self?.endPreview(start: false, keepRoute: false, reason: "Отмена")
        }
    }
}
