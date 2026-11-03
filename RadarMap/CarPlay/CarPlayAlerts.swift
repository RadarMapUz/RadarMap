//
//  CarPlayAlerts.swift
//  RadarMap
//
//  Разговор с водителем на экране машины: подтверждения, короткие ответы и
//  вопросы после проезда — «радар ещё стоял?» и «ещё перекрыто?».
//
//  Вынесено из CarPlaySceneDelegate — тот отвечает за жизненный цикл сцены и
//  сборку шаблонов, и разговор с водителем в нём был третьей обязанностью.
//
//  Общее правило файла: в машине разговаривают ШАБЛОНАМИ, а не рисованием —
//  в окне карты касаний нет, нарисованные кнопки были бы мёртвыми. И карту
//  не закрывают: подтверждения и вопрос — баннером навигатора поверх неё
//  (CarPlayBanners), а не модальным окном на весь экран, как до 18.10
//  (аудит 18.10, п. 4). Модальное окно остаётся только для ошибки в ответ на
//  действие водителя — там ответ обязан дойти.
//

import CarPlay
import os

extension CarPlaySceneDelegate {

    // MARK: - «Радар ещё стоял?» в машине

    /// Вопрос после реального проезда мимо чужой отметки — радара или
    /// события дороги (MobileCameraService.passQuestion: один за раз, радар
    /// первым). Оба — один вид баннера, `.question`, с одними правилами.
    ///
    /// Молчание по-прежнему ничего не отправляет: «не знаю» портит данные
    /// сильнее, чем их отсутствие, поэтому баннер, закрытый или истёкший без
    /// ответа, равносилен «Пропустить» (CarPlaySceneDelegate.didDismiss).
    func observePendingConfirm() {
        let session = session
        withObservationTracking {
            _ = env.mobile.passQuestion?.id
            // И тревогу тоже: вопрос ждёт, пока впереди камера, — значит,
            // снятие тревоги обязано перепоказать вопрос.
            _ = env.location.isApproachingCamera
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                self.presentPendingConfirmIfNeeded()
                self.observePendingConfirm()
            }
        }
    }

    func presentPendingConfirmIfNeeded() {
        env.mobile.expireStaleConfirm()
        guard let banners else { return }
        let pending = env.mobile.passQuestion
        // Показанный вопрос ещё про ту же отметку — всё на месте.
        if confirmBanner != nil, pending?.id == confirmBannerID { return }
        // Показан, а ответ уже не нужен (истёк, отвечен на телефоне) или
        // вопрос теперь о другой отметке. Оставленный, он принимал бы «Нет»
        // за отметку, о которой не спрашивал.
        let stale = confirmBanner
        confirmBanner = nil
        confirmBannerID = nil
        guard let question = pending, question.id != skippedConfirmID, canAskNow() else {
            if let stale { banners.dismiss(stale) }
            return
        }
        let id = question.id
        let titles: [String]
        let symbolName: String
        // Кнопки — по типу отметки (12.7): про пост «Стоит» / «Пост убрали».
        var yesTitle = String(localized: "Да")
        var noTitle = String(localized: "Нет")
        switch question {
        case .camera(let camera):
            // Вопрос — тот же, что на телефоне, для всех типов (словарь
            // 02.11): «Тренога ещё стоит?» — «Стоит» / «Убрали».
            let asked = MobilePassWatch.question(for: camera.kind)
            titles = [asked.title, MobilePassWatch.shortQuestion]
            symbolName = camera.kind.symbolName
            yesTitle = asked.yes
            noTitle = asked.no
        case .road(let event):
            titles = [RoadEventPassWatch.question(for: event.kind)]
            symbolName = (ReportKind(rawValue: event.kind.rawValue) ?? .closure).symbol
        }
        let alert = CPNavigationAlert(
            titleVariants: titles,
            subtitleVariants: [],
            image: CarPlayGuidance.symbol(symbolName, pointSize: 30,
                                          onDark: model.carIsDark ?? !model.isDaylight),
            primaryAction: CPAlertAction(title: yesTitle, style: .default) { [weak self] _ in
                self?.env.mobile.answerPassQuestion(stillThere: true, for: id)
            },
            secondaryAction: CPAlertAction(title: noTitle, style: .destructive) { [weak self] _ in
                self?.env.mobile.answerPassQuestion(stillThere: false, for: id)
            },
            duration: AppConfig.carPlayQuestionSeconds)
        // Прежний вопрос заменит новый сам (show). Занято важнее (камера,
        // объезд) — вопрос вернётся, когда экран освободится (bannersFreed).
        guard banners.show(alert, kind: .question) else {
            if let stale { banners.dismiss(stale) }
            return
        }
        confirmBanner = alert
        confirmBannerID = id
        if case .road = question {
            Log.carplay.notice("вопрос «ещё перекрыто?»: баннер")
        } else {
            Log.carplay.notice("вопрос «ещё на месте?»: баннер")
        }
    }

    /// Можно ли спросить сейчас. Баннер живёт на шаблоне карты: под «Куда»
    /// или поиском, как и поверх чужого приложения, его не видно, и он истёк
    /// бы непрочитанным — то есть «пропущенным». Вернёт вопрос возврат к
    /// карте (templateDidAppear) или к RadarMap (sceneDidBecomeActive).
    private func canAskNow() -> Bool {
        guard shownTemplate == nil, model.isOnScreen,
              // Пока впереди камера, вопрос ждёт: перекрывать предупреждение
              // вопросом — ровно то, чего делать нельзя.
              !env.location.isApproachingCamera else { return false }
        // Только стоя или ползком: ответ на ходу — второй взгляд на экран.
        // Вопрос живёт `mobileConfirmMaxAgeSeconds` — до светофора доживает.
        guard env.location.speedKmh < AppConfig.carPlayQuestionMaxKmh else {
            waitToAsk()
            return false
        }
        return true
    }

    /// Вопрос висит, а машина едет: проверить остановку изредка, пока он жив.
    private func waitToAsk() {
        guard confirmWatch == nil else { return }
        let session = session
        confirmWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await Task.pause(seconds: AppConfig.carPlayQuestionPollSeconds)
                guard let self, self.session == session else { return }
                guard self.env.mobile.passQuestion != nil, self.confirmBanner == nil else {
                    self.confirmWatch = nil
                    return
                }
                guard self.env.location.speedKmh < AppConfig.carPlayQuestionMaxKmh else { continue }
                self.confirmWatch = nil
                self.presentPendingConfirmIfNeeded()
                return
            }
        }
    }

    // MARK: - Ответы водителю

    func popToMap(then: (@MainActor () -> Void)? = nil) {
        // Баннер живёт на шаблоне карты, а диалог поверх летящего возврата
        // CarPlay отклоняет — всё, что нужно показать после, ждёт completion.
        interfaceController?.popToRootTemplate(animated: true) { _, error in
            if let error {
                Log.carplay.error("popToRootTemplate: \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in then?() }
        }
    }

    /// Ошибка в ответ на действие водителя («Маршрут не построен») — модальным
    /// окном: ответ на тап обязан дойти, даже если поверх карты другой шаблон.
    ///
    /// titleVariants — это взаимоисключающие варианты ОДНОГО заголовка от
    /// длинного к короткому (шаблон покажет тот, что влезет), а не «заголовок
    /// плюс текст»: передавая сюда две разные фразы, мы гарантировали, что
    /// вторую водитель не увидит никогда. Склеиваем в одну строку и даём
    /// короткий запасной вариант для узких экранов.
    func showAlert(title: String, message: String) {
        let alert = CPAlertTemplate(titleVariants: [title + ". " + message, title],
                                    actions: [CPAlertAction(title: String(localized: "Понятно"),
                                                            style: .cancel) { [weak self] _ in
            self?.dismissTopTemplate()
        }])
        interfaceController?.presentTemplate(alert, animated: true) { _, error in
            if let error {
                Log.carplay.error("presentTemplate(алерт): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Короткое подтверждение («Поездка началась», итог поездки) — баннером
    /// поверх карты: гаснет сам, нажимать ничего не нужно, и карта видна.
    /// Уступает всему важнее: опоздавшее подтверждение не показывается.
    /// `speakIfHidden` — ответ на тап водителя: если баннер не встал (впереди
    /// камера), он звучит голосом — иначе тап остался бы без ответа.
    /// true — баннер на экране (очередь его приняла).
    @discardableResult
    func showToast(_ text: String, variants: [String]? = nil, speakIfHidden: Bool = false) -> Bool {
        let alert = CPNavigationAlert(
            titleVariants: variants ?? [text],
            subtitleVariants: nil,
            image: nil,
            primaryAction: CPAlertAction(title: String(localized: "ОК"), style: .cancel) { _ in },
            secondaryAction: nil,
            duration: AppConfig.carPlayToastSeconds)
        let shown = banners?.show(alert, kind: .info) ?? false
        if !shown, speakIfHidden { env.alerts.speak(text) }
        return shown
    }
}
