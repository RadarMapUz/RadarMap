//
//  CarPlaySceneDelegate+Report.swift
//  RadarMap
//
//  «Отметить» в машине — вариант B (02.11; спецификация CarPlay, часть A).
//
//  Касание кнопки бара или карты запоминает точку (ReportFlow — тот же
//  черновик, что у телефона) и ставит над картой баннер «Тренога? Или
//  выберите»: iOS 27 — три типа кнопками и крестик, до iOS 27 — «Пост ·
//  ДТП…» (сетка) и «Отмена». Три секунды молчания — тренога; тот же баннер
//  становится «Тренога отмечена · Отменить» на 8 с. Пока выбор не сделан и
//  отсчёт не вышел, на сервер не уходит ничего.
//
//  Баннер — вид черновика, а не его владелец: машина наблюдает
//  `env.reports.draft` и рисует то, что там; отсчёт, отправку и голос ведёт
//  ReportFlow. Поэтому камера, вытеснившая баннер, отсчёт не останавливает
//  (тренога уйдёт и прозвучит), а касание на телефоне видно и в машине.
//
//  Камера всегда сверху (CarPlayBanners): выбор — `.request`, ниже камеры.
//  Камера уже на экране в момент касания — выбор не ставим, тренога уходит
//  сразу, «Отменить» встанет, когда экран освободится (A6).
//

import CarPlay
import os

extension CarPlaySceneDelegate {

    // MARK: - Касание

    /// Кнопка бара или карты. Двойное касание вслепую — тренога сразу (сам
    /// черновик); отказ (нет точки, дубль) — голосом ReportFlow и баннером.
    func beginReport(source: ReportDraft.Source) {
        let cameraOnScreen = banners?.showingKind == .camera
        Task { @MainActor [weak self] in
            guard let self else { return }
            let answer = await env.reports.begin(from: source, choiceBlocked: cameraOnScreen)
            if case .done(let outcome) = answer, !outcome.isSuccess {
                showToast(outcome.spoken)
            }
        }
    }

    // MARK: - Баннер — вид черновика

    func observeReportDraft() {
        let session = session
        withObservationTracking {
            _ = env.reports.draft
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                self.syncReportBanner()
                self.observeReportDraft()
            }
        }
    }

    func syncReportBanner() {
        guard let banners else { return }
        let draft = env.reports.draft
        switch draft.phase {
        case .choosing(_, _, let silence):
            // Тот же выбор уже показан (или был и вытеснен) — второй раз не
            // ставим: отсчёт идёт и без баннера.
            guard reportShown?.serial != draft.serial, silence == .tripod else { return }
            presentChoice(serial: draft.serial, banners: banners)
        case .sending:
            break
        case .sent(let sent):
            if reportGridOpen { closeReportGrid() }
            guard reportShown.map({ $0.serial != draft.serial || !$0.sent }) ?? true else { return }
            let remaining = sent.undoUntil.timeIntervalSinceNow
            if #available(iOS 27.0, *), let banner = reportBanner, banners.isShowing(banner) {
                // Тот же баннер переписывается, а не ставится новый: новый на
                // месте старого мигнул бы и прошёл бы очередь заново (A4).
                banner.updateTitleVariants(sentTitles(sent.kind), subtitleVariants: sentSubtitles(sent),
                                           avatarImage: banner.avatarImage, alert: nil,
                                           actions: sentActions(), duration: max(1, remaining))
                reportShown = (draft.serial, true)
                return
            }
            if let banner = reportBanner { banners.dismiss(banner) }
            reportBanner = nil
            guard CarPlayReportChoice.showsUndoBanner(remaining: remaining) else { return }
            presentSent(sent, serial: draft.serial, remaining: remaining, banners: banners)
        case .idle:
            if reportGridOpen { closeReportGrid() }
            if let banner = reportBanner { banners.dismiss(banner) }
            reportBanner = nil
        }
    }

    private func presentChoice(serial: Int, banners: CarPlayBanners) {
        let titles = [ReportWords.choosePrompt, ReportWords.choosePromptShort]
        let subtitle = String(localized: "Уйдёт сама через 3 с")
        var maximum: Int?
        if #available(iOS 27.0, *) { maximum = CPNavigationAlert.maximumActionsCount }
        let alert: CPNavigationAlert
        switch CarPlayReportChoice.layout(maximumActions: maximum) {
        case .inBanner(let kinds):
            guard #available(iOS 27.0, *) else { return }
            alert = CPNavigationAlert(
                titleVariants: titles,
                subtitleVariants: [subtitle],
                avatarImage: CarPlayBannerArt.avatar(CameraType.tripod,
                                                     size: CarPlayCameraBannerLook.fit(
                                                        AppConfig.carPlayBannerAvatarSize,
                                                        into: CPNavigationAlert.maximumAvatarImageSize)),
                alert: nil,
                actions: kinds.map { kind in
                    // «Выбрана» — цветом: тренога уйдёт сама. Цвет не прошёл
                    // контраст машины — система возьмёт свой, кнопка останется.
                    kind == ReportDraft.defaultKind
                        ? CPAlertAction(title: ReportWords.title(kind), color: Theme.actionUIColor) { [weak self] _ in
                            self?.env.reports.choose(kind)
                        }
                        : CPAlertAction(title: ReportWords.title(kind), style: .default) { [weak self] _ in
                            self?.env.reports.choose(kind)
                        }
                },
                // Срок ведём сами: системный минимум баннера — 5 с, отсчёт — 3.
                duration: 0)
            alert.showsCloseButton = true
        case .viaGrid:
            alert = CPNavigationAlert(
                titleVariants: titles,
                subtitleVariants: [subtitle],
                image: nil,
                primaryAction: CPAlertAction(title: String(localized: "Пост · ДТП…"), style: .default) { [weak self] _ in
                    self?.presentReportGrid()
                },
                secondaryAction: CPAlertAction(title: String(localized: "Отмена"), style: .cancel) { [weak self] _ in
                    self?.env.reports.cancelChoice()
                },
                duration: 0)
        }
        reportShown = (serial, false)
        guard banners.show(alert, kind: .request) else {
            Log.carplay.notice("выбор отметки не показан: экран занят — отсчёт идёт")
            return
        }
        reportBanner = alert
        Log.carplay.notice("выбор отметки: баннер")
    }

    private func presentSent(_ sent: ReportDraft.Sent, serial: Int, remaining: TimeInterval,
                             banners: CarPlayBanners) {
        let actions = sentActions()
        let alert: CPNavigationAlert
        if #available(iOS 27.0, *) {
            alert = CPNavigationAlert(titleVariants: sentTitles(sent.kind), subtitleVariants: sentSubtitles(sent),
                                      avatarImage: nil, alert: nil, actions: actions,
                                      duration: max(AppConfig.reportUndoBannerMinSeconds, remaining))
        } else {
            alert = CPNavigationAlert(titleVariants: sentTitles(sent.kind), subtitleVariants: sentSubtitles(sent),
                                      image: nil, primaryAction: actions[0],
                                      secondaryAction: actions.count > 1 ? actions[1] : nil,
                                      duration: max(AppConfig.reportUndoBannerMinSeconds, remaining))
        }
        guard banners.show(alert, kind: .request) else { return }
        reportBanner = alert
        reportShown = (serial, true)
    }

    private func sentTitles(_ kind: ReportKind) -> [String] {
        [ReportWords.marked(kind), String(localized: "Отмечено")]
    }

    private func sentSubtitles(_ sent: ReportDraft.Sent) -> [String] {
        [sent.queued ? String(localized: "Уйдёт, когда появится связь")
                     : String(localized: "Увидят другие водители")]
    }

    /// «Отменить» — пока можно; точку уже подтвердил другой водитель —
    /// только «Понятно».
    private func sentActions() -> [CPAlertAction] {
        guard env.reports.canUndo() else {
            return [CPAlertAction(title: String(localized: "Понятно"), style: .cancel) { _ in }]
        }
        return [CPAlertAction(title: String(localized: "Отменить"), style: .destructive) { [weak self] _ in
                    Task { @MainActor [weak self] in await self?.env.reports.undo() }
                },
                CPAlertAction(title: String(localized: "ОК"), style: .cancel) { _ in }]
    }

    // MARK: - Закрыт водителем или системой

    /// Баннер отметки ушёл (CarPlaySceneDelegate.didDismiss). Крестик и
    /// кнопка приходят одним `.userDismissed`, а порядок с обработчиком
    /// кнопки не описан: отмену засчитываем с паузой, только если выбор так
    /// и остался открытым (A6).
    func reportBannerDismissed(_ alert: CPNavigationAlert, context: CPNavigationAlert.DismissalContext) {
        guard alert === reportBanner else { return }
        reportBanner = nil
        let serial = env.reports.draft.serial
        guard context == .userDismissed, env.reports.draft.choosing != nil else {
            // Снят системой (камера) — выбор не возвращаем, отсчёт идёт; а
            // «Отменить» вернётся по onIdle, пока окно открыто. Закрытый
            // водителем («ОК») или истёкший — не возвращается.
            if context == .systemDismissed, reportShown?.sent == true { reportShown = nil }
            return
        }
        Task { @MainActor [weak self] in
            await Task.pause(seconds: AppConfig.reportChooseTapGraceSeconds)
            guard let self, !self.reportGridOpen, self.env.reports.draft.serial == serial,
                  self.env.reports.draft.choosing != nil else { return }
            Log.carplay.notice("выбор отметки закрыт крестиком — не отмечено")
            self.env.reports.cancelChoice()
        }
    }

    // MARK: - Сетка до iOS 27

    /// «Пост · ДТП…»: отсчёт треноги стоит — водитель уже сказал «не
    /// тренога»; без выбора 10 с сетка закрывается, ничего не отправив.
    func presentReportGrid() {
        env.reports.holdChoice()
        let buttons = [ReportKind.post, .accident].map { kind in
            gridButton(symbol: kind.symbol, titles: [ReportWords.title(kind)]) { [weak self] in
                self?.reportGridOpen = false
                self?.popToMap { [weak self] in self?.env.reports.choose(kind) }
            }
        } + [gridButton(symbol: "xmark", titles: [String(localized: "Отмена")]) { [weak self] in
            self?.reportGridOpen = false
            self?.popToMap { [weak self] in self?.env.reports.cancelChoice() }
        }]
        guard beginPush("отметка") else { return }
        reportGridOpen = true
        let grid = CPGridTemplate(title: String(localized: "Что там?"), gridButtons: buttons)
        interfaceController?.pushTemplate(grid, animated: true) { [weak self] _, error in
            Task { @MainActor [weak self] in self?.endPush() }
            if let error {
                Log.carplay.error("pushTemplate(отметка): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func closeReportGrid() {
        reportGridOpen = false
        popToMap()
    }
}
