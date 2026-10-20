//
//  CarPlaySceneDelegate+Window.swift
//  RadarMap
//
//  Окно машины: хост, сторож застывания, корневой шаблон и его подтверждение.
//

import CarPlay
import SwiftUI
import os

extension CarPlaySceneDelegate {

    func startFreezeWatch(scene: CPTemplateApplicationScene) {
        freezeWatch?.cancel()
        freezeWatch = Task { @MainActor [weak self, weak scene] in
            while !Task.isCancelled {
                await Task.pause(seconds: AppConfig.carPlayFreezeCheckSeconds)
                guard let self, let scene, scene.activationState == .foregroundActive,
                      self.model.isOnScreen, self.host != nil else { continue }
                let behind = self.env.location.locationTick - self.model.lastRenderedTick
                let silence = Date().timeIntervalSince(self.model.lastHeartbeat)
                // Пульс TimelineView — только улика, не повод чинить: такт,
                // взятый не от экрана машины, при погашенном экране телефона
                // встаёт (форум Apple 777989), и сторож перезагружал бы живую
                // карту. Чиним только по тикам GPS, которые дерево не отметило.
                if behind <= AppConfig.carPlayFreezeTicks {
                    if silence > AppConfig.carPlayHeartbeatStaleSeconds, !self.heartbeatReported {
                        self.heartbeatReported = true
                        Log.carplay.fault("пульс экрана машины молчит \(Int(silence), privacy: .public) с при живых тиках — только пишу")
                    }
                    continue
                }
                guard self.freezeRepairs < AppConfig.carPlayFreezeRepairs else {
                    Log.carplay.fault("окно машины стоит и после \(self.freezeRepairs, privacy: .public) пересозданий: тиков \(behind, privacy: .public), пульс молчит \(Int(silence), privacy: .public) с")
                    continue
                }
                self.freezeRepairs += 1
                Log.carplay.fault("окно машины застыло: тиков \(behind, privacy: .public), пульс молчит \(Int(silence), privacy: .public) с — пересоздаю хост")
                self.installHost()
            }
        }
    }

    /// Экран машины — новым содержимым постоянного корня. Только на переднем
    /// плане (см. didConnect): дерево, построенное в окне, которое система не
    /// показывает, потом не оживало. Корень окна при этом не меняется.
    func installHost() {
        guard let windowRoot else {
            Log.carplay.error("хост экрана машины: корня окна нет")
            return
        }
        let host = UIHostingController(rootView: AnyView(
            CarPlayMapScreen(model: model).environment(env)))
        host.view.backgroundColor = UIColor(Theme.background)
        windowRoot.setContent(host)
        self.host = host
        needsFreshHost = false
        // Новое дерево ещё не успело отметиться — без сброса сторож счёл бы
        // его застывшим по меткам прежнего.
        model.lastHeartbeat = Date()
        model.lastRenderedTick = env.location.locationTick
    }

    /// Сцена на экране машины: на переднем плане (активна или нет — например,
    /// поверх висит системный алерт).
    static func isShown(_ scene: UIScene) -> Bool {
        scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
    }

    static func stateName(_ scene: UIScene) -> String {
        switch scene.activationState {
        case .foregroundActive:   return "на экране"
        case .foregroundInactive: return "на экране (неактивна)"
        case .background:         return "в фоне"
        case .unattached:         return "не привязана к экрану"
        @unknown default:         return "неизвестно"
        }
    }

    // MARK: - Шаблон на экране

    /// Корневой шаблон показан (после подключения, после закрытого «Куда»,
    /// алерта или поиска). Бар отправленный раньше этого момента головное
    /// устройство теряет: журнал 2.2.3 показал, что хост держал сцену в фоне
    /// и отвечал «No active map template found», а completion у
    /// setRootTemplate пришёл через 25 мс — до показа. Здесь шаблон уже на
    /// экране, и отправка гарантированно доходит.
    func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        shownTemplate = aTemplate === mapTemplate ? nil : aTemplate
        // Улика для «диалог не показался»: баннеры живут на шаблоне карты и
        // под сеткой или поиском не видны, а templateDidAppear уже оказался
        // ненадёжным для корня (carplay4, carplay10).
        if aTemplate !== mapTemplate {
            Log.carplay.notice("поверх карты: \(String(describing: type(of: aTemplate)), privacy: .public)")
        }
        guard aTemplate === mapTemplate else { return }
        resendButtons()
        rootDidShow(via: "templateDidAppear")
        // Вернулись к карте из «Куда» или поиска — ждавший вопрос теперь видно.
        presentPendingConfirmIfNeeded()
        retryOneTimeShows()
    }

    /// Корень на экране машины — один раз за подключение. Признак — либо
    /// templateDidAppear, либо активная сцена с подтверждённой установкой
    /// (CarPlayRootWatch): первый система присылает не всегда.
    func rootDidShow(via source: String) {
        guard !rootShown, let mapTemplate else { return }
        rootShown = true
        templateWatch?.cancel()
        Log.carplay.notice("корневой шаблон на экране: \(source, privacy: .public)")
        // Сессия — только на шаблоне, который уже на экране: начатая на
        // летящем корне пропадала, а свой баннер манёвра при этом уже спрятан
        // (hasSystemGuidance) — водитель без манёвра. Completion у
        // setRootTemplate для этого не годится: он приходил через 25 мс, пока
        // хост ещё держал сцену в фоне.
        // Выбор на телефоне уже идёт — тот же выбор и здесь, до сессии.
        observeFlow()
        if !guidanceAttached {
            attachGuidance(background: false)
        } else if guidanceAttachedInBackground {
            guidanceAttachedInBackground = false
            guidance.mayStartSession = true
            guidance.restartSession(reason: "корень на экране после подключения в фоне")
        }
        // Алерт о разрешении — сразу, а не по первому тапу: без разрешения
        // экран машины не покажет ни скорости, ни камер, и молчание
        // неотличимо от поломки. Поверх летящего корня CarPlay его отклонял.
        if !env.location.isAuthorized { return showNoPermissionAlert() }
        offerDestinationSoon()
    }

    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        if shownTemplate === aTemplate { shownTemplate = nil }
    }

    func watchRootTemplate() {
        templateWatch?.cancel()
        guard !rootShown else { return }
        let session = session
        templateWatch = Task { @MainActor [weak self] in
            await Task.pause(seconds: AppConfig.carPlayRootSettleDelay)
            guard let self, !Task.isCancelled, self.session == session else { return }
            guard self.model.isOnScreen else {
                // Ушли с экрана машины, не дождавшись показа: ведение — в фон.
                if self.rootSet == true, !self.rootShown { self.attachGuidanceInBackground() }
                return
            }
            if self.applyRootWatch(timedOut: false) == .markShown { return }
            await Task.pause(seconds: max(0, AppConfig.carPlayTemplateShowTimeout - AppConfig.carPlayRootSettleDelay))
            guard !Task.isCancelled, self.session == session, self.model.isOnScreen else { return }
            self.applyRootWatch(timedOut: true)
        }
    }

    @discardableResult
    func applyRootWatch(timedOut: Bool) -> CarPlayRootWatch.Action {
        let action = CarPlayRootWatch.action(rootShown: rootShown, rootSet: rootSet,
                                             retried: rootRetried, timedOut: timedOut)
        switch action {
        case .none:
            break
        case .markShown:
            rootDidShow(via: "сцена активна, установка подтверждена")
        case .setAgain:
            guard let mapTemplate, let interfaceController else { break }
            rootRetried = true
            Log.carplay.fault("корневой шаблон не подтверждён за \(Int(AppConfig.carPlayTemplateShowTimeout), privacy: .public) с — ставлю заново")
            setRoot(mapTemplate, on: interfaceController)
        }
        return action
    }

    /// Установка корня без анимации (анимированная у сцены в фоне теряется).
    /// Подтверждение системы запоминается для CarPlayRootWatch; пришло, пока
    /// сцена на экране, — проверка «показан» запускается сразу.
    func setRoot(_ template: CPMapTemplate, on interfaceController: CPInterfaceController) {
        rootSet = nil
        let session = session
        interfaceController.setRootTemplate(template, animated: false) { [weak self] success, error in
            if let error {
                Log.carplay.error("setRootTemplate: \(error.localizedDescription, privacy: .public)")
            }
            let confirmed = success && error == nil
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                self.rootSet = confirmed
                guard confirmed, !self.rootShown else { return }
                if self.model.isOnScreen {
                    self.watchRootTemplate()
                } else {
                    self.attachGuidanceInBackground()
                }
            }
        }
    }
}
