//
//  CarPlayAlerts.swift
//  RadarMap
//
//  Диалоги на экране машины: подтверждения, короткие ответы и вопрос
//  «радар ещё стоял?».
//
//  Вынесено из CarPlaySceneDelegate — тот отвечает за жизненный цикл сцены и
//  сборку шаблонов, и разговор с водителем в нём был третьей обязанностью.
//
//  Общее правило файла: в машине разговаривают ШАБЛОНАМИ, а не рисованием.
//  Слой поверх карты намеренно не принимает касания (жесты должны доходить до
//  карты), поэтому нарисованные в нём кнопки были бы мёртвыми; шаблон и
//  нажимается, и озвучивается системой.
//

import CarPlay
import os

extension CarPlaySceneDelegate {

    // MARK: - «Радар ещё стоял?» в машине

    /// Вопрос после реального проезда мимо чужой отметки.
    ///
    /// На телефоне это плашка в HUD, но здесь так нельзя: слой поверх карты
    /// CarPlay намеренно `allowsHitTesting(false)`, чтобы жесты доходили до
    /// карты, — нарисованные в нём кнопки были бы мёртвыми. Правильная форма
    /// в машине — шаблон: он и нажимается, и озвучивается системой.
    ///
    /// Молчание по-прежнему ничего не отправляет: «не знаю» портит данные
    /// сильнее, чем их отсутствие, поэтому у диалога есть третий выход
    /// «Пропустить», а закрытие руками равносильно ему.
    func observePendingConfirm() {
        let session = session
        withObservationTracking {
            _ = env.mobile.pendingConfirm
            // И тревогу тоже: guard ниже откладывает вопрос, пока на экране
            // предупреждение, — значит, снятие тревоги обязано перепоказать
            // вопрос. Без этого чтения он терялся навсегда: комментарий
            // обещал «вопрос ждёт», а код его выбрасывал.
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
        guard let camera = env.mobile.pendingConfirm else { return }
        // Пока на экране предупреждение о камере, вопрос ждёт: перекрывать
        // предупреждение вопросом — ровно то, чего делать нельзя.
        guard !env.location.isApproachingCamera else { return }
        // Занято другим диалогом (тост, «Нет доступа») — не пытаемся: второй
        // presentTemplate поверх показанного CarPlay отклоняет. Наблюдение
        // выше перепокажет вопрос при следующей смене состояния.
        guard interfaceController?.presentedTemplate == nil else { return }
        func answer(_ value: Bool?) -> (CPAlertAction) -> Void {
            { [weak self] _ in
                self?.env.mobile.answerConfirm(stillThere: value)
                self?.dismissTopTemplate()
            }
        }
        let alert = CPAlertTemplate(
            titleVariants: [String(format: String(localized: "%@ ещё на месте?"), camera.kind.displayName),
                            String(localized: "Ещё на месте?")],
            actions: [
                CPAlertAction(title: String(localized: "Да"), style: .default, handler: answer(true)),
                CPAlertAction(title: String(localized: "Нет"), style: .destructive, handler: answer(false)),
                CPAlertAction(title: String(localized: "Пропустить"), style: .cancel, handler: answer(Bool?.none)),
            ])
        interfaceController?.presentTemplate(alert, animated: true) { _, error in
            if let error {
                Log.carplay.error("presentTemplate(подтверждение): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Всплывающие сообщения

    func popToMap() {
        interfaceController?.popToRootTemplate(animated: true) { _, error in
            if let error {
                Log.carplay.error("popToRootTemplate: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Диалог с пояснением.
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

    /// Короткое подтверждение без единого тапа: само гаснет через пару секунд —
    /// водителю нечего нажимать.
    func showToast(_ text: String) {
        let alert = CPAlertTemplate(titleVariants: [text],
                                    actions: [CPAlertAction(title: String(localized: "ОК"),
                                                            style: .default) { [weak self] _ in
            self?.dismissTopTemplate()
        }])
        interfaceController?.presentTemplate(alert, animated: true) { _, error in
            if let error {
                Log.carplay.error("presentTemplate(тост): \(error.localizedDescription, privacy: .public)")
            }
        }
        toastTask?.cancel()
        // Гасим только СВОЙ тост: безусловный dismissTemplate по таймеру
        // закрывал любой диалог, успевший встать следом, — включая вопрос
        // «ещё на месте?», требующий ответа.
        toastTask = Task { @MainActor [weak self, weak alert] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self, let alert,
                  self.interfaceController?.presentedTemplate === alert else { return }
            self.dismissTopTemplate()
        }
    }
}
