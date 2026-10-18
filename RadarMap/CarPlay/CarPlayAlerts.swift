//
//  CarPlayAlerts.swift
//  RadarMap
//
//  Разговор с водителем на экране машины: подтверждения, короткие ответы и
//  вопрос «радар ещё стоял?».
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

    /// Вопрос после реального проезда мимо чужой отметки.
    ///
    /// Молчание по-прежнему ничего не отправляет: «не знаю» портит данные
    /// сильнее, чем их отсутствие, поэтому баннер, закрытый или истёкший без
    /// ответа, равносилен «Пропустить» (CarPlaySceneDelegate.didDismiss).
    func observePendingConfirm() {
        let session = session
        withObservationTracking {
            _ = env.mobile.pendingConfirm
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
        // Вопрос на экране, а ответ уже не нужен (истёк, отвечен на телефоне)
        // или теперь он про другую отметку — снять. Оставленный, он принимал
        // бы «Нет» за отметку, о которой не спрашивал.
        if let shown = confirmBanner, env.mobile.pendingConfirm?.id != confirmBannerID {
            confirmBanner = nil
            confirmBannerID = nil
            banners.dismiss(shown)
        }
        guard let camera = env.mobile.pendingConfirm, confirmBanner == nil else { return }
        // Пока впереди камера, вопрос ждёт: перекрывать предупреждение
        // вопросом — ровно то, чего делать нельзя.
        guard !env.location.isApproachingCamera else { return }
        // Только стоя или ползком: ответ на ходу — второй взгляд на экран.
        // Вопрос живёт `mobileConfirmMaxAgeSeconds` — до светофора доживает.
        guard env.location.speedKmh < AppConfig.carPlayQuestionMaxKmh else { return waitToAsk() }
        let id = camera.id
        let alert = CPNavigationAlert(
            titleVariants: [String(format: String(localized: "%@ ещё на месте?"), camera.kind.displayName),
                            String(localized: "Ещё на месте?")],
            subtitleVariants: [],
            image: CarPlayGuidance.symbol(camera.kind.symbolName, pointSize: 30,
                                          onDark: model.carIsDark ?? !model.isDaylight),
            primaryAction: CPAlertAction(title: String(localized: "Да"), style: .default) { [weak self] _ in
                self?.env.mobile.answerConfirm(stillThere: true, for: id)
            },
            secondaryAction: CPAlertAction(title: String(localized: "Нет"), style: .destructive) { [weak self] _ in
                self?.env.mobile.answerConfirm(stillThere: false, for: id)
            },
            duration: AppConfig.carPlayQuestionSeconds)
        // Занято важнее (камера, объезд) — вопрос вернётся, когда экран
        // освободится (bannersFreed).
        guard banners.show(alert, kind: .question) else { return }
        confirmBanner = alert
        confirmBannerID = id
        Log.carplay.notice("вопрос «ещё на месте?»: баннер")
    }

    /// Вопрос висит, а машина едет: проверить остановку изредка, пока он жив.
    private func waitToAsk() {
        guard confirmWatch == nil else { return }
        let session = session
        confirmWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await Task.pause(seconds: AppConfig.carPlayQuestionPollSeconds)
                guard let self, self.session == session else { return }
                guard self.env.mobile.pendingConfirm != nil, self.confirmBanner == nil else {
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
    func showToast(_ text: String, variants: [String]? = nil) {
        guard let banners else { return }
        let alert = CPNavigationAlert(
            titleVariants: variants ?? [text],
            subtitleVariants: nil,
            image: nil,
            primaryAction: CPAlertAction(title: String(localized: "ОК"), style: .cancel) { _ in },
            secondaryAction: nil,
            duration: AppConfig.carPlayToastSeconds)
        banners.show(alert, kind: .info)
    }
}
