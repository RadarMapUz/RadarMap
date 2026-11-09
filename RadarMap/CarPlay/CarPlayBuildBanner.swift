//
//  CarPlayBuildBanner.swift
//  RadarMap
//
//  Ход построения маршрута на экране машины: баннер поверх карты с «Отменой»,
//  при неудаче — что случилось и «Повторить».
//
//  До 09.11 после касания в «Куда» экран оставался прежним до 6 с (GPS), потом
//  ещё секунды показывал просто карту, а ошибка приходила окном на весь экран.
//  Состояние — общее с телефоном (RouteService.buildFlow); здесь только вид, и
//  только через очередь баннеров: камера остаётся сверху, и когда она уходит,
//  ход построения или ошибка возвращаются (`bannersFreed`).
//

import CarPlay
import os

@MainActor
final class CarPlayBuildBanner {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    private enum Shown: Equatable {
        case working(Int)
        case failed(Int)
    }

    private var alert: CPNavigationAlert?
    private var shown: Shown?
    private var shownSubtitle: String?

    struct Actions {
        let cancel: () -> Void
        let retry: (RouteBuildFlow.Target) -> Void
    }

    func sync(_ flow: RouteBuildFlow, banners: CarPlayBanners, actions: Actions) {
        switch flow.state {
        case .idle:
            if let alert { banners.dismiss(alert) }
            clear()
        case .working(let target, let stage, let slow):
            let subtitle = slow ? String(localized: "Сеть медленная, ещё немного…") : stage.title
            if shown == .working(flow.attempt) {
                update(subtitle: subtitle, target: target, cancel: actions.cancel)
                return
            }
            present(working: target, subtitle: subtitle, attempt: flow.attempt, banners: banners, cancel: actions.cancel)
        case .failed(let target, let failure):
            guard shown != .failed(flow.attempt) else { return }
            present(failed: target, failure: failure, attempt: flow.attempt, banners: banners, retry: actions.retry)
        }
    }

    func owns(_ alert: CPNavigationAlert) -> Bool { alert === self.alert }

    /// Снят не водителем (вытеснен камерой): вернётся по `onIdle`.
    func forget(_ alert: CPNavigationAlert) {
        guard alert === self.alert else { return }
        clear()
    }

    /// Подключение кончилось.
    func reset() {
        clear()
    }

    private func clear() {
        alert = nil
        shown = nil
        shownSubtitle = nil
    }

    private func titles(_ target: RouteBuildFlow.Target) -> [String] {
        [String(format: String(localized: "Строим маршрут: %@"), target.name), String(localized: "Строим маршрут…")]
    }

    private func present(working target: RouteBuildFlow.Target, subtitle: String, attempt: Int,
                         banners: CarPlayBanners, cancel: @escaping () -> Void) {
        let next = CPNavigationAlert(
            titleVariants: titles(target),
            subtitleVariants: [subtitle],
            image: nil,
            primaryAction: CPAlertAction(title: String(localized: "Отмена"), style: .cancel) { _ in cancel() },
            secondaryAction: nil,
            duration: 0)
        guard banners.show(next, kind: .request) else { return }
        alert = next
        shown = .working(attempt)
        shownSubtitle = subtitle
        Log.carplay.notice("построение: баннер хода")
    }

    /// До iOS 27 текст показанного баннера не изменить — там остаётся первый.
    private func update(subtitle: String, target: RouteBuildFlow.Target, cancel: @escaping () -> Void) {
        guard subtitle != shownSubtitle, let alert else { return }
        shownSubtitle = subtitle
        guard #available(iOS 27.0, *) else { return }
        alert.updateTitleVariants(titles(target), subtitleVariants: [subtitle], avatarImage: alert.avatarImage,
                                  alert: nil,
                                  actions: [CPAlertAction(title: String(localized: "Отмена"), style: .cancel) { _ in cancel() }],
                                  duration: 0)
    }

    private func present(failed target: RouteBuildFlow.Target, failure: RouteBuildFlow.Failure, attempt: Int,
                         banners: CarPlayBanners, retry: @escaping (RouteBuildFlow.Target) -> Void) {
        let title = failure.title ?? AppEnvironment.shared.route.errorMessage ?? String(localized: "Маршрут не построен")
        let canRetry = RouteBuildFlow.canRetry(target, failure)
        let primary = canRetry
            ? CPAlertAction(title: String(localized: "Повторить"), style: .default) { _ in retry(target) }
            : CPAlertAction(title: String(localized: "Понятно"), style: .cancel) { _ in }
        let next = CPNavigationAlert(
            titleVariants: [title, String(localized: "Маршрут не построен")],
            subtitleVariants: failure.hint.map { [$0] } ?? [],
            image: nil,
            primaryAction: primary,
            secondaryAction: canRetry ? CPAlertAction(title: String(localized: "Закрыть"), style: .cancel) { _ in } : nil,
            duration: AppConfig.carPlayBuildFailedSeconds)
        guard banners.show(next, kind: .request) else { return }
        alert = next
        shown = .failed(attempt)
        shownSubtitle = nil
        Log.carplay.notice("построение: баннер ошибки, повтор \(canRetry, privacy: .public)")
    }
}
